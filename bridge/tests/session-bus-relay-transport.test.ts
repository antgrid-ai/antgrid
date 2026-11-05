import { afterEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { BusRefusalReason, type BusClientMessage, type BusServerMessage, type MachineEntry } from "antgrid-wire";
import { generateEphemeralKeypair } from "../src/key-exchange";
import { __setRootForTest } from "../src/logger";
import {
  BUS_LINK_BURST,
  MAX_PENDING_INBOUND,
  RelayBusTransport,
  type InboundVerdict,
  type RelayBusTransportDeps,
  type SeenRow,
  type TransportOutcome,
  type VerifiedInbound,
} from "../src/session-bus/relay-transport";
import { openBus, sealBus, signBusAck, verifyBusAck, type InnerHeader } from "../src/session-bus/seal";
import type { BusHeldReason } from "../src/session-bus/relay-transport";
import * as errorsModule from "../src/session-bus/errors";

function ed25519Pair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const seed = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32);
  const pub = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  return { seed: Buffer.from(seed).toString("base64"), pub: Buffer.from(pub).toString("base64") };
}

function busPair() {
  const k = generateEphemeralKeypair();
  return { privateKey: k.privateKey.toString("base64"), publicKey: k.publicKey.toString("base64") };
}

const self = { id: randomUUID(), sign: ed25519Pair(), bus: busPair() };
const peer = { id: randomUUID(), sign: ed25519Pair(), bus: busPair() };
const other = { id: randomUUID(), sign: ed25519Pair(), bus: busPair() };

const wait = (ms = 20) => new Promise((r) => setTimeout(r, ms));
const POST = { type: "session-bus:post", data: { hello: "world" } } as never;

function entry(m: typeof peer, over: Partial<MachineEntry> = {}): MachineEntry {
  return {
    deviceId: m.id, displayName: "peer", machineName: null, ed25519Pub: m.sign.pub,
    busPublicKey: m.bus.publicKey, orchestrator: false, busControl: false, ...over,
  };
}

class FakeDirectory {
  entries: MachineEntry[] = [entry(peer)];
  hasView = true;
  allowed = true;
  kicks = 0;
  ensureCalls = 0;
  onEnsure: (() => void) | null = null;
  current() {
    return this.hasView ? ({ machines: this.entries, allowed: this.allowed } as never) : null;
  }
  machine(id: string) {
    return this.hasView ? (this.entries.find((e) => e.deviceId === id) ?? null) : null;
  }
  busKeyFor(id: string) {
    return this.hasView && this.allowed ? (this.entries.find((e) => e.deviceId === id)?.busPublicKey ?? null) : null;
  }
  selfOrchestrator() {
    return false;
  }
  async ensureFresh() {
    this.ensureCalls++;
    this.onEnsure?.();
    return this.hasView;
  }
  kick() {
    this.kicks++;
  }
}

class MemSeen {
  rows = new Map<string, SeenRow>();
  records: unknown[][] = [];
  get(from: string, id: string) {
    return this.rows.get(`${from}/${id}`) ?? null;
  }
  record(from: string, id: string, outcome: "applied" | "refused", code: string | undefined, expiresAt: number, response?: string) {
    this.records.push([from, id, outcome, code, expiresAt, response]);
    this.rows.set(`${from}/${id}`, { outcome, code, response });
  }
}

function harness(over: Partial<RelayBusTransportDeps> = {}) {
  const sent: BusClientMessage[] = [];
  const outcomes: Array<{ id: string; to: string; outcome: TransportOutcome }> = [];
  const inbound: VerifiedInbound[] = [];
  const replays: unknown[][] = [];
  // `clock` is the relay-corrected clock; `local` is the one send inputs are
  // stamped on, and follows `clock` unless a test pulls them apart.
  const state = {
    link: "ready" as "ready" | "offline" | "unsupported", accept: true, clock: 1_000_000_000, remote: true,
    local: null as number | null,
  };
  const dir = new FakeDirectory();
  const seen = new MemSeen();
  const verdict: { next: () => Promise<InboundVerdict> } = { next: async () => ({ outcome: "applied" }) };
  const deps: RelayBusTransportDeps = {
    selfDeviceId: () => self.id,
    signSeed: () => self.sign.seed,
    busKey: () => self.bus,
    directory: dir as never,
    link: () => ({
      sendBus: (f: BusClientMessage) => {
        if (!state.accept) return false;
        sent.push(f);
        return true;
      },
      busLinkState: () => state.link,
      busNow: () => state.clock,
    }),
    localNow: () => state.local ?? state.clock,
    remoteAccessEnabled: () => state.remote,
    seen,
    onInbound: async (v) => {
      inbound.push(v);
      return verdict.next();
    },
    onOutcome: (id, to, outcome) => outcomes.push({ id, to, outcome }),
    onReplayResponse: (...a) => replays.push(a),
    ...over,
  };
  const t = new RelayBusTransport(deps);
  live.push(t);
  return { t, sent, outcomes, inbound, replays, state, dir, seen, verdict };
}

const live: RelayBusTransport[] = [];
afterEach(() => {
  for (const t of live.splice(0)) t.stop();
});

function sendInput(over: Record<string, unknown> = {}) {
  return {
    to: peer.id, id: randomUUID(), kind: "message" as const, body: POST,
    sentAt: 1_000_000_000, expiresAt: 1_000_000_000 + 60_000, role: "agent" as const, ...over,
  };
}

function deliver(over: { from?: typeof peer; id?: string; header?: Partial<InnerHeader>; body?: string; to?: typeof self } = {}) {
  const from = over.from ?? peer;
  const id = over.id ?? randomUUID();
  const header: InnerHeader = {
    v: 1, from: from.id, to: self.id, id, role: "agent", kind: "message",
    sentAt: 1_000_000_000, expiresAt: 1_000_000_000 + 60_000, ...over.header,
  };
  const r = sealBus({
    header, body: over.body ?? JSON.stringify(POST), signSeedB64: from.sign.seed,
    recipientBusPubB64: (over.to ?? self).bus.publicKey,
  });
  if (!r.ok) throw new Error(r.code);
  return { type: "bus:deliver", id, from: from.id, blob: r.blob } as BusServerMessage;
}

function acks(sent: BusClientMessage[]) {
  return sent.filter((f): f is Extract<BusClientMessage, { type: "bus:ack" }> => f.type === "bus:ack");
}

function expectAckVerifies(f: Extract<BusClientMessage, { type: "bus:ack" }>, from = peer.id) {
  expect(verifyBusAck(self.sign.pub, { from, to: self.id, id: f.id, outcome: f.outcome, code: f.code }, f.sig)).toBe(true);
}

describe("outbound send", () => {
  test("seals to the recipient's key and sends a bus:send the recipient opens", () => {
    const h = harness();
    const input = sendInput();
    expect(h.t.send(input)).toEqual({ sent: true });
    const f = h.sent[0]!;
    expect(f.type).toBe("bus:send");
    if (f.type !== "bus:send") return;
    expect(f.id).toBe(input.id);
    expect(f.ttlMs).toBe(60_000);
    const opened = openBus({
      blob: f.blob, from: self.id, to: peer.id, id: input.id,
      ownBusPrivB64: peer.bus.privateKey, ownBusPubB64: peer.bus.publicKey, senderEd25519PubB64: self.sign.pub,
    });
    expect(opened.ok).toBe(true);
    if (opened.ok) {
      expect(JSON.parse(opened.body)).toEqual(POST);
      expect(opened.header.sentAt).toBe(h.state.clock);
      expect(opened.header.expiresAt).toBe(h.state.clock + 60_000);
    }
  });

  test("header times come from the relay-corrected clock and the ttl is capped", () => {
    const h = harness();
    h.state.clock = 5_000_000_000;
    h.state.local = 2_000_000_000;
    h.t.send(sendInput({ sentAt: 2_000_000_000, expiresAt: 2_000_000_000 + 100 * 3_600_000 }));
    const f = h.sent[0]!;
    if (f.type !== "bus:send") throw new Error("shape");
    expect(f.ttlMs).toBe(6 * 3_600_000);
    const opened = openBus({
      blob: f.blob, from: self.id, to: peer.id, id: f.id,
      ownBusPrivB64: peer.bus.privateKey, ownBusPubB64: peer.bus.publicKey, senderEd25519PubB64: self.sign.pub,
    });
    if (!opened.ok) throw new Error(opened.code);
    expect(opened.header.sentAt).toBe(5_000_000_000);
    expect(opened.header.expiresAt).toBe(5_000_000_000 + 6 * 3_600_000);
  });

  test("a resend keeps the expiry of the first send", () => {
    const h = harness();
    const hour = 3_600_000;
    const input = sendInput({ sentAt: h.state.clock, expiresAt: h.state.clock + 6 * hour });
    h.state.local = h.state.clock + 5 * hour;
    h.state.clock += 5 * hour;
    expect(h.t.send(input)).toEqual({ sent: true });
    const f = h.sent[0]!;
    if (f.type !== "bus:send") throw new Error("shape");
    expect(f.ttlMs).toBe(hour);
    const opened = openBus({
      blob: f.blob, from: self.id, to: peer.id, id: f.id,
      ownBusPrivB64: peer.bus.privateKey, ownBusPubB64: peer.bus.publicKey, senderEd25519PubB64: self.sign.pub,
    });
    if (!opened.ok) throw new Error(opened.code);
    expect(opened.header.expiresAt).toBe(input.expiresAt);
    expect(opened.header.sentAt).toBe(input.sentAt);
  });

  test("a resend past its expiry is refused EXPIRED before sealing or pacing", () => {
    const h = harness();
    const input = sendInput();
    h.state.local = input.expiresAt;
    expect(h.t.send(input)).toEqual({ sent: false, refused: "EXPIRED" });
    expect(h.sent).toHaveLength(0);
    h.state.local = null;
    for (let n = 0; n < BUS_LINK_BURST; n++) expect(h.t.send(sendInput())).toEqual({ sent: true });
  });

  test("remote access off refuses every kind before sealing", () => {
    const h = harness();
    h.state.remote = false;
    for (const kind of ["message", "request", "response"] as const) {
      expect(h.t.send(sendInput({ kind }))).toEqual({ sent: false, reason: "remote-access-off" });
    }
    expect(h.sent).toHaveLength(0);
    expect(h.dir.kicks).toBe(0);
  });

  test("each held reason", () => {
    const reason = (r: ReturnType<RelayBusTransport["send"]>) => (r as { reason?: string }).reason;

    let h = harness();
    expect(reason(h.t.send(sendInput({ to: "local" })))).toBe("no-transport");
    expect(reason(h.t.send(sendInput({ to: self.id })))).toBe("no-transport");

    h = harness({ link: () => null });
    expect(reason(h.t.send(sendInput()))).toBe("no-transport");

    h = harness({ link: () => ({ busLinkState: () => "ready" }) });
    expect(reason(h.t.send(sendInput()))).toBe("relay-unsupported");

    h = harness();
    h.state.link = "offline";
    expect(reason(h.t.send(sendInput()))).toBe("central-offline");
    h.state.link = "unsupported";
    expect(reason(h.t.send(sendInput()))).toBe("relay-unsupported");

    h = harness();
    h.dir.hasView = false;
    expect(reason(h.t.send(sendInput()))).toBe("directory-unavailable");
    expect(h.dir.kicks).toBe(1);

    h = harness();
    h.dir.entries = [entry(peer, { busPublicKey: null })];
    expect(reason(h.t.send(sendInput()))).toBe("no-bus-key");
    expect(h.dir.kicks).toBe(1);

    h = harness();
    h.dir.entries = [];
    expect(reason(h.t.send(sendInput()))).toBe("no-bus-key");

    h = harness();
    h.state.accept = false;
    expect(reason(h.t.send(sendInput()))).toBe("central-offline");

    h = harness({ signSeed: () => null });
    expect(reason(h.t.send(sendInput()))).toBe("no-transport");
  });

  test("an oversized body is refused terminally and spends no pacing", () => {
    const h = harness();
    const big = { type: "session-bus:post", data: "x".repeat(100_000) } as never;
    expect(h.t.send(sendInput({ body: big }))).toEqual({ sent: false, refused: "PLAINTEXT_TOO_LARGE" });
    expect(h.sent).toHaveLength(0);
  });

  test("pacing allows the burst then holds as paced, and refills with time", () => {
    const h = harness();
    for (let n = 0; n < BUS_LINK_BURST; n++) expect(h.t.send(sendInput())).toEqual({ sent: true });
    expect(h.t.send(sendInput())).toEqual({ sent: false, reason: "paced" });
    h.state.clock += 1_000;
    expect(h.t.send(sendInput())).toEqual({ sent: true });
  });
});

describe("outbound outcomes", () => {
  test("a receipt is relayed", () => {
    const h = harness();
    const id = randomUUID();
    h.t.handleFrame({ type: "bus:receipt", id, to: peer.id, state: "queued" });
    h.t.handleFrame({ type: "bus:receipt", id, to: peer.id, state: "delivered-to-socket" });
    expect(h.outcomes.map((o) => o.outcome)).toEqual([{ kind: "relayed" }, { kind: "relayed" }]);
  });

  function ackedFrame(signer: typeof peer, over: Partial<{ id: string; outcome: "applied" | "refused"; code: string }> = {}) {
    const id = over.id ?? randomUUID();
    const outcome = over.outcome ?? "applied";
    const code = outcome === "refused" ? (over.code ?? "STALE") : undefined;
    const sig = signBusAck(signer.sign.seed, { from: self.id, to: peer.id, id, outcome, code });
    return { type: "bus:acked", id, to: peer.id, outcome, ...(code ? { code } : {}), sig } as BusServerMessage;
  }

  test("a verified applied ack applies; a verified refusal is terminal", () => {
    const h = harness();
    h.t.handleFrame(ackedFrame(peer));
    h.t.handleFrame(ackedFrame(peer, { outcome: "refused", code: "NOT_ALLOWED_AGENT_REACH" }));
    expect(h.outcomes.map((o) => o.outcome)).toEqual([
      { kind: "applied" },
      { kind: "refused", code: "NOT_ALLOWED_AGENT_REACH" },
    ]);
  });

  test("a bad signature or another machine's signature is ack-unverified, never applied", () => {
    const h = harness();
    h.t.handleFrame(ackedFrame(other));
    const good = ackedFrame(peer) as Extract<BusServerMessage, { type: "bus:acked" }>;
    h.t.handleFrame({ ...good, outcome: "refused", code: "STALE" });
    expect(h.outcomes.map((o) => o.outcome)).toEqual([
      { kind: "retry", reason: "ack-unverified" },
      { kind: "retry", reason: "ack-unverified" },
    ]);
    expect(h.dir.kicks).toBe(0);
  });

  test("an ack from a machine missing from the directory is unverified and kicks", () => {
    const h = harness();
    h.dir.entries = [];
    h.t.handleFrame(ackedFrame(peer));
    expect(h.outcomes[0]!.outcome).toEqual({ kind: "retry", reason: "ack-unverified" });
    expect(h.dir.kicks).toBe(1);
  });

  test("a verified UNOPENABLE refusal means the recipient key is stale", () => {
    const h = harness();
    h.t.handleFrame(ackedFrame(peer, { outcome: "refused", code: "UNOPENABLE" }));
    expect(h.outcomes[0]!.outcome).toEqual({ kind: "retry", reason: "recipient-key-stale" });
    expect(h.dir.kicks).toBe(1);
  });

  test("every relay refusal reason maps", () => {
    const expected: Record<BusRefusalReason, { retryable: boolean; outcome: TransportOutcome }> = {
      "queue-full": { retryable: true, outcome: { kind: "retry", reason: "relay-queue-full" } },
      "rate-limited": { retryable: true, outcome: { kind: "retry", reason: "relay-rate-limited" } },
      "recipient-outdated": { retryable: true, outcome: { kind: "retry", reason: "relay-recipient-outdated" } },
      "not-agent": { retryable: false, outcome: { kind: "refused", code: "RELAY_NOT_AGENT" } },
      self: { retryable: false, outcome: { kind: "refused", code: "RELAY_SELF" } },
      expired: { retryable: false, outcome: { kind: "refused", code: "EXPIRED" } },
    };
    for (const reason of BusRefusalReason.options) {
      const h = harness();
      h.t.handleFrame({ type: "bus:refused", id: randomUUID(), to: peer.id, reason, retryable: expected[reason].retryable });
      expect(h.outcomes[0]!.outcome).toEqual(expected[reason].outcome);
    }
  });

  test("a retryable flag that disagrees with the reason never becomes terminal", () => {
    const h = harness();
    h.t.handleFrame({ type: "bus:refused", id: randomUUID(), to: peer.id, reason: "expired", retryable: true });
    h.t.handleFrame({ type: "bus:refused", id: randomUUID(), to: peer.id, reason: "queue-full", retryable: false });
    expect(h.outcomes.map((o) => o.outcome.kind)).toEqual(["retry", "retry"]);
    expect(h.outcomes[1]!.outcome).toEqual({ kind: "retry", reason: "relay-queue-full" });
  });
});

describe("inbound deliver", () => {
  test("opens, applies, records, and acks with a verifying signature", async () => {
    const h = harness();
    const m = deliver();
    h.t.handleFrame(m);
    await wait();
    expect(h.inbound).toHaveLength(1);
    expect(h.inbound[0]!.from).toBe(peer.id);
    expect(h.inbound[0]!.body).toEqual(POST);
    expect(h.seen.records).toHaveLength(1);
    const a = acks(h.sent);
    expect(a).toHaveLength(1);
    expect(a[0]).toMatchObject({ id: (m as { id: string }).id, outcome: "applied" });
    expectAckVerifies(a[0]!);
  });

  test("a handler refusal is recorded and acked with its code", async () => {
    const h = harness();
    h.verdict.next = async () => ({ outcome: "refused", code: "NOT_ALLOWED_AGENT_REACH" });
    h.t.handleFrame(deliver());
    await wait();
    const a = acks(h.sent);
    expect(a[0]).toMatchObject({ outcome: "refused", code: "NOT_ALLOWED_AGENT_REACH" });
    expectAckVerifies(a[0]!);
    expect(h.seen.records[0]!.slice(2, 4)).toEqual(["refused", "NOT_ALLOWED_AGENT_REACH"]);
  });

  test("own deliveries are dropped silently", async () => {
    const h = harness();
    h.t.handleFrame({ ...(deliver() as object), from: self.id } as BusServerMessage);
    await wait();
    expect(h.inbound).toHaveLength(0);
    expect(h.sent).toHaveLength(0);
  });

  test("an unlisted sender is refused UNKNOWN_SENDER only after a refresh, and a missing view defers", async () => {
    const h = harness();
    h.dir.entries = [];
    h.t.handleFrame(deliver());
    await wait();
    expect(h.dir.ensureCalls).toBe(1);
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "refused", code: "UNKNOWN_SENDER" });

    const d = harness();
    d.dir.hasView = false;
    d.t.handleFrame(deliver());
    await wait();
    expect(d.dir.ensureCalls).toBe(1);
    expect(acks(d.sent)).toHaveLength(0);
    expect(d.inbound).toHaveLength(0);
  });

  test("a sender the refresh adds is applied, not refused", async () => {
    const h = harness();
    h.dir.entries = [];
    h.dir.onEnsure = () => {
      h.dir.entries = [entry(peer)];
    };
    h.t.handleFrame(deliver());
    await wait();
    expect(h.dir.ensureCalls).toBe(1);
    expect(acks(h.sent)).toHaveLength(1);
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "applied" });
  });

  test("an unlisted sender whose refresh fails defers without an ack", async () => {
    const h = harness();
    h.dir.entries = [];
    h.dir.ensureFresh = async () => {
      h.dir.ensureCalls++;
      return false;
    };
    h.t.handleFrame(deliver());
    await wait();
    expect(h.dir.ensureCalls).toBe(1);
    expect(acks(h.sent)).toHaveLength(0);
    expect(h.inbound).toHaveLength(0);
    expect(h.seen.records).toHaveLength(0);
  });

  test("an account the directory does not allow defers instead of refusing", async () => {
    const h = harness();
    h.dir.allowed = false;
    h.dir.entries = [];
    h.t.handleFrame(deliver());
    await wait();
    expect(h.dir.ensureCalls).toBe(1);
    expect(acks(h.sent)).toHaveLength(0);
    expect(h.inbound).toHaveLength(0);
    expect(h.seen.records).toHaveLength(0);
  });

  test("a view that arrives during the bounded wait is used", async () => {
    const h = harness();
    h.dir.hasView = false;
    h.dir.onEnsure = () => {
      h.dir.hasView = true;
    };
    h.t.handleFrame(deliver());
    await wait();
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "applied" });
  });

  test("no own bus key or no signing seed defers without an ack", async () => {
    const a = harness({ busKey: () => null });
    a.t.handleFrame(deliver());
    const b = harness({ signSeed: () => null });
    b.t.handleFrame(deliver());
    await wait();
    expect(acks(a.sent)).toHaveLength(0);
    expect(acks(b.sent)).toHaveLength(0);
    expect(a.inbound).toHaveLength(0);
  });

  test("a blob sealed to another key is refused UNOPENABLE", async () => {
    const h = harness();
    h.t.handleFrame(deliver({ to: other }));
    await wait();
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "refused", code: "UNOPENABLE" });
    expectAckVerifies(acks(h.sent)[0]!);
  });

  test("a message signed by a machine other than the claimed sender is refused BAD_SIGNATURE", async () => {
    const h = harness();
    h.dir.entries = [entry(peer, { ed25519Pub: other.sign.pub })];
    h.t.handleFrame(deliver());
    await wait();
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "refused", code: "BAD_SIGNATURE" });
  });

  test("a header with an impossible lifetime is refused MALFORMED", async () => {
    const h = harness();
    h.t.handleFrame(deliver({ header: { sentAt: 5, expiresAt: 5 } }));
    await wait();
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "refused", code: "MALFORMED" });
  });

  test("a stale message is refused STALE and a sender clock 10 min ahead is not", async () => {
    const h = harness();
    h.t.handleFrame(deliver({ header: { sentAt: 1_000_000_000 - 3_600_000, expiresAt: 1_000_000_000 - 3_000_000 } }));
    h.t.handleFrame(deliver({ header: { sentAt: 1_000_000_000 + 600_000, expiresAt: 1_000_000_000 + 660_000 } }));
    await wait();
    const a = acks(h.sent);
    expect(a[0]).toMatchObject({ outcome: "refused", code: "STALE" });
    expect(a[1]).toMatchObject({ outcome: "applied" });
    expect(h.inbound).toHaveLength(1);
  });

  test("a body that is not JSON is refused MALFORMED", async () => {
    const h = harness();
    h.t.handleFrame(deliver({ body: "not json" }));
    await wait();
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "refused", code: "MALFORMED" });
    expect(h.inbound).toHaveLength(0);
  });

  test("a duplicate is re-acked from seen without applying again", async () => {
    const h = harness();
    const m = deliver();
    h.t.handleFrame(m);
    await wait();
    h.t.handleFrame(m);
    await wait();
    expect(h.inbound).toHaveLength(1);
    const a = acks(h.sent);
    expect(a).toHaveLength(2);
    expect(a.map((x) => x.outcome)).toEqual(["applied", "applied"]);
    a.forEach((x) => expectAckVerifies(x));
  });

  test("a duplicate refusal re-acks the stored code", async () => {
    const h = harness();
    h.verdict.next = async () => ({ outcome: "refused", code: "UNKNOWN_PEER" });
    const m = deliver();
    h.t.handleFrame(m);
    await wait();
    h.t.handleFrame(m);
    await wait();
    expect(h.inbound).toHaveLength(1);
    expect(acks(h.sent).map((x) => x.code)).toEqual(["UNKNOWN_PEER", "UNKNOWN_PEER"]);
  });

  test("a duplicate whose seen row holds a response replays it", async () => {
    const h = harness();
    h.verdict.next = async () => ({ outcome: "applied", response: '{"r":1}' });
    const m = deliver();
    const reqId = (m as { id: string }).id;
    h.t.handleFrame(m);
    await wait();
    expect(h.seen.records[0]![5]).toBe('{"r":1}');
    expect(h.replays).toHaveLength(0);
    h.t.handleFrame(m);
    await wait();
    expect(h.inbound).toHaveLength(1);
    expect(h.replays).toHaveLength(1);
    expect(h.replays[0]!.slice(0, 3)).toEqual([peer.id, reqId, '{"r":1}']);
  });

  test("defer sends no ack and records nothing, then a drain is requested", async () => {
    const h = harness();
    h.verdict.next = async () => ({ outcome: "defer" });
    h.t.handleFrame(deliver());
    await wait();
    expect(acks(h.sent)).toHaveLength(0);
    expect(h.seen.records).toHaveLength(0);
    expect(h.sent.filter((f) => f.type === "bus:drain")).toHaveLength(1);
  });

  test("a throwing handler defers", async () => {
    const h = harness();
    h.verdict.next = async () => {
      throw new Error("boom");
    };
    h.t.handleFrame(deliver());
    await wait();
    expect(acks(h.sent)).toHaveLength(0);
    expect(h.sent.filter((f) => f.type === "bus:drain")).toHaveLength(1);
  });

  test("drain is throttled: a second defer inside the interval waits", async () => {
    const h = harness();
    h.verdict.next = async () => ({ outcome: "defer" });
    h.t.handleFrame(deliver());
    await wait();
    h.t.handleFrame(deliver());
    await wait();
    expect(h.sent.filter((f) => f.type === "bus:drain")).toHaveLength(1);
    h.state.clock += 6_000;
    h.t.handleFrame(deliver());
    await wait();
    expect(h.sent.filter((f) => f.type === "bus:drain")).toHaveLength(2);
  });

  test("order is preserved across an async handler", async () => {
    const h = harness();
    const order: string[] = [];
    let n = 0;
    h.verdict.next = async () => {
      const mine = n++;
      await wait(mine === 0 ? 40 : 1);
      order.push(String(mine));
      return { outcome: "applied" };
    };
    const ids = [deliver(), deliver(), deliver()];
    ids.forEach((m) => h.t.handleFrame(m));
    await wait(150);
    expect(order).toEqual(["0", "1", "2"]);
    expect(acks(h.sent).map((a) => a.id)).toEqual(ids.map((m) => (m as { id: string }).id));
  });

  test("deliveries past the pending cap are skipped unacked and a drain follows", async () => {
    const h = harness();
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => (release = r));
    h.verdict.next = async () => {
      await gate;
      return { outcome: "applied" };
    };
    for (let n = 0; n < MAX_PENDING_INBOUND + 5; n++) h.t.handleFrame(deliver());
    release();
    await wait(200);
    expect(h.inbound).toHaveLength(MAX_PENDING_INBOUND);
    expect(h.sent.filter((f) => f.type === "bus:drain")).toHaveLength(1);
  });

  test("a forged orchestrator role is downgraded unless the directory vouches for it", async () => {
    const h = harness();
    h.t.handleFrame(deliver({ header: { role: "orchestrator" } }));
    await wait();
    expect(h.inbound[0]!.role).toBe("agent");

    h.dir.entries = [entry(peer, { orchestrator: true })];
    h.t.handleFrame(deliver({ header: { role: "orchestrator" } }));
    h.t.handleFrame(deliver({ header: { role: "agent" } }));
    await wait();
    expect(h.inbound[1]!.role).toBe("orchestrator");
    expect(h.inbound[2]!.role).toBe("agent");
  });

  test("remote access off still acks inbound mail", async () => {
    const h = harness();
    h.state.remote = false;
    h.verdict.next = async () => ({ outcome: "refused", code: "REMOTE_ACCESS_OFF" });
    h.t.handleFrame(deliver());
    await wait();
    expect(acks(h.sent)[0]).toMatchObject({ outcome: "refused", code: "REMOTE_ACCESS_OFF" });
  });

  test("acks are paced behind the shared bucket and flush as it refills", async () => {
    const h = harness();
    for (let n = 0; n < BUS_LINK_BURST; n++) h.t.send(sendInput());
    h.t.handleFrame(deliver());
    await wait();
    expect(acks(h.sent)).toHaveLength(0);
    h.state.clock += 1_000;
    await wait(200);
    expect(acks(h.sent)).toHaveLength(1);
  });

  test("onAuthenticated sends one drain", () => {
    const h = harness();
    h.t.onAuthenticated();
    expect(h.sent).toEqual([{ type: "bus:drain" }]);
  });

  test("a stopped transport ignores frames", async () => {
    const h = harness();
    h.t.stop();
    h.t.handleFrame(deliver());
    await wait();
    expect(h.inbound).toHaveLength(0);
  });
});

describe("logging", () => {
  test("no key, blob or content reaches the logs at any level", async () => {
    const lines: string[] = [];
    __setRootForTest({ write: (l: string) => (lines.push(l), true) }, "trace");
    try {
      const h = harness();
      const secret = "TOPSECRETCONTENT";
      const body = { type: "session-bus:post", data: { secret } } as never;
      h.t.send(sendInput({ body }));
      h.t.handleFrame(deliver({ body: JSON.stringify(body) }));
      h.t.handleFrame(deliver({ body: `${secret} not json` }));
      h.t.handleFrame({ type: "bus:acked", id: randomUUID(), to: peer.id, outcome: "applied", sig: "A".repeat(86) + "==" });
      await wait();
      const blob = (h.sent[0] as { blob: { box: string; epk: string } }).blob;
      const all = lines.join(String.fromCharCode(10));
      expect(lines.length).toBeGreaterThan(0);
      for (const leaked of [secret, self.bus.privateKey, self.sign.seed, blob.box, blob.epk]) {
        expect(all).not.toContain(leaked);
      }
    } finally {
      __setRootForTest(process.stdout);
    }
  });
});

describe("vocabulary", () => {
  test("every held reason and relay code has a sentence in errors.ts", () => {
    const mod = errorsModule as Record<string, unknown>;
    const text = mod.BUS_HELD_REASON_TEXT as Record<string, string> | undefined;
    const reasons: BusHeldReason[] = [
      "no-transport", "central-offline", "relay-unsupported", "directory-unavailable", "no-bus-key", "paced",
      "remote-access-off", "relay-queue-full", "relay-rate-limited", "relay-recipient-outdated",
      "ack-unverified", "recipient-key-stale",
    ];
    expect(text).toBeDefined();
    for (const r of reasons) expect(typeof text?.[r]).toBe("string");
    const codes = mod.SESSION_BUS_ERRORS as Record<string, number>;
    for (const c of ["RELAY_NOT_AGENT", "RELAY_SELF", "EXPIRED", "UNKNOWN_SENDER", "UNOPENABLE", "BAD_SIGNATURE",
      "HEADER_MISMATCH", "MALFORMED", "STALE", "PLAINTEXT_TOO_LARGE", "REMOTE_ACCESS_OFF"]) {
      expect(codes[c]).toBeDefined();
    }
  });
});
