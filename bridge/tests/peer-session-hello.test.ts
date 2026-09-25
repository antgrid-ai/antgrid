// Stage B's establishment contract: a native peer gets in through exactly one
// door — a `session`-kind `session:hello` naming an admitted identity — and
// everything else about the session (attribution, the hello's own re-ack/
// violation rule) follows from `receivePeerFrame`/`handleHello` in
// peer-session-owner.ts. The lightweight tests here drive that seam directly
// through `TestPeerSessionOwner`; the two that must see a real close CODE
// (unauthorized vs. protocol-violation) drive the native layer, since only
// `NativeHostConnection` has a connection to close.
import { describe, expect, it, spyOn, test } from "bun:test";
import type { Connection } from "@number0/iroh";
import { MAX_TRANSFER_BYTES, PEER_ALPN, encodePeerFrame, encodeStreamOpen } from "antgrid-wire";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import { netwatch, __resetNetwatchForTest } from "../src/netwatch";
import { NativeHostConnection } from "../src/peer/native-host-connection";
import type { PairedPhonesStore } from "../src/paired-phones";
import { TestPeerSessionOwner, ed25519Pair } from "./test-peer-session-owner";
import vector from "../../evals/fixtures/endpoint-registration-vectors.json";

type SessionsMap = Map<string, Record<string, unknown>>;

function sessionsOf(client: TestPeerSessionOwner): SessionsMap {
  return (client as unknown as { sessions: SessionsMap }).sessions;
}

describe("establishment: the one door in", () => {
  it("H1: pre-establishment, a message-kind record is dropped pre-establishment and establishes nothing", () => {
    __resetNetwatchForTest();
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    client.setBus(bus);
    try {
      // The drop fires purely on "no session for this peer" (receivePeerFrame),
      // before any message shape or routing is even looked at.
      client.sendFromPeer("phone-1", createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }), "message");
      expect(received).toHaveLength(0);
      const drops = netwatch.snapshot().filter((e) => e.kind === "drop" && e.reason === "pre-establishment");
      expect(drops).toHaveLength(1);
      expect(client.peerSession("phone-1")).toBeNull();
    } finally { client.clearBus(); client.close(); }
  });

  it("H2: pre-establishment, a session:hello body sent with the message kind does not establish", () => {
    // `type` is the only discriminator between a liveness/session frame and a
    // control-plane message (peer-protocol.ts): a hello arriving under the
    // wrong header kind never reaches `onSessionFrame`/`handleHello` at all.
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    try {
      // Admitted first, so the only thing standing between this hello and an
      // established session is its header kind: an unadmitted peer would be
      // refused `not-admitted` whatever kind it used.
      (client as unknown as { admitPeer(peerId: string, pub: string): void }).admitPeer("phone-1", ed25519Pair().pubB64);
      client.sendFromPeer("phone-1", { type: "session:hello", attemptId: "a1" }, "message");
      expect(client.peerSession("phone-1")).toBeNull();
      client.sendFromPeer("phone-1", { type: "session:hello", attemptId: "a1" }, "session");
      expect(client.peerSession("phone-1")).not.toBeNull();
    } finally { client.close(); }
  });

  it("H3: an established message-kind {m: ...} body is dropped unrecognized-plaintext", () => {
    // The wire body of a `message`-kind record is a bare `AbMessage`, so an
    // envelope-wrapped one has no string `type` of its own and is dropped
    // rather than unwrapped.
    __resetNetwatchForTest();
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    client.establish("phone-1");
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    client.setBus(bus);
    try {
      client.sendFromPeer("phone-1", { m: createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }) }, "message");
      expect(received).toHaveLength(0);
      const drops = netwatch.snapshot().filter((e) => e.kind === "drop" && e.reason === "unrecognized-plaintext");
      expect(drops).toHaveLength(1);
    } finally { client.clearBus(); client.close(); }
  });

  it("H4: an established message-kind ping AbMessage reaches control-plane dispatch and is not answered with a liveness pong", () => {
    // `ping`/`pong` are ordinary AbMessage literals too (peer-protocol.ts's
    // own comment): on the `message` kind they are just control-plane
    // traffic, dispatched like any other verb, never auto-answered the way a
    // `session`-kind liveness ping is.
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    client.establish("phone-1");
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    client.setBus(bus);
    try {
      const ping = createMessage("ping", {});
      client.sendFromPeer("phone-1", ping, "message");
      expect(received).toEqual([ping]);
      expect(client.sentTo("phone-1")).toEqual([]);
    } finally { client.clearBus(); client.close(); }
  });

  it("H6: a control-plane message over MAX_TRANSFER_BYTES is too-large, writes nothing and reports MESSAGE_TOO_LARGE", async () => {
    // The app reads a session record only up to PEER_MAX_BRIDGE_RECORD_BYTES,
    // so an oversized record reaching the writer would retire the whole
    // connection app-side instead of dropping one message here.
    const errors: string[] = [];
    const client = TestPeerSessionOwner.forTest({
      sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1",
      options: { onError: (code) => errors.push(code) },
    });
    client.establish("phone-1");
    try {
      const huge = createMessage("agent:turn-start", { sessionId: "x".repeat(MAX_TRANSFER_BYTES), turnId: "t1" });
      const outcome = await (client as unknown as {
        sendControlPlane(msg: unknown, channel: string): Promise<string>;
      }).sendControlPlane(huge, "control");
      expect(outcome).toBe("too-large");
      expect(client.sentTo("phone-1")).toEqual([]);
      expect(errors).toEqual(["MESSAGE_TOO_LARGE"]);
    } finally { client.close(); }
  });

  it("H5: a credit session frame is dropped unknown-session-frame", () => {
    // An older app's `credit` must not reach dispatch: it falls through
    // `handleSessionFrame`'s default arm like any other unrecognized
    // session-frame type.
    __resetNetwatchForTest();
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    client.establish("phone-1");
    try {
      client.sendFromPeer("phone-1", { type: "credit", bytes: 1_024 }, "session");
      const drops = netwatch.snapshot().filter((e) => e.kind === "drop" && e.reason === "unknown-session-frame");
      expect(drops).toHaveLength(1);
    } finally { client.close(); }
  });

  it("a repeated hello naming the same attemptId re-acks without tearing down the session", () => {
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    const { attemptId } = client.establish("phone-1");
    try {
      const before = sessionsOf(client).get("phone-1");
      client.sendFromPeer("phone-1", { type: "session:hello", attemptId }, "session");
      expect(client.readToPeer("phone-1")).toEqual({ type: "established", attemptId });
      expect(sessionsOf(client).get("phone-1")).toBe(before);
    } finally { client.close(); }
  });

  it("a hello naming a different attemptId once established is a protocol violation and ends the session", () => {
    const client = TestPeerSessionOwner.forTest({ sendPayload: () => {}, peerId: "phone-1", deviceId: "dev-1" });
    client.establish("phone-1", { attemptId: "a1" });
    try {
      client.sendFromPeer("phone-1", { type: "session:hello", attemptId: "a2" }, "session");
      expect(client.peerSession("phone-1")).toBeNull();
    } finally { client.close(); }
    // The native layer's equivalent case, plus the CLOSE CODE that has no
    // meaning at this seam (no connection to close), is below.
  });
});

// --- The native layer: cases that need a real connection to close ---
//
// Newest-wins for the same endpoint (a second connection retiring a slow
// first) is covered in native-host-connection.test.ts; the cases below cover
// who may NOT evict an established holder.

function fixture(extra: {
  schedule?: (callback: () => void, ms: number) => () => void;
  pairedPhones?: PairedPhonesStore;
} = {}) {
  let allowed = true;
  const client = new NativeHostConnection({
    central: {
      url: "ws://localhost:1", identity: { deviceId: vector.challenge.deviceId, deviceName: "test", createdAt: "",
        ed25519PublicKey: vector.devicePublic, ed25519PrivateKey: vector.deviceSeed },
      getLicenseToken: () => "test-only",
    },
    native: {
      identity: { deviceId: vector.challenge.deviceId, deviceName: "test", createdAt: "",
        ed25519PublicKey: vector.devicePublic, ed25519PrivateKey: vector.deviceSeed },
      enrollment: vector.challenge, endpointSecret: vector.endpointSeed, licenseApiUrl: "https://backend.invalid",
      getLicenseToken: () => "test-only",
      remoteAccessEnabled: () => allowed,
      ...(extra.schedule ? { lifecycle: { schedule: extra.schedule } } : {}),
      ...(extra.pairedPhones ? { pairedPhones: extra.pairedPhones } : {}),
    },
  });
  const endpointId = "a".repeat(64);
  const peerId = "11111111-1111-4111-8111-111111111111";
  const snapshot = { accountId: vector.challenge.accountId, deviceId: vector.challenge.deviceId,
    enrollmentId: vector.challenge.enrollmentId, policyGeneration: "1", registrationGeneration: "1",
    allowed: true, leaseMs: 60_000, endpoint: { endpointId: vector.challenge.endpointId, generation: "1" },
    peers: [{ deviceId: peerId, ed25519Pub: vector.devicePublic, endpoint: { endpointId, generation: "1" } }], relayUrls: [] };
  const access = client.peers as unknown as {
    enrollment: { authorization: () => Promise<unknown> };
    acceptPeer: (connection: Connection) => Promise<void>;
    nativePeers: Map<string, unknown>;
  };
  access.enrollment.authorization = async () => snapshot;
  return { client, access, endpointId, peerId, snapshot, setAllowed: (value: boolean) => { allowed = value; } };
}

/** A1: every native bidi stream, the session stream included, opens with one
 *  `[u32 BE len][UTF-8 JSON StreamOpen]` record before it carries anything
 *  else (docs/iroh-reduction/stage-A-A1-contract.md §0). This prepends the
 *  default `{"kind":"session"}` record ahead of whatever a fixture below
 *  scripts for the session stream itself, so every fixture here keeps
 *  driving the SAME protocol content past the open-frame read `acceptPeer`
 *  now does first. */
function withSessionOpen<T extends { recv: { readExact: (length: number) => Promise<number[]> } }>(stream: T): T {
  const body = Array.from(encodeStreamOpen({ kind: "session" }));
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(body.length, 0);
  const record = { prefix: Array.from(prefix), body };
  let stage: 0 | 1 | 2 = 0;
  return {
    ...stream,
    recv: {
      readExact: async (length: number) => {
        if (stage === 0) { stage = 1; return record.prefix; }
        if (stage === 1) { stage = 2; return record.body; }
        return stream.recv.readExact(length);
      },
    },
  };
}

/** Same shape as native-host-connection.test.ts's `connection()`, plus the
 *  close CODE — the thing this file's two native tests exist to check.
 *
 *  Unlike that file's version, `firstStream` here arrives ALREADY wrapped
 *  with the session open frame — every caller below builds it from
 *  `pausableStream()`/`scriptedStream()`, which do that themselves so their
 *  own doc comments can describe the full stream shape in one place.
 *  Wrapping again here would inject a second open-frame record ahead of the
 *  real one, which the session-stream reader would misparse as the first
 *  actual frame and never reach the scripted data.
 *
 *  The default `firstStream` (no data ever scripted) still needs the open
 *  frame served — several tests below admit a peer that never says hello, or
 *  that the lease refuses, and both outcomes are decided only after the
 *  session stream's open frame is validated. */
function connection(endpointId: string, firstStream = Promise.resolve(withSessionOpen({
  send: { writeAll: async (_bytes: number[]) => {}, setPriority: async (_p: number) => {},
    reset: async (_code: bigint) => {}, finish: async () => {} },
  recv: { readExact: (_length: number) => new Promise<number[]>(() => {}) },
}))) {
  let streams = 0;
  const codes: bigint[] = [];
  const fake = {
    remoteId: () => ({ toString: () => endpointId }),
    alpn: () => Array.from(Buffer.from(PEER_ALPN)),
    setMaxConcurrentBiStreams: (_n: bigint) => {},
    acceptBi: () => streams++ === 0 ? firstStream : new Promise(() => {}),
    acceptUni: () => new Promise(() => {}),
    closed: () => new Promise(() => {}),
    close: (code: bigint) => { codes.push(code); },
  };
  return { native: fake as unknown as Connection, closeCodes: () => codes };
}

/** A record stream whose first record hangs until released — for putting a
 *  peer PAST admission and INTO the read loop before revoking access, so the
 *  close it earns comes from the read loop's own per-record `authorized()`
 *  recheck (code 3) rather than the pre-stream admission check (code 1). The
 *  A1 open frame is served first (`withSessionOpen`); the gate below it is
 *  what a test releases, with a real frame the reader can decode — a
 *  malformed one would earn a protocol-violation close instead, before
 *  `authorized()` is ever consulted. */
function pausableStream() {
  const gate = Promise.withResolvers<Uint8Array>();
  let stage: 0 | 1 = 0;
  return {
    // Takes a whole encoded frame (not raw bytes off the wire): the
    // StreamRecordReader reads its length prefix and body as two separate
    // `readExact` calls, so the gate must answer each in turn rather than
    // handing the same bytes back twice.
    resolve: (frame: Uint8Array) => gate.resolve(frame),
    stream: withSessionOpen({
      send: { writeAll: async (_bytes: number[]) => {}, setPriority: async (_p: number) => {},
        reset: async (_code: bigint) => {}, finish: async () => {} },
      recv: {
        readExact: async (_length: number) => {
          const frame = await gate.promise;
          if (stage === 0) {
            stage = 1;
            const prefix = Buffer.alloc(4);
            prefix.writeUInt32BE(frame.length, 0);
            return Array.from(prefix);
          }
          return Array.from(frame);
        },
      },
    }),
  };
}

/** A record stream that serves each frame's length-prefix then its bytes, in
 *  order, over the actual record framing (the session `StreamRecordReader`: a
 *  4-byte BE length, then the frame) — but frame 0 only; every later frame
 *  stays UNAVAILABLE until `release(index)` is called for it.
 *
 *  A stream with every frame queued up front resolves the whole read loop —
 *  establish, then process the next frame — inside one microtask flush, which
 *  races past any `setTimeout`-based poll for the state in between (observed:
 *  a poll for "session established" never caught it, because by its first
 *  check the second frame had already been read and had torn the session back
 *  down). Gating each later frame behind an explicit release is what gives a
 *  test a real point to poll from. The A1 open frame is served first
 *  (`withSessionOpen`), ungated, ahead of frame 0. */
function scriptedStream(frames: Uint8Array[]) {
  const perFrame = frames.map((frame): [number[], number[]] => {
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32BE(frame.length, 0);
    return [Array.from(prefix), Array.from(frame)];
  });
  const resolvers: Array<() => void> = [];
  const gates: Array<Promise<void>> = perFrame.map((_, index) => {
    if (index === 0) return Promise.resolve();
    const { promise, resolve } = Promise.withResolvers<void>();
    resolvers[index] = resolve;
    return promise;
  });
  let frameIndex = 0;
  let chunkIndex = 0;
  return {
    release: (index: number) => resolvers[index]?.(),
    stream: withSessionOpen({
      send: { writeAll: async (_bytes: number[]) => {}, setPriority: async (_p: number) => {},
        reset: async (_code: bigint) => {}, finish: async () => {} },
      recv: {
        readExact: async (_length: number) => {
          if (frameIndex >= perFrame.length) return new Promise<number[]>(() => {});
          await gates[frameIndex];
          const bytes = perFrame[frameIndex]![chunkIndex]!;
          chunkIndex++;
          if (chunkIndex === 2) { chunkIndex = 0; frameIndex++; }
          return bytes;
        },
      },
    }),
  };
}

async function until(condition: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

test("(b) access revoked mid-session closes the connection unauthorized (code 3)", async () => {
  const f = fixture();
  const paused = pausableStream();
  const peer = connection(f.endpointId, Promise.resolve(paused.stream));
  try {
    await f.access.acceptPeer(peer.native);
    expect(f.access.nativePeers.size).toBe(1);
    f.setAllowed(false);
    // Any well-formed record does it — revocation is caught by the read
    // loop's own `authorized()` check once `reader.read()` returns, not by
    // anything specific to this frame's content.
    paused.resolve(encodePeerFrame({ type: "session" }, Buffer.from(JSON.stringify({ type: "ping" }))));
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([3n]);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

// A session:hello is only ever processed off a `session`-kind record
// (peer-protocol.ts's `type` discriminator); every scripted hello below uses it.
const helloFrame = (attemptId: string) => encodePeerFrame(
  { type: "session" },
  Buffer.from(JSON.stringify({ type: "session:hello", attemptId })),
);
const slotOf = (f: ReturnType<typeof fixture>) => `${f.peerId}#${f.client.deviceId}`;

test("a second hello naming a different attemptId once established closes the connection as a protocol violation (code 2)", async () => {
  const f = fixture();
  const scripted = scriptedStream([helloFrame("a1"), helloFrame("a2")]);
  const peer = connection(f.endpointId, Promise.resolve(scripted.stream));
  try {
    await f.access.acceptPeer(peer.native);
    const slot = `${f.peerId}#${f.client.deviceId}`;
    await until(() => f.client.peers.peerSession(slot) !== null);
    scripted.release(1);
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([2n]);
    expect(f.client.peers.peerSession(slot)).toBeNull();
  } finally { f.client.close(); }
});

// --- The native layer: admission, the lease re-check, the hello timer ---

test("a hello the lease re-check refuses is never established and closes unauthorized (code 3)", async () => {
  const f = fixture();
  // Admission's refresh sees the device; the hello's own refresh finds it
  // removed. Without that second refresh the hello would establish on the
  // admission-time lease.
  let refreshes = 0;
  f.access.enrollment.authorization = async () => (++refreshes === 1 ? f.snapshot : { ...f.snapshot, peers: [] });
  const scripted = scriptedStream([helloFrame("a1")]);
  const peer = connection(f.endpointId, Promise.resolve(scripted.stream));
  try {
    await f.access.acceptPeer(peer.native);
    await until(() => peer.closeCodes().length > 0);
    expect(refreshes).toBe(2);
    expect(peer.closeCodes()).toEqual([3n]);
    expect(f.client.peers.peerSession(slotOf(f))).toBeNull();
    expect(f.client.peers.establishedPeers()).toEqual([]);
  } finally { f.client.close(); }
});

test("a lease-authorized peer's envelope before its hello never reaches the control-plane bus", async () => {
  const f = fixture();
  const bus = new MessageBus();
  const received: unknown[] = [];
  bus.setInboundHandler((msg) => received.push(msg));
  f.client.setBus(bus);
  // The wire body of a `message`-kind record is a bare AbMessage.
  const envelope = encodePeerFrame({ type: "message" },
    Buffer.from(JSON.stringify(createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" }))));
  const scripted = scriptedStream([envelope, helloFrame("a1"), envelope]);
  const peer = connection(f.endpointId, Promise.resolve(scripted.stream));
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(peer.native);
    await until(() => events.some((e) => e.kind === "drop" && e.reason === "pre-establishment"));
    expect(received).toHaveLength(0);
    scripted.release(1);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    // The same bytes, once the peer has said hello, do reach the bus: the drop
    // above is the establishment gate, not a malformed fixture.
    scripted.release(2);
    await until(() => received.length === 1);
    expect(peer.closeCodes()).toEqual([]);
  } finally { observer.mockRestore(); f.client.close(); }
});

test("the hello timer spares an established connection and closes one that never said hello", async () => {
  const timers: Array<{ ms: number; fire: () => void }> = [];
  const f = fixture({ schedule: (callback, ms) => { timers.push({ ms, fire: callback }); return () => {}; } });
  const silentEndpoint = "b".repeat(64);
  f.snapshot.peers.push({ deviceId: "22222222-2222-4222-8222-222222222222", ed25519Pub: vector.devicePublic,
    endpoint: { endpointId: silentEndpoint, generation: "1" } });
  const scripted = scriptedStream([helloFrame("a1")]);
  const greeted = connection(f.endpointId, Promise.resolve(scripted.stream));
  const silent = connection(silentEndpoint);
  try {
    await f.access.acceptPeer(greeted.native);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    await f.access.acceptPeer(silent.native);
    const helloTimers = timers.filter((t) => t.ms === 30_000);
    expect(helloTimers).toHaveLength(2);
    // Fired regardless of cancellation: the timer's own guard must be what
    // spares the greeted connection.
    for (const t of helloTimers) t.fire();
    await until(() => silent.closeCodes().length > 0);
    expect(greeted.closeCodes()).toEqual([]);
    expect(f.client.peers.peerSession(slotOf(f))).not.toBeNull();
  } finally { f.client.close(); }
});

test("admission records the lease's identity for push and suppression, and registers the phone", async () => {
  const upserts: Array<{ phonePubkey: string; phoneDeviceId: string }> = [];
  const pairedPhones = {
    has: () => false,
    upsert: (row: { phonePubkey: string; phoneDeviceId: string }) => { upserts.push(row); },
    touchLastSeen: () => {},
  } as unknown as PairedPhonesStore;
  const f = fixture({ pairedPhones });
  const scripted = scriptedStream([helloFrame("a1")]);
  const peer = connection(f.endpointId, Promise.resolve(scripted.stream));
  try {
    await f.access.acceptPeer(peer.native);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    // `peerPubkey` is what push:register resolves the phone's row by, and what
    // push suppression compares against the registry.
    expect(f.client.peers.peerSession(slotOf(f))?.peerPubkey).toBe(vector.devicePublic);
    expect(f.client.peers.peerPubkeyFor(slotOf(f))).toBe(vector.devicePublic);
    expect(upserts).toHaveLength(1);
    expect(upserts[0]).toMatchObject({ phonePubkey: vector.devicePublic, phoneDeviceId: f.peerId });
  } finally { f.client.close(); }
});

test("a key rotated in the lease retires the established peer", async () => {
  const f = fixture();
  const scripted = scriptedStream([helloFrame("a1")]);
  const peer = connection(f.endpointId, Promise.resolve(scripted.stream));
  try {
    await f.access.acceptPeer(peer.native);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    f.snapshot.peers[0]!.ed25519Pub = Buffer.alloc(32, 9).toString("base64");
    await (f.client.peers as unknown as { lease: { refresh(): Promise<boolean> } }).lease.refresh();
    expect(peer.closeCodes()).toEqual([3n]);
    expect(f.client.peers.peerSession(slotOf(f))).toBeNull();
  } finally { f.client.close(); }
});

test("an endpoint the lease does not know cannot evict an established peer", async () => {
  const f = fixture();
  const scripted = scriptedStream([helloFrame("a1")]);
  const holder = connection(f.endpointId, Promise.resolve(scripted.stream));
  const stranger = connection("c".repeat(64));
  try {
    await f.access.acceptPeer(holder.native);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    await f.access.acceptPeer(stranger.native);
    expect(stranger.closeCodes()).toEqual([3n]);
    expect(holder.closeCodes()).toEqual([]);
    expect(f.client.peers.peerSession(slotOf(f))).not.toBeNull();
  } finally { f.client.close(); }
});

test("a second endpoint still authorized for the same device is refused rather than evicting the first", async () => {
  const f = fixture();
  const otherEndpoint = "d".repeat(64);
  f.snapshot.peers.push({ deviceId: f.peerId, ed25519Pub: vector.devicePublic,
    endpoint: { endpointId: otherEndpoint, generation: "1" } });
  const scripted = scriptedStream([helloFrame("a1")]);
  const holder = connection(f.endpointId, Promise.resolve(scripted.stream));
  const other = connection(otherEndpoint);
  try {
    await f.access.acceptPeer(holder.native);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    await f.access.acceptPeer(other.native);
    expect(other.closeCodes()).toEqual([1n]);
    expect(holder.closeCodes()).toEqual([]);
    expect(f.client.peers.peerSession(slotOf(f))).not.toBeNull();
  } finally { f.client.close(); }
});

test("a device whose endpoint rotated in the lease replaces its old connection", async () => {
  const f = fixture();
  const rotated = "e".repeat(64);
  const scripted = scriptedStream([helloFrame("a1")]);
  const old = connection(f.endpointId, Promise.resolve(scripted.stream));
  const fresh = connection(rotated);
  try {
    await f.access.acceptPeer(old.native);
    await until(() => f.client.peers.peerSession(slotOf(f)) !== null);
    f.snapshot.peers[0]!.endpoint = { endpointId: rotated, generation: "2" };
    await f.access.acceptPeer(fresh.native);
    expect(old.closeCodes()).toEqual([3n]);
    expect(fresh.closeCodes()).toEqual([]);
    expect(f.access.nativePeers.size).toBe(1);
  } finally { f.client.close(); }
});
