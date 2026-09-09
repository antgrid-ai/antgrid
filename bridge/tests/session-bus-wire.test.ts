// bridge/tests/session-bus-wire.test.ts
import { afterAll, afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalListener } from "../src/local-listener";
import { __setRootForTest } from "../src/logger";
import { MessageBus } from "../src/message-bus";
import {
  AbMessageSchema,
  CHECKOUT_VARIABLE_MESSAGE_TYPES,
  createMessage,
  parseMessageFast,
  SessionBusAckWire,
  SessionBusAssignWire,
  SessionBusCancelWire,
  SessionBusFetchResultWire,
  SessionBusFetchWire,
  SessionBusMessageWire,
  SessionBusTransitionWire,
  type AbMessage,
  type SessionMemberKey,
  type SessionMemberRef,
} from "../src/protocol";
import {
  SessionBusCoordinator,
  type SessionBusEvent,
  type SessionBusSelf,
} from "../src/session-bus/coordinator";
import { SESSION_BUS_UNACKED_WARN_ATTEMPTS } from "../src/session-bus/constants";
import { HELD_MESSAGE_TTL_MS } from "../src/session-bus/held-store";
import { NO_PROGRESS_EXCHANGES } from "../src/session-bus/task-guard";

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
  taskId: "t1",
  contextId: "ctx-1",
  parts: [{ kind: "text" as const, text: "run the suite" }],
  metadata: { peer: LEAD_REF, summary: "run the suite", timestamp: 1_000_000 },
};

// One instance of every type in the family, in the exact shape the coordinator
// puts on the wire.
const SAMPLES: { msg: AbMessage; wire: { safeParse: (v: unknown) => { success: boolean } } }[] = [
  {
    msg: createMessage("session-bus:assign", {
      from: LEAD_KEY, to: PEER_KEY, contextId: "ctx-1",
      taskId: "t1", seq: 0, expiresAt: 2_000_000, envelope: ENVELOPE,
    }),
    wire: SessionBusAssignWire,
  },
  {
    msg: createMessage("session-bus:transition", {
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1",
      taskId: "t1", seq: 1, state: "working", waitingOn: "lead", envelope: ENVELOPE,
    }),
    wire: SessionBusTransitionWire,
  },
  {
    msg: createMessage("session-bus:cancel", {
      from: LEAD_KEY, to: PEER_KEY, contextId: "ctx-1", taskId: "t1", seq: 1, reason: "no longer needed",
    }),
    wire: SessionBusCancelWire,
  },
  {
    msg: createMessage("session-bus:message", {
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1", taskId: null, envelope: ENVELOPE,
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
      from: PEER_KEY, to: LEAD_KEY, contextId: "ctx-1", taskId: "t1", seq: 0, ok: true,
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
    const bad = { ...SAMPLES[0]!.msg, seq: -1 };
    expect(SessionBusAssignWire.safeParse(bad).success).toBe(false);
  });

  test("no bus frame is checkout-variable", () => {
    // A task addresses a session, and a session's checkout is resolved from that
    // id — routing one by checkoutId would let a carrier name a working tree.
    for (const { msg } of SAMPLES) {
      expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has(msg.type as never)).toBe(false);
    }
  });

  test("no bus frame is replayed to a late joiner", () => {
    // Task traffic is addressed and acked; replaying it on connect would hand a
    // phone the exchange it must never see, and re-deliver a frame whose ack
    // already retired it.
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

  test("the owner socket sees a task frame and a bus subscriber never does", async () => {
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
      projectId: "p-lead",
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
      projectId: "p-peer",
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

  function assign(): string {
    const res = lead.assign({
      sessionId: LEAD_REF.sessionId,
      peer: PEER_REF,
      summary: "run the suite",
      parts: [{ kind: "text", text: "run the suite" }],
    });
    if (!("ok" in res) || !res.ok) throw new Error(`assign refused: ${JSON.stringify(res)}`);
    return res.taskId;
  }

  // A carrier that ACCEPTS a frame and then finds nowhere to put it reports the
  // same `true` as one that delivered it, and the app has no way to say so back.
  // The retry loop is then the only witness, and for three hours it said nothing
  // at all — which is what this pins.
  test("a frame that keeps leaving with nothing acked is said out loud", () => {
    const lines: string[] = [];
    __setRootForTest({ write: (s: string) => (lines.push(s), true) }, "debug");
    try {
      assign();
      for (let i = 0; i < SESSION_BUS_UNACKED_WARN_ATTEMPTS + 2; i++) {
        now += 61_000;
        lead.pump();
      }
      const warned = lines.filter((l) => l.includes("with nothing acked"));
      expect(warned.length).toBe(1);
      expect(warned[0]).toContain(PEER_REF.sessionId);
      expect(warned[0]).toContain(PEER_REF.machineLabel!);
      // The frame really was accepted every time — this is the case that used to
      // leave no trace anywhere.
      expect(carried.length).toBeGreaterThan(SESSION_BUS_UNACKED_WARN_ATTEMPTS);
    } finally {
      __setRootForTest(process.stdout);
    }
  });

  test("an assign reaches the peer, is acked, and retires the lead's outbox", () => {
    const taskId = assign();
    expect(lead.task(LEAD_REF.sessionId, taskId)!.outbox).toHaveLength(1);

    const sent = drain();
    expect(sent).toHaveLength(1);
    expect(sent[0]!.type).toBe("session-bus:assign");

    expect(peer.task(PEER_REF.sessionId, taskId)!.role).toBe("peer");
    expect(peer.task(PEER_REF.sessionId, taskId)!.state).toBe("submitted");
    expect(peerEvents.map((e) => e.kind)).toEqual(["assigned"]);

    const acks = drain();
    expect(acks).toHaveLength(1);
    expect(acks[0]!.type).toBe("session-bus:ack");
    expect((acks[0] as { to: SessionMemberKey }).to).toEqual(LEAD_KEY);
    expect(lead.task(LEAD_REF.sessionId, taskId)!.outbox).toHaveLength(0);
  });

  test("a retried duplicate is acked again and applied once", () => {
    const taskId = assign();
    const [frame] = carried;
    drain();
    peerEvents.length = 0;
    carried.length = 0;

    // The retry a lost ack produces: byte-identical, and the peer must not
    // re-open work it already started.
    peer.handleInbound(frame!);
    expect(peerEvents).toEqual([]);
    expect(peer.task(PEER_REF.sessionId, taskId)!.state).toBe("submitted");
    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:ack");
  });

  test("the peer reports back addressed to the lead, and the lead acks it", () => {
    const taskId = assign();
    drain();
    drain();
    leadEvents.length = 0;

    const res = peer.report(
      { sessionId: PEER_REF.sessionId, taskId, summary: "started", parts: [{ kind: "text", text: "on it" }] },
      "working",
    );
    expect("ok" in res && res.ok).toBe(true);

    const sent = drain();
    expect(sent).toHaveLength(1);
    expect(sent[0]!.type).toBe("session-bus:transition");
    expect((sent[0] as { to: SessionMemberKey }).to).toEqual(LEAD_KEY);
    // The seq the peer minted, not the assign's: a report that reused seq 0
    // would be folded as the duplicate of the assign it answers.
    expect((sent[0] as { seq: number }).seq).toBeGreaterThan(0);

    expect(lead.task(LEAD_REF.sessionId, taskId)!.state).toBe("working");
    expect(leadEvents.map((e) => e.kind)).toEqual(["transitioned"]);

    drain();
    expect(peer.task(PEER_REF.sessionId, taskId)!.outbox).toHaveLength(0);
  });

  test("a frame naming a session this bridge does not hold is dropped without an ack", () => {
    // Acking it would tell the sender a task is being worked that nothing here
    // will ever work.
    const stray = createMessage("session-bus:assign", {
      from: LEAD_KEY,
      to: { machineId: "m-peer", projectId: "p-peer", sessionId: "s-nobody" },
      contextId: "ctx-x", taskId: "t-x", seq: 0, expiresAt: now + 1000, envelope: ENVELOPE,
    });
    // Reported as DROPPED, not merely "a bus frame": the agent core binds a
    // peer's only route home on this answer, so a frame naming somebody else's
    // session must not be able to claim it.
    expect(peer.handleInbound(stray)).toBe("dropped");
    expect(carried).toEqual([]);
    expect(peerEvents).toEqual([]);
  });

  test("an accepted frame is reported applied, so a route is bound only on one", () => {
    assign();
    const [frame] = carried;
    carried.length = 0;
    expect(peer.handleInbound(frame!)).toBe("applied");
  });

  test("a non-bus frame falls through", () => {
    expect(lead.handleInbound(createMessage("terminal:input", { terminalId: "t", data: "x" }))).toBe(false);
  });

  test("with no carrier the task still exists and the frame is retried later", () => {
    carrierUp = false;
    const taskId = assign();
    expect(carried).toEqual([]);
    const held = lead.task(LEAD_REF.sessionId, taskId)!.outbox[0]!;
    // Due again immediately rather than a backoff step out: a send that never
    // left is not an attempt, and spending the schedule on an untouched link is
    // what makes a reconnect feel dead (D11).
    expect(held.nextAttemptAt).toBe(now);

    carrierUp = true;
    lead.pump();
    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:assign");
  });

  test("a restart resumes retrying from disk", () => {
    carrierUp = false;
    const taskId = assign();
    lead.stop();

    const resumed = new SessionBusCoordinator({
      abDir: join(dir, "lead"),
      projectId: "p-lead",
      self: selfFor(LEAD_REF),
      send: (frame) => { carried.push(frame); return true; },
      now: () => now,
      newId: () => "id-restart",
    });
    // `resume`, not a load naming the session: a fresh process holds no sessions
    // and nothing else is going to name this one, so without the enumeration the
    // report the dead process queued simply never goes (D11).
    resumed.resume();
    expect(resumed.task(LEAD_REF.sessionId, taskId)!.state).toBe("submitted");
    resumed.pump();
    resumed.stop();

    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:assign");
    expect((carried[0] as { taskId: string }).taskId).toBe(taskId);
  });

  test("a peer's taskless finding is routed home, not defaulted to the lead route", () => {
    const taskId = assign();
    drain();
    drain();
    routes.length = 0;
    const contextId = peer.task(PEER_REF.sessionId, taskId)!.contextId;

    // No taskId: an aside about work in progress. The route has to come from the
    // SESSION's side of the context — a "lead" route on a peer machine posts the
    // finding to that machine's own desktop app, which accepts it and reports it
    // sent.
    const res = peer.message({
      sessionId: PEER_REF.sessionId,
      taskId: null,
      to: LEAD_REF,
      contextId,
      summary: "an aside",
      parts: [{ kind: "text", text: "an aside" }],
    });
    expect("ok" in res && res.ok).toBe(true);
    expect(routes).toHaveLength(1);
    expect(routes[0]!.role).toBe("peer");
  });

  test("a retried frame does not spend the no-progress budget", () => {
    assign();
    const [frame] = carried;
    drain();

    // The retries a flaky carrier produces. Spending the budget on them halts a
    // session for the LINK's behaviour rather than the agents' (spec 8), and the
    // halt is persisted.
    for (let i = 0; i < NO_PROGRESS_EXCHANGES + 2; i += 1) peer.handleInbound(frame!);
    expect(peer.budget(PEER_REF.sessionId).halted).toBe(false);
  });

  test("a halted session is taken off hold by a human, and only by a human", () => {
    const taskId = assign();
    drain();
    const contextId = lead.task(LEAD_REF.sessionId, taskId)!.contextId;

    // Findings that move nothing: the loop the guard exists to stop.
    for (let i = 0; i < NO_PROGRESS_EXCHANGES; i += 1) {
      const res = lead.message({
        sessionId: LEAD_REF.sessionId,
        taskId: null,
        to: PEER_REF,
        contextId,
        summary: `note ${i}`,
        parts: [{ kind: "text", text: `note ${i}` }],
      });
      expect("ok" in res && res.ok).toBe(true);
    }
    expect(lead.budget(LEAD_REF.sessionId).halted).toBe(true);

    // The halt is on disk, so with no way to lift it the session could never
    // assign again — for the life of the checkout, across restarts.
    lead.clearHalt(LEAD_REF.sessionId);
    expect(lead.budget(LEAD_REF.sessionId).halted).toBe(false);
  });

  test("a human at this machine pauses the clock on the tasks this session is working", () => {
    const taskId = assign();
    drain();

    peer.humanBlocked(PEER_REF.sessionId, true);
    expect(peer.task(PEER_REF.sessionId, taskId)!.waitingOn).toBe("human");
    expect(peer.task(PEER_REF.sessionId, taskId)!.pausedAt).toBe(now);

    peer.humanBlocked(PEER_REF.sessionId, false);
    expect(peer.task(PEER_REF.sessionId, taskId)!.waitingOn).toBeUndefined();

    // A session this coordinator never loaded is not hydrated on a status edge:
    // every session in the project reaches this, and nearly none are on a bus.
    peer.humanBlocked("s-not-on-any-bus", true);
    peer.clearHalt("s-not-on-any-bus");
  });

  test("a session with no membership is refused rather than given an address", () => {
    const res = lead.assign({
      sessionId: "s-not-a-member",
      peer: PEER_REF,
      summary: "x",
      parts: [{ kind: "text", text: "x" }],
    });
    expect("ok" in res && res.ok).toBe(false);
    expect((res as { code: string }).code).toBe("NOT_MEMBER");
  });

  test("a cancel is sequenced, acked, and terminal on both ends", () => {
    const taskId = assign();
    drain();
    drain();

    const res = lead.cancel(LEAD_REF.sessionId, taskId, "no longer needed");
    expect("ok" in res && res.ok).toBe(true);
    const sent = drain();
    expect(sent[0]!.type).toBe("session-bus:cancel");
    expect(peer.task(PEER_REF.sessionId, taskId)!.state).toBe("canceled");

    drain();
    expect(lead.task(LEAD_REF.sessionId, taskId)!.outbox).toHaveLength(0);
    expect(lead.task(LEAD_REF.sessionId, taskId)!.state).toBe("canceled");
  });

  test("an unsequenced message is delivered but never queued for retry", () => {
    const taskId = assign();
    drain();
    drain();

    const res = peer.message({
      sessionId: PEER_REF.sessionId,
      taskId,
      to: LEAD_REF,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });
    expect("ok" in res && res.ok).toBe(true);
    expect((res as { sent: boolean }).sent).toBe(true);
    // Never the outbox: that queue is stop-and-wait (D13), so a finding parked
    // in it would block the next transition on the task behind an unacked note.
    expect(peer.task(PEER_REF.sessionId, taskId)!.outbox).toHaveLength(0);

    const sent = drain();
    expect(sent).toHaveLength(1);
    expect(sent[0]!.type).toBe("session-bus:message");
    expect(leadEvents.some((e) => e.kind === "message")).toBe(true);
    // A message is not acked — an ack would make a lossy note stop-and-wait.
    expect(carried).toEqual([]);
  });

  // D13 lets a message be lost and gives it nothing to dedup by, so one already
  // on the wire can never be resent. One the transport REFUSED is a different
  // frame: it never reached the relay, so putting it out later is a delivery and
  // not a second copy — and it is the case that decides whether a peer keeps its
  // finding across the seconds its carrier is away.
  test("a refused message is held and goes once when a route returns", () => {
    const taskId = assign();
    drain();
    drain();
    carrierUp = false;

    const res = peer.message({
      sessionId: PEER_REF.sessionId,
      taskId,
      to: LEAD_REF,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });
    expect(res).toMatchObject({ ok: true, sent: false, held: true });
    // Held is not queued: the task's own outbox stays free for transitions.
    expect(peer.task(PEER_REF.sessionId, taskId)!.outbox).toHaveLength(0);
    expect(carried).toEqual([]);

    carrierUp = true;
    peer.pump();
    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:message");

    carried.length = 0;
    peer.pump();
    expect(carried).toEqual([]);
  });

  test("a held message survives a restart of the machine that could not send it", () => {
    const taskId = assign();
    drain();
    drain();
    carrierUp = false;
    peer.message({
      sessionId: PEER_REF.sessionId,
      taskId,
      to: LEAD_REF,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });
    peer.stop();
    carried.length = 0;

    const resumed = new SessionBusCoordinator({
      abDir: join(dir, "peer"),
      projectId: "p-peer",
      self: selfFor(PEER_REF),
      send: (frame) => { carried.push(frame); return true; },
      now: () => now,
      newId: () => "id-restart-msg",
    });
    resumed.resume();
    resumed.pump();
    resumed.stop();

    expect(carried).toHaveLength(1);
    expect(carried[0]!.type).toBe("session-bus:message");
  });

  test("a held message stops being worth delivering once its task would have lapsed", () => {
    const taskId = assign();
    drain();
    drain();
    carrierUp = false;
    peer.message({
      sessionId: PEER_REF.sessionId,
      taskId,
      to: LEAD_REF,
      summary: "a finding",
      parts: [{ kind: "text", text: "the suite is red" }],
    });

    now += HELD_MESSAGE_TTL_MS;
    carrierUp = true;
    peer.pump();
    // The lossiness D13 asks for, spent where it costs least: a finding about
    // work the lead has already given up on arrives as noise, not as news.
    expect(carried.filter((f) => f.type === "session-bus:message")).toEqual([]);
  });
});
