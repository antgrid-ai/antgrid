// bridge/tests/session-bus-wire.test.ts
import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalListener } from "../src/local-listener";
import { MessageBus } from "../src/message-bus";
import {
  AbMessageSchema,
  CHECKOUT_VARIABLE_MESSAGE_TYPES,
  createMessage,
  parseMessageFast,
  SessionBusAckWire,
  SessionBusFetchResultWire,
  SessionBusFetchWire,
  SessionBusMessageWire,
  type AbMessage,
  type SessionMemberKey,
  type SessionMemberRef,
} from "../src/protocol";
import {
  SessionBusCoordinator,
  type SessionBusEvent,
  type SessionBusSelf,
} from "../src/session-bus/coordinator";
import { HELD_MESSAGE_TTL_MS } from "../src/session-bus/held-store";

const LEAD_REF: SessionMemberRef = {
  machineId: "m-lead",
  projectId: "p-lead",
  sessionId: "s-lead",
  machineLabel: "Desktop",
};
const PEER_REF: SessionMemberRef = {
  machineId: "m-peer",
  projectId: "p-peer",
  sessionId: "s-peer",
  machineLabel: "Laptop",
};
const LEAD_KEY: SessionMemberKey = { machineId: "m-lead", projectId: "p-lead", sessionId: "s-lead" };
const PEER_KEY: SessionMemberKey = { machineId: "m-peer", projectId: "p-peer", sessionId: "s-peer" };

const ENVELOPE = {
  messageId: "msg-1",
  threadId: "t1",
  contextId: "ctx-1",
  parts: [{ kind: "text" as const, text: "run the suite" }],
  metadata: { peer: LEAD_REF, summary: "run the suite", timestamp: 1_000_000 },
};

// One instance of every type in the family, in the exact shape the coordinator
// puts on the wire.
const SAMPLES: { msg: AbMessage; wire: { safeParse: (v: unknown) => { success: boolean } } }[] = [
  {
    msg: createMessage("session-bus:post", {
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1", threadId: null, envelope: ENVELOPE,
    }),
    wire: SessionBusMessageWire,
  },
  {
    // The same body under a different verb, which is the whole of the
    // difference: a bridge that does not know a verb refuses the frame, where a
    // bridge that did not know a flag would silently treat it as the other one.
    msg: createMessage("session-bus:notify", {
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1", threadId: "t1", envelope: ENVELOPE,
    }),
    wire: SessionBusMessageWire,
  },
  {
    msg: createMessage("session-bus:fetch", {
      from: LEAD_KEY, to: PEER_KEY, contextId: "ctx-1",
      requestId: "r1", artifactId: "a1", offset: 0, length: 1024,
    }),
    wire: SessionBusFetchWire,
  },
  {
    msg: createMessage("session-bus:fetch:result", {
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1",
      requestId: "r1", ok: true, artifactId: "a1", offset: 0, eof: true, dataBase64: "aGk=",
    }),
    wire: SessionBusFetchResultWire,
  },
  {
    msg: createMessage("session-bus:ack", {
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1", messageId: "msg-1", ok: true,
    }),
    wire: SessionBusAckWire,
  },
];

describe("session-bus protocol", () => {
  test("every frame survives the fast path and its own wire schema", () => {
    for (const { msg, wire } of SAMPLES) {
      const parsed = parseMessageFast(JSON.stringify(msg));
      expect(parsed, `${msg.type} is not in KNOWN_TYPES`).not.toBeNull();
      expect(parsed!.type).toBe(msg.type);
      // parseMessageFast only checks the type tag; the handler re-parses with
      // the wire schema, which is where a malformed body is actually caught.
      expect(wire.safeParse(parsed).success, `${msg.type} failed its wire schema`).toBe(true);
      expect(AbMessageSchema.safeParse(msg).success, `${msg.type} is not in the union`).toBe(true);
    }
  });

  test("a body that violates its wire schema is refused", () => {
    const bad = { ...SAMPLES[0]!.msg, threadId: "" };
    expect(SessionBusMessageWire.safeParse(bad).success).toBe(false);
  });

  test("no bus frame is checkout-variable", () => {
    // A bus frame addresses a session, and a session's checkout is resolved from
    // that id — routing one by checkoutId would let a carrier name a working tree.
    for (const { msg } of SAMPLES) {
      expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has(msg.type as never)).toBe(false);
    }
  });

  test("no bus frame is replayed to a late joiner", () => {
    // Bus traffic is addressed to one session; replaying it on connect would
    // hand a phone an exchange it must never see, and hand the agent a message
    // it has already read.
    const bus = new MessageBus();
    for (const { msg } of SAMPLES) bus.publish(msg, "control");
    const snapshot = bus.getSnapshot(["*"]);
    expect(snapshot.some((m) => String(m.type).startsWith("session-bus:"))).toBe(false);
  });
});

describe("session-bus forwarding", () => {
  let bus: MessageBus;
  let listener: LocalListener;

  beforeEach(async () => {
    bus = new MessageBus();
    listener = new LocalListener({ bus, token: "secret-token", projectId: "proj-bus" });
    await listener.start();
  });
  afterEach(async () => { await listener.stop(); });

  async function openOwner(carrier: boolean): Promise<WebSocket> {
    const ws = new WebSocket(`ws://127.0.0.1:${listener.port}`);
    await new Promise<void>((resolve, reject) => {
      ws.onopen = () => resolve();
      ws.onerror = (e) => reject(e);
    });
    ws.send(JSON.stringify({
      type: "hello", token: "secret-token", appPid: 1, appVersion: "test",
      ...(carrier ? { capabilities: { sessionBusCarrier: true } } : {}),
    }));
    await new Promise<void>((resolve) => {
      ws.onmessage = (ev) => { if (JSON.parse(String(ev.data)).type === "ready") resolve(); };
    });
    return ws;
  }

  test("the owner socket sees a bus frame and a bus subscriber never does", async () => {
    // The first invariant of spec 4.1: the lead's phone is a bus subscriber, and
    // the bus has no addressing, so anything published fans out to it.
    const subscriber: string[] = [];
    bus.subscribe({ deliver: (msg) => { subscriber.push(msg.type); } });

    const ws = await openOwner(true);
    const owner: string[] = [];
    ws.onmessage = (ev) => { owner.push(JSON.parse(String(ev.data)).type); };

    for (const { msg } of SAMPLES) expect(listener.deliverToOwner(msg)).toBe(true);
    await Bun.sleep(50);

    expect(owner).toEqual(SAMPLES.map((s) => s.msg.type));
    expect(subscriber).toEqual([]);
    ws.close();
  });

  test("with no carrier the frame does not leave and nothing is published", async () => {
    const subscriber: string[] = [];
    bus.subscribe({ deliver: (msg) => { subscriber.push(msg.type); } });
    const ws = await openOwner(false);
    expect(listener.deliverToOwner(SAMPLES[0]!.msg)).toBe(false);
    await Bun.sleep(20);
    expect(subscriber).toEqual([]);
    ws.close();
  });
});

describe("session-bus coordinator across a carrier", () => {
  let dir: string;
  let lead: SessionBusCoordinator;
  let peer: SessionBusCoordinator;
  let carried: AbMessage[];
  let routes: { contextId: string; role: string }[];
  let leadEvents: SessionBusEvent[];
  let peerEvents: SessionBusEvent[];
  let carrierUp: boolean;
  let now: number;
  let ids: number;

  const selfFor = (ref: SessionMemberRef) => (sessionId: string): SessionBusSelf | null =>
    sessionId === ref.sessionId
      ? { key: { machineId: ref.machineId, projectId: ref.projectId, sessionId }, ref }
      : null;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "sb-wire-"));
    carried = [];
    routes = [];
    leadEvents = [];
    peerEvents = [];
    carrierUp = true;
    now = 1_000_000;
    ids = 0;
    const newId = () => `id-${++ids}`;
    // One carrier for both ends, which is what a desktop app relaying between
    // two bridges actually is. Every frame is captured before delivery so a test
    // can hold, drop or duplicate it the way a real link does.
    lead = new SessionBusCoordinator({
      abDir: join(dir, "lead"),
      projectIdFor: () => "p-lead",
      self: selfFor(LEAD_REF),
      send: (frame, ctx) => {
        if (!carrierUp) return false;
        carried.push(frame);
        routes.push({ contextId: ctx.contextId, role: ctx.role });
        return true;
      },
      onEvent: (e) => leadEvents.push(e),
      now: () => now,
      newId,
    });
    peer = new SessionBusCoordinator({
      abDir: join(dir, "peer"),
      projectIdFor: () => "p-peer",
      self: selfFor(PEER_REF),
      send: (frame, ctx) => {
        if (!carrierUp) return false;
        carried.push(frame);
        routes.push({ contextId: ctx.contextId, role: ctx.role });
        return true;
      },
      onEvent: (e) => peerEvents.push(e),
      now: () => now,
      newId,
    });
  });

  afterEach(() => {
    lead.stop();
    peer.stop();
    rmSync(dir, { recursive: true, force: true });
  });

  /** Deliver everything the carrier is holding, to whichever end it addresses. */
  function drain(): AbMessage[] {
    const batch = carried;
    carried = [];
    for (const frame of batch) {
      const to = (frame as { to: SessionMemberKey }).to;
      (to.sessionId === LEAD_REF.sessionId ? lead : peer).handleInbound(frame);
    }
    return batch;
  }

  /** A post from the lead, which opens the context every reply then rides. */
  function post(): string {
    const res = lead.message({
      sessionId: LEAD_REF.sessionId,
      verb: "post",
      threadId: null,
      to: PEER_REF,
      summary: "run the suite",
      parts: [{ kind: "text", text: "run the suite" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`message refused: ${JSON.stringify(res)}`);
    return res.messageId;
  }

  test("a post is delivered, raised as an event, and answered with a receipt", () => {
    const messageId = post();
    const sent = drain();
    expect(sent).toHaveLength(1);
    expect(sent[0]!.type).toBe("session-bus:post");
    expect((sent[0] as { to: SessionMemberKey }).to).toEqual(PEER_KEY);
    expect(peerEvents.map((e) => e.kind)).toEqual(["post"]);

    // E6: the receipt is keyed by the message it answers and is the only honest
    // witness that the frame arrived, since everything on the sending side can
    // report only that it left.
    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:ack");
    expect((carried[0] as unknown as { messageId: string }).messageId).toBe(messageId);
  });

  test("the receipt stamps the sender's own log entry, and only the outbound one", () => {
    const messageId = post();
    drain();
    // The second drain carries home the ack the peer raised while folding, which
    // is what turns "it left" into "it arrived".
    drain();

    const out = lead.messages(LEAD_REF.sessionId).entries.filter((e) => e.direction === "out");
    expect(out).toHaveLength(1);
    expect(out[0]!.envelope.messageId).toBe(messageId);
    expect(out[0]!.deliveredAt).toBe(now);
    // The receiver logged the same message inbound; a stamp there would read as
    // a receipt for its own delivery.
    expect(peer.messages(PEER_REF.sessionId).entries.every((e) => e.deliveredAt === undefined)).toBe(true);
  });

  test("a first send mints a thread id and a second send carrying it reuses it", () => {
    // Nothing minted one before this wave, so a reply had no thread to name and
    // there was no way to tell a fresh exchange from a continuing one.
    const first = lead.message({
      sessionId: LEAD_REF.sessionId,
      verb: "post",
      threadId: null,
      to: PEER_REF,
      summary: "run the suite",
      parts: [{ kind: "text", text: "run the suite" }],
    });
    expect("ok" in first && first.ok).toBe(true);
    const opened = first as { threadId: string; opensThread: boolean };
    expect(opened.threadId).toBeTruthy();
    expect(opened.opensThread).toBe(true);

    const second = lead.message({
      sessionId: LEAD_REF.sessionId,
      verb: "notify",
      threadId: opened.threadId,
      to: PEER_REF,
      summary: "and one more thing",
      parts: [{ kind: "text", text: "and one more thing" }],
    });
    expect("ok" in second && second.ok).toBe(true);
    expect((second as { threadId: string }).threadId).toBe(opened.threadId);
    expect((second as { opensThread: boolean }).opensThread).toBe(false);

    // The id the caller was told has to be the id on the wire, or it cannot be
    // replied on.
    const threads = carried.map((f) => (f as unknown as { threadId: string | null }).threadId);
    expect(threads).toEqual([opened.threadId, opened.threadId]);
  });

  // The reply template names what it answers, and the coordinator is the only
  // thing that can source it: it owns the log, and a renderer going back to disk
  // for it would resolve the owning project for itself and could answer about a
  // different one.
  test("an answer on a thread carries what this session last said on it", () => {
    const first = lead.message({
      sessionId: LEAD_REF.sessionId,
      verb: "post",
      threadId: null,
      to: PEER_REF,
      summary: "run the suite",
      parts: [{ kind: "text", text: "run the suite" }],
    });
    const threadId = (first as { threadId: string }).threadId;
    drain();
    carried = [];

    const answer = peer.message({
      sessionId: PEER_REF.sessionId,
      verb: "notify",
      threadId,
      to: LEAD_REF,
      summary: "it is green",
      parts: [{ kind: "text", text: "it is green" }],
    });
    expect("ok" in answer && answer.ok).toBe(true);
    drain();

    const arrived = leadEvents.at(-1)!;
    expect(arrived.opensThread).toBe(false);
    expect(arrived.answering).toBe("run the suite");

    // A first contact answers nothing, so claiming it did would place the reader
    // in an exchange that never happened.
    expect(peerEvents[0]!.answering).toBeUndefined();
  });

  test("a frame naming a session this bridge does not hold is dropped without an ack", () => {
    // Reported as DROPPED, not merely "a bus frame": the agent core binds the
    // only route home on this answer, so a frame naming somebody else's session
    // must not be able to claim it.
    const stray = createMessage("session-bus:post", {
      from: LEAD_KEY,
      to: { machineId: "m-peer", projectId: "p-peer", sessionId: "s-nobody" },
      contextId: "ctx-x", threadId: null, envelope: ENVELOPE,
    });
    expect(peer.handleInbound(stray)).toBe("dropped");
    expect(carried).toEqual([]);
    expect(peerEvents).toEqual([]);
  });

  test("an accepted frame is reported applied, so a route is bound only on one", () => {
    post();
    const [frame] = carried;
    carried.length = 0;
    expect(peer.handleInbound(frame!)).toBe("applied");
  });

  test("a non-bus frame falls through", () => {
    expect(lead.handleInbound(createMessage("terminal:input", { terminalId: "t", data: "x" }))).toBe(false);
  });

  test("a reply is routed home, not defaulted to the machine that opened the context", () => {
    post();
    drain();
    routes.length = 0;

    // The route has to come from the SESSION's side of the context: a "lead"
    // route on the answering machine posts the reply to THAT machine's own
    // desktop app, which accepts it and reports it sent.
    const res = peer.message({
      sessionId: PEER_REF.sessionId,
      verb: "post",
      threadId: null,
      to: LEAD_REF,
      contextId: LEAD_REF.sessionId,
      summary: "an aside",
      parts: [{ kind: "text", text: "an aside" }],
    });
    expect("ok" in res && res.ok).toBe(true);
    expect(routes).toHaveLength(1);
    expect(routes[0]!.role).toBe("peer");

    // And the same derivation on the machine the context belongs to.
    routes.length = 0;
    post();
    expect(routes[0]!.role).toBe("lead");
  });

  test("a session this bridge does not hold is refused rather than given an address", () => {
    const res = lead.message({
      sessionId: "s-not-here",
      verb: "post",
      threadId: null,
      to: PEER_REF,
      summary: "x",
      parts: [{ kind: "text", text: "x" }],
    });
    expect("ok" in res && res.ok).toBe(false);
    expect((res as { code: string }).code).toBe("NOT_MEMBER");
  });

  // A message can be lost and has nothing to dedup by, so one already on the
  // wire can never be resent. One the transport REFUSED is a different frame: it
  // never reached the relay, so putting it out later is a delivery and not a
  // second copy — and it is the case that decides whether a machine keeps what
  // it wrote across the seconds its carrier is away.
  test("a refused message is held and goes once when a route returns", () => {
    carrierUp = false;

    const res = peer.message({
      sessionId: PEER_REF.sessionId,
      verb: "post",
      threadId: null,
      to: LEAD_REF,
      contextId: LEAD_REF.sessionId,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });
    expect(res).toMatchObject({ ok: true, sent: false, held: true });
    expect(carried).toEqual([]);

    carrierUp = true;
    peer.pump();
    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:post");

    carried.length = 0;
    peer.pump();
    expect(carried).toEqual([]);
  });

  test("a held message survives a restart of the machine that could not send it", () => {
    carrierUp = false;
    peer.message({
      sessionId: PEER_REF.sessionId,
      verb: "post",
      threadId: null,
      to: LEAD_REF,
      contextId: LEAD_REF.sessionId,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });
    peer.stop();
    carried.length = 0;

    const resumed = new SessionBusCoordinator({
      abDir: join(dir, "peer"),
      projectIdFor: () => "p-peer",
      self: selfFor(PEER_REF),
      send: (frame) => { carried.push(frame); return true; },
      now: () => now,
      newId: () => "id-restart-msg",
    });
    // `resume`, not a load naming the session: a fresh process holds no sessions
    // and nothing else is going to name this one, so without the enumeration
    // what the dead process held simply never goes.
    resumed.resume();
    resumed.pump();
    resumed.stop();

    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:post");
  });

  test("a held message stops being worth delivering once its life has lapsed", () => {
    carrierUp = false;
    peer.message({
      sessionId: PEER_REF.sessionId,
      verb: "post",
      threadId: null,
      to: LEAD_REF,
      contextId: LEAD_REF.sessionId,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });

    now += HELD_MESSAGE_TTL_MS;
    carrierUp = true;
    peer.pump();
    // The lossiness a message plane asks for, spent where it costs least: a note
    // about a conversation this old arrives as noise, not as news.
    expect(carried.filter((f) => f.type === "session-bus:post")).toEqual([]);
  });
});

// The harness above sends every peer-role frame unconditionally, so it cannot
// see what agent-core's own carrier does: there is exactly one way home for a
// peer-role frame and it is the route the inbound frame taught. The receipt a
// fold dispatches is such a frame, and it is fire-and-forget — so the moment the
// route is bound, relative to the fold, is the whole of whether the first
// message of a cross-machine exchange is ever reported delivered.
describe("session-bus route binding around the fold", () => {
  let dir: string;
  let peer: SessionBusCoordinator;
  let carried: AbMessage[];
  let now: number;

  const CONTEXT = "ctx-opened-by-lead";

  const selfFor = (ref: SessionMemberRef) => (sessionId: string): SessionBusSelf | null =>
    sessionId === ref.sessionId
      ? { key: { machineId: ref.machineId, projectId: ref.projectId, sessionId }, ref }
      : null;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "sb-route-"));
    carried = [];
    now = 2_000_000;
    peer = new SessionBusCoordinator({
      abDir: join(dir, "peer"),
      projectIdFor: () => "p-peer",
      self: selfFor(PEER_REF),
      // agent-core.ts's `send` closure, reduced to the decision under test.
      send: (frame, ctx) => {
        if (ctx.role === "peer" && !peer.routeFor(ctx.contextId)) return false;
        carried.push(frame);
        return true;
      },
      now: () => now,
      newId: () => "id-route",
    });
  });

  afterEach(() => {
    peer.stop();
    rmSync(dir, { recursive: true, force: true });
  });

  const inbound = (to: SessionMemberKey, contextId: string) =>
    createMessage("session-bus:post", {
      from: LEAD_KEY,
      to,
      contextId,
      threadId: null,
      envelope: {
        messageId: "msg-opening",
        threadId: null,
        contextId,
        parts: [{ kind: "text" as const, text: "run the suite" }],
        metadata: { peer: LEAD_REF, summary: "run the suite", timestamp: now },
      },
    });

  test("the receipt for the frame that OPENS a context reaches its carrier", () => {
    // Nothing has ever routed this context: this is the first frame of the
    // exchange, which is exactly where the sender looks for its receipt.
    expect(peer.routeFor(CONTEXT)).toBeNull();

    expect(peer.handleInbound(inbound(PEER_KEY, CONTEXT), () => peer.noteRoute(CONTEXT, "app-1", "p-peer")))
      .toBe("applied");

    // Observed at the carrier, not in the log: an ack that was never handed to
    // a transport is not a receipt, and nothing retries one.
    expect(carried.map((f) => f.type)).toEqual(["session-bus:ack"]);
    expect((carried[0] as unknown as { messageId: string }).messageId).toBe("msg-opening");
  });

  test("a frame whose address check fails binds no route", () => {
    // The rebind hole: this map is the far end's only way home, so a frame
    // naming a session this bridge does not hold must not be able to claim a
    // context and take the next answer for itself.
    expect(peer.handleInbound(inbound({ machineId: "m-peer", projectId: "p-peer", sessionId: "s-nobody" }, CONTEXT), () =>
      peer.noteRoute(CONTEXT, "app-impostor", "p-peer"),
    )).toBe("dropped");
    expect(peer.routeFor(CONTEXT)).toBeNull();
    expect(carried).toEqual([]);
  });
});
