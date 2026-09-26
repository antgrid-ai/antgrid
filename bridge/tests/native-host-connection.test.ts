import { expect, test, spyOn } from "bun:test";
import { netwatch } from "../src/netwatch";
import type { Connection } from "@number0/iroh";
import { NativeHostConnection, evalIrohBindAddress } from "../src/peer/native-host-connection";
import vector from "../../evals/fixtures/endpoint-registration-vectors.json";
import {
  FRAME_VERSION, FrameKind, MAX_TRANSFER_BYTES, PEER_ALPN, PEER_MAX_RECORD_BYTES,
  STREAM_MAX_BIDI_STREAMS_PER_CONNECTION, STREAM_OPEN_MAX_BYTES, decodeStreamRefused, encodePeerFrame,
  encodeStreamOpen, type PeerFrameKind,
} from "antgrid-wire";
import { MessageBus } from "../src/message-bus";
import { STREAM_RECORD_SLICE_BYTES } from "../src/peer/stream-records";

// A1: every native bidi stream, the session stream included, opens with one
// `[u32 BE len][UTF-8 JSON StreamOpen]` record before it carries anything
// else (docs/iroh-reduction/stage-A-A1-contract.md §0). `withSessionOpen`
// prepends the default `{"kind":"session"}` record ahead of whatever a test
// scripted for the session stream itself, so every existing fixture keeps
// working unmodified past the open-frame read `acceptPeer` now does first.
function sessionOpenRecord(): { prefix: number[]; body: number[] } {
  const body = Array.from(encodeStreamOpen({ kind: "session" }));
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(body.length, 0);
  return { prefix: Array.from(prefix), body };
}

function withSessionOpen<T extends { recv: { readExact: (length: number) => Promise<number[]> } }>(stream: T): T {
  const record = sessionOpenRecord();
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

test("eval native bind seam accepts loopback only and is inert outside evals", () => {
  expect(evalIrohBindAddress({ ANTGRID_EVAL_TEST: "1", ANTGRID_EVAL_IROH_BIND_ADDR: "127.0.0.1:19001" }))
    .toBe("127.0.0.1:19001");
  expect(evalIrohBindAddress({ ANTGRID_EVAL_TEST: "0", ANTGRID_EVAL_IROH_BIND_ADDR: "0.0.0.0:19001" }))
    .toBeUndefined();
  expect(() => evalIrohBindAddress({ ANTGRID_EVAL_TEST: "1", ANTGRID_EVAL_IROH_BIND_ADDR: "0.0.0.0:19001" }))
    .toThrow("INVALID_EVAL_BIND_ADDR");
  expect(() => evalIrohBindAddress({ ANTGRID_EVAL_TEST: "1", ANTGRID_EVAL_IROH_BIND_ADDR: "127.0.0.1:65536" }))
    .toThrow("INVALID_EVAL_BIND_ADDR");
});
function fixture(now?: () => number, schedule?: (callback: () => void, ms: number) => () => void,
  projectCataloged?: (projectId: string) => boolean) {
  let allowed = true;
  const lifecycle: { now?: () => number; schedule?: (callback: () => void, ms: number) => () => void } = {};
  if (now) lifecycle.now = now;
  if (schedule) lifecycle.schedule = schedule;
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
      ...(projectCataloged ? { projectCataloged } : {}),
      ...(Object.keys(lifecycle).length ? { lifecycle } : {}),
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
    handleTextMessage: (raw: string) => void;
    resetSessions: () => void;
    handleBinaryFrame: (frame: Buffer) => void;
    onSessionEstablished: (peerId: string) => void;
    notePolicyGeneration: (generation: string) => void;
  };
  access.enrollment.authorization = async () => snapshot;
  return { client, access, endpointId, peerId, snapshot, setAllowed: (value: boolean) => { allowed = value; } };
}

function connection(endpointId: string, firstStream = Promise.resolve({
  send: { writeAll: async (_bytes: number[]) => {}, setPriority: async (_p: number) => {},
    reset: async (_code: bigint) => {}, finish: async () => {} },
  recv: { readExact: (_length: number) => new Promise<number[]>(() => {}) },
}), alpn = PEER_ALPN, acceptUni: () => Promise<unknown> = () => new Promise(() => {}),
  // Never settles by default, like a connection that never idles out; a test
  // proving a QUIC idle close resolves this itself with `{reason:"timed out"}`.
  closed: Promise<{ reason: string }> = new Promise(() => {})) {
  let streams = 0;
  let acceptBiCalls = 0;
  const closeCodes: bigint[] = [];
  const maxBiCalls: bigint[] = [];
  const order: string[] = [];
  // A per-test queue for streams AFTER the session stream: an `acceptBi`
  // with nothing queued waits for the next `pushLaterStream`, like a real
  // connection whose peer has not opened another stream yet.
  const laterStreams: unknown[] = [];
  const laterWaiters: Array<(stream: unknown) => void> = [];
  const fake = {
    remoteId: () => ({ toString: () => endpointId }),
    alpn: () => Array.from(Buffer.from(alpn)),
    setMaxConcurrentBiStreams: (n: bigint) => { order.push("setMaxConcurrentBiStreams"); maxBiCalls.push(n); },
    acceptBi: () => {
      acceptBiCalls++;
      order.push("acceptBi");
      return streams++ === 0 ? firstStream.then(withSessionOpen) : (laterStreams.length ? Promise.resolve(laterStreams.shift()) : new Promise((resolve) => laterWaiters.push(resolve)));
    },
    acceptUni: () => acceptUni(),
    closed: () => closed,
    close: (code: bigint) => { closeCodes.push(code); },
  };
  return {
    native: fake as unknown as Connection,
    closes: () => closeCodes.length,
    closeCodes: () => closeCodes,
    acceptBiCalls: () => acceptBiCalls,
    maxBiCalls,
    order,
    pushLaterStream: (stream: { send: unknown; recv: { readExact: (length: number) => Promise<number[]> } }) => {
      const waiter = laterWaiters.shift();
      if (waiter) waiter(stream);
      else laterStreams.push(stream);
    },
  };
}

/** Like `connection()`, but the caller controls the EXACT bytes served for
 *  the session stream's own open frame, instead of the well-formed
 *  `{"kind":"session"}` record `withSessionOpen` injects — for exercising the
 *  bridge's validation of that first record itself (§3.3 step 6). */
function connectionWithRawFirstStream(endpointId: string, firstStream: Promise<{
  send: { writeAll: (bytes: number[]) => Promise<void> };
  recv: { readExact: (length: number) => Promise<number[]> };
}>, alpn = PEER_ALPN) {
  let streams = 0;
  let acceptBiCalls = 0;
  const closeCodes: bigint[] = [];
  const fake = {
    remoteId: () => ({ toString: () => endpointId }),
    alpn: () => Array.from(Buffer.from(alpn)),
    setMaxConcurrentBiStreams: (_n: bigint) => {},
    acceptBi: () => { acceptBiCalls++; return streams++ === 0 ? firstStream : new Promise(() => {}); },
    acceptUni: () => new Promise(() => {}),
    closed: () => new Promise(() => {}),
    close: (code: bigint) => { closeCodes.push(code); },
  };
  return { native: fake as unknown as Connection, closeCodes: () => closeCodes, acceptBiCalls: () => acceptBiCalls };
}

/** A `{send, recv}` fake that serves each element of `steps` in order off
 *  `readExact`, then hangs — for scripting a raw (non-session-wrapped) open
 *  frame directly onto the session stream. */
function rawStream(steps: number[][]) {
  let index = 0;
  return {
    send: { writeAll: async (_bytes: number[]) => {} },
    recv: {
      readExact: async (_length: number): Promise<number[]> => {
        if (index >= steps.length) return new Promise<number[]>(() => {});
        return steps[index++]!;
      },
    },
  };
}

function lengthPrefix(length: number): number[] {
  const buf = Buffer.alloc(4);
  buf.writeUInt32BE(length, 0);
  return Array.from(buf);
}

async function until(condition: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadlineAt = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadlineAt) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

test("native endpoint identity must be present in authoritative peer inventory", async () => {
  const f = fixture();
  try {
    const impostor = connection("b".repeat(64));
    await f.access.acceptPeer(impostor.native);
    expect(impostor.closes()).toBe(1);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

test("repeated dials from one unrecognized endpoint cost at most one lease refresh per window", async () => {
  const f = fixture();
  let calls = 0;
  const authorize = f.access.enrollment.authorization;
  f.access.enrollment.authorization = async () => { calls++; return authorize(); };
  const strangerId = "c".repeat(64);
  try {
    for (let i = 0; i < 5; i++) {
      const stranger = connection(strangerId);
      await f.access.acceptPeer(stranger.native);
      expect(stranger.closes()).toBe(1);
    }
    expect(calls).toBe(1);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

test("two distinct endpoint ids each get their own refresh window, unaffected by the other", async () => {
  const f = fixture();
  const secondEndpointId = "b".repeat(64);
  f.snapshot.peers.push({ deviceId: "22222222-2222-4222-8222-222222222222", ed25519Pub: vector.devicePublic,
    endpoint: { endpointId: secondEndpointId, generation: "1" } });
  try {
    const first = connection(f.endpointId);
    const second = connection(secondEndpointId);
    await Promise.all([f.access.acceptPeer(first.native), f.access.acceptPeer(second.native)]);
    expect(f.access.nativePeers.size).toBe(2);
    expect(first.closes()).toBe(0);
    expect(second.closes()).toBe(0);
  } finally { f.client.close(); }
});

test("a just-registered endpoint is admitted once its one refresh catches the fresh registration", async () => {
  const f = fixture();
  const freshId = "d".repeat(64);
  let calls = 0;
  f.access.enrollment.authorization = async () => {
    calls++;
    return { ...f.snapshot, peers: [...f.snapshot.peers, { deviceId: "33333333-3333-4333-8333-333333333333",
      ed25519Pub: vector.devicePublic, endpoint: { endpointId: freshId, generation: "1" } }] };
  };
  try {
    const fresh = connection(freshId);
    await f.access.acceptPeer(fresh.native);
    expect(fresh.closes()).toBe(0);
    expect(f.access.nativePeers.size).toBe(1);
    expect(calls).toBe(1);
  } finally { f.client.close(); }
});

test("an unrecognized endpoint earns another refresh once its window elapses", async () => {
  let clock = 1_000;
  const f = fixture(() => clock);
  let calls = 0;
  const authorize = f.access.enrollment.authorization;
  f.access.enrollment.authorization = async () => { calls++; return authorize(); };
  const strangerId = "c".repeat(64);
  try {
    await f.access.acceptPeer(connection(strangerId).native);
    clock += 4_999;
    await f.access.acceptPeer(connection(strangerId).native);
    expect(calls).toBe(1);
    clock += 2;
    await f.access.acceptPeer(connection(strangerId).native);
    expect(calls).toBe(2);
  } finally { f.client.close(); }
});

test("an endpoint already in the cached lease is admitted without a refresh", async () => {
  const f = fixture();
  const secondEndpointId = "b".repeat(64);
  f.snapshot.peers.push({ deviceId: "22222222-2222-4222-8222-222222222222", ed25519Pub: vector.devicePublic,
    endpoint: { endpointId: secondEndpointId, generation: "1" } });
  let calls = 0;
  const authorize = f.access.enrollment.authorization;
  f.access.enrollment.authorization = async () => { calls++; return authorize(); };
  try {
    await f.access.acceptPeer(connection(f.endpointId).native);
    expect(calls).toBe(1);
    const second = connection(secondEndpointId);
    await f.access.acceptPeer(second.native);
    expect(second.closes()).toBe(0);
    expect(f.access.nativePeers.size).toBe(2);
    expect(calls).toBe(1);
  } finally { f.client.close(); }
});

test("an admitted endpoint redialing after a policy bump is not throttled as unknown", async () => {
  const f = fixture();
  try {
    const first = connection(f.endpointId);
    await f.access.acceptPeer(first.native);
    expect(f.access.nativePeers.size).toBe(1);
    f.snapshot.policyGeneration = "2";
    f.access.notePolicyGeneration("2");
    expect(first.closes()).toBe(1);
    expect(f.access.nativePeers.size).toBe(0);
    const redial = connection(f.endpointId);
    await f.access.acceptPeer(redial.native);
    expect(redial.closes()).toBe(0);
    expect(f.access.nativePeers.size).toBe(1);
  } finally { f.client.close(); }
});

test("peer payload diagnostics classify all production payload frames as native", async () => {
  const f = fixture();
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(connection(f.endpointId).native);
    const access = f.client.peers as unknown as {
      onControlMessage: (plaintext: string, peerId: string) => void;
    };
    access.onControlMessage("{}", `${f.peerId}#${f.client.deviceId}`);
    access.onControlMessage("{}", "websocket-peer");
    expect(events.filter((event) => event.reason === "unrecognized-plaintext").map((event) => event.transport))
      .toEqual(["iroh", "iroh"]);
    // Every one of these frames rides the session stream, so each is tagged
    // with the same logical label the app writes for it (netwatch.ts).
    for (const event of events.filter((event) => event.reason === "unrecognized-plaintext")) {
      expect(event.streamKind).toBe("session");
      expect(event.streamId).toBe("0");
    }
    const accepted = events.find((event) => event.kind === "lifecycle" && event.msgType === "peer:native-accepted");
    expect(accepted?.detail?.attemptGeneration).toBe(1);
    expect(accepted?.detail?.leaseRemainingMs).toBeGreaterThan(59_000);
    expect(accepted).toMatchObject({ streamKind: "session", streamId: "0" });
    const slot = `${f.peerId}#${f.client.deviceId}`;
    f.access.onSessionEstablished(slot);
    const established = events.find((event) => event.msgType === "peer:e2e-established");
    expect(established?.detail?.attemptGeneration).toBe(1);
    expect(established?.detail?.sessionGeneration).toBe(1);
    expect(established?.detail?.leaseRemainingMs).toBeGreaterThan(59_000);
    expect(established).toMatchObject({ streamKind: "session", streamId: "0" });
    f.setAllowed(false);
    f.client.recheckAuthorization();
    const retired = events.find((event) => event.msgType === "peer:native-retired");
    expect(retired?.detail).toMatchObject({
      attemptGeneration: 1,
      sessionGeneration: 1,
      reason: "unauthorized",
      teardownOutcome: "requested",
    });
    expect(retired).toMatchObject({ streamKind: "session", streamId: "0" });
    expect(JSON.stringify(events)).not.toContain("private");
    expect(JSON.stringify(events)).not.toContain("test-only");
  } finally { observer.mockRestore(); f.client.close(); }
});

test("native write diagnostics await the sliced write and separate payload from record framing", async () => {
  // writeSessionRecord is the session stream's only outbound path, so this
  // one case covers every control-plane and liveness write.
  const f = fixture();
  const written = Promise.withResolvers<void>();
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(connection(f.endpointId, Promise.resolve({
      send: { writeAll: () => written.promise, setPriority: async () => {}, reset: async () => {}, finish: async () => {} },
      recv: { readExact: (_length: number) => new Promise<number[]>(() => {}) },
    })).native);
    const slot = `${f.peerId}#${f.client.deviceId}`;
    const owner = f.client.peers as unknown as {
      handleHello: (hello: { type: "session:hello"; attemptId: string }, peerId: string) => void;
      sessions: Map<string, unknown>;
      writeSessionRecord(peerId: string, kind: PeerFrameKind, payload: Buffer, diagnosticType: string): Promise<unknown> | null;
    };
    owner.handleHello({ type: "session:hello", attemptId: "a1" }, slot);
    await until(() => owner.sessions.has(slot));
    const payload = Buffer.from("private-test-payload");
    const outcome = owner.writeSessionRecord(slot, "message", payload, "session:hello");
    expect(outcome).not.toBeNull();
    expect(events.filter((event) => event.dir === "tx")).toHaveLength(0);
    written.resolve();
    expect(await outcome).toBe("sent");
    // The hello handshake itself queues an ack through the same writer and
    // completes on the same shared `written` promise, so filter down to the
    // write this test actually issued rather than assume it is the only one.
    const tx = events.filter((event) => event.dir === "tx" && event.bytes === payload.length);
    expect(tx).toHaveLength(1);
    expect(tx[0].transport).toBe("iroh");
    expect(tx[0].bytes).toBe(payload.length);
    expect(tx[0].streamKind).toBe("session");
    expect(tx[0].streamId).toBe("0");
    const peerFrame = encodePeerFrame({ type: "message" }, payload);
    expect(tx[0].detail).toEqual({ peerFrameBytes: peerFrame.length, recordBytes: peerFrame.length + 4, lengthPrefixBytes: 4 });
    expect(JSON.stringify(events)).not.toContain("private-test-payload");
  } finally { written.resolve(); observer.mockRestore(); f.client.close(); }
});

test("throwing payload observer cannot reject native admission or local binding", async () => {
  const f = fixture();
  const observer = spyOn(netwatch, "record").mockImplementation((event) => {
    if (event.transport === "iroh") throw new Error("observer failure");
  });
  try {
    let admitted = false;
    const stream = f.client.attachStream(new MessageBus(), { onAdmitted: () => { admitted = true; } });
    await f.access.acceptPeer(connection(f.endpointId).native);
    f.access.onSessionEstablished(`${f.peerId}#${f.client.deviceId}`);
    expect(admitted).toBe(true);
    stream.detach();
  } finally { observer.mockRestore(); f.client.close(); }
});

test("resume closes native peers synchronously and fences pre-resume stream admission", async () => {
  const f = fixture();
  try {
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    const resumed = f.client.noteResume();
    expect(peer.closes()).toBe(1);
    expect(f.access.nativePeers.size).toBe(0);
    expect(await resumed).toBe(true);

    const stream = Promise.withResolvers<any>();
    const late = connection(f.endpointId, stream.promise);
    const accepted = f.access.acceptPeer(late.native);
    await new Promise((resolve) => setTimeout(resolve, 0));
    await f.client.noteResume();
    stream.resolve({ send: { writeAll: async () => {}, setPriority: async () => {}, reset: async () => {}, finish: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
    await accepted;
    expect(late.closes()).toBe(1);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

test("native-only resume does not churn the central control connection", async () => {
  const f = fixture();
  let centralCloses = 0;
  const access = f.client.peers as unknown as { ws: WebSocket | null };
  try {
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    f.client.central.ws = { readyState: WebSocket.OPEN, close: () => centralCloses++ } as unknown as WebSocket;
    await f.client.noteResume();
    expect(peer.closes()).toBe(1);
    expect(centralCloses).toBe(0);
  } finally { f.client.central.ws = null; f.client.close(); }
});

test("a revoked local endpoint cannot admit a peer using an otherwise allowed device lease", async () => {
  const f = fixture();
  try {
    f.access.enrollment.authorization = async () => ({ ...f.snapshot, endpoint: null });
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    expect(f.access.nativePeers.size).toBe(0);
    expect(peer.closes()).toBe(1);
  } finally { f.client.close(); }
});

test("local project readiness does not wait for a peer or central acknowledgement", async () => {
  const f = fixture();
  try {
    let admitted = 0;
    const handle = f.client.attachStream(new MessageBus(), { onAdmitted: () => { admitted++; } });
    expect(admitted).toBe(1);
    await f.access.acceptPeer(connection(f.endpointId).native);
    expect(admitted).toBe(1);
    f.access.onSessionEstablished(`${f.peerId}#${f.client.deviceId}`);
    expect(admitted).toBe(1);
    f.access.onSessionEstablished(`${f.peerId}#${f.client.deviceId}`);
    expect(admitted).toBe(1);
    handle.detach();
  } finally { f.client.close(); }
});

test("central control client exposes no binary payload entry point", () => {
  const f = fixture();
  try {
    expect("handleBinaryFrame" in f.client.central).toBe(false);
    expect("sendBinary" in f.client.central).toBe(false);
  } finally { f.client.close(); }
});

test("central presence/reconnect preserves native selection; remote-access-off closes it immediately", async () => {
  const f = fixture();
  try {
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    const slot = `${f.peerId}#${f.client.deviceId}`;
    expect(f.access.nativePeers.has(slot)).toBe(true);
    f.client.central.handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: slot }));
    f.client.central.handleTextMessage(JSON.stringify({ type: "welcome", deviceId: f.client.deviceId, epoch: 1 }));
    expect(f.access.nativePeers.has(slot)).toBe(true);
    f.setAllowed(false);
    f.client.recheckAuthorization();
    expect(f.access.nativePeers.size).toBe(0);
    expect(peer.closes()).toBe(1);
  } finally { f.client.close(); }
});

test("revocation while the first stream is pending refuses the late native stream", async () => {
  const f = fixture();
  const stream = Promise.withResolvers<{ send: { writeAll: (_bytes: number[]) => Promise<void>;
    setPriority: (p: number) => Promise<void>; reset: (code: bigint) => Promise<void>; finish: () => Promise<void> };
    recv: { readExact: (_length: number) => Promise<number[]> } }>();
  try {
    const peer = connection(f.endpointId, stream.promise);
    const admission = f.access.acceptPeer(peer.native);
    await Promise.resolve();
    await Promise.resolve();
    f.setAllowed(false);
    stream.resolve({ send: { writeAll: async () => {}, setPriority: async () => {}, reset: async () => {}, finish: async () => {} },
      recv: { readExact: async () => [] } });
    await admission;
    expect(peer.closes()).toBe(1);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

test("missing native carrier never writes payloads to central WebSocket", async () => {
  const f = fixture();
  const sent: unknown[] = [];
  const access = f.client.peers as unknown as {
    ws: WebSocket | null;
    lease: { refresh(): Promise<boolean> };
    writeSessionRecord(peerId: string, kind: PeerFrameKind, payload: Buffer, diagnosticType: string): Promise<unknown> | null;
    sendJson(data: object): void;
  };
  try {
    await access.lease.refresh();
    f.client.central.ws = { readyState: WebSocket.OPEN, send: (data: unknown) => sent.push(data) } as unknown as WebSocket;
    expect(access.writeSessionRecord(f.peerId, "message", Buffer.from("payload"), "terminal:input")).toBeNull();
    expect(sent).toEqual([]);
    f.client.central.sendJson({ type: "ping" });
    expect(sent).toEqual([JSON.stringify({ type: "ping" })]);
  } finally { f.client.central.ws = null; f.client.close(); }
});


test("a new connection for the same endpoint retires a slow first (newest wins)", async () => {
  // D4: a second authenticated connection for a peerId already in nativePeers
  // retires the first rather than being refused — the fix for the
  // rekey-as-reconnect stall (stage-B-waves.md §1.4).
  const f = fixture(); const stream = Promise.withResolvers<any>();
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    const first = connection(f.endpointId, stream.promise);
    const pending = f.access.acceptPeer(first.native);
    await new Promise((r) => setTimeout(r, 0));
    expect(f.access.nativePeers.size).toBe(1);

    const second = connection(f.endpointId);
    await f.access.acceptPeer(second.native);

    // The slow first is retired, not the newcomer.
    expect(first.closes()).toBeGreaterThanOrEqual(1);
    expect(f.access.nativePeers.size).toBe(1);
    const retired = events.find((event) => event.msgType === "peer:native-retired" && event.detail?.reason === "superseded");
    expect(retired).toBeDefined();

    // The stale connection's own stream finally resolving must not disturb
    // the newcomer: a superseded attempt never retires its successor.
    stream.resolve({ send: { writeAll: async () => {}, setPriority: async () => {}, reset: async () => {}, finish: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
    await pending;
    expect(f.access.nativePeers.size).toBe(1);
  } finally { observer.mockRestore(); f.client.close(); }
});

test("slow admission does not block a second authorized device", async () => {
  const f = fixture(); const slow = Promise.withResolvers<any>();
  const endpointId = "b".repeat(64);
  f.snapshot.peers.push({ deviceId: "22222222-2222-4222-8222-222222222222", ed25519Pub: vector.devicePublic,
    endpoint: { endpointId, generation: "1" } });
  const access = f.client.peers as any;
  try {
    const first = connection(f.endpointId, slow.promise), second = connection(endpointId);
    const incoming = [first, second].map((p) => ({ accept: async () => ({ connect: async () => p.native }), refuse: async () => {} }));
    const endpoint = { acceptNext: async () => incoming.shift() ?? null };
    await access.acceptConnections(endpoint, access.lifetime);
    await new Promise((r) => setTimeout(r, 0));
    expect(f.access.nativePeers.size).toBe(2); expect(access.admissions.size).toBe(1);
    slow.resolve({ send: { writeAll: async () => {}, setPriority: async () => {}, reset: async () => {}, finish: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
    await new Promise((r) => setTimeout(r, 0));
    expect(f.access.nativePeers.size).toBe(2); expect(access.admissions.size).toBe(0);
  } finally { f.client.close(); }
});


test("pending native admissions are bounded and late arrivals are retired after close", async () => {
  const f = fixture(); const access = f.client.peers as any;
  const pending = Array.from({ length: 4 }, () => Promise.withResolvers<Connection>());
  let refused = 0;
  const incoming = [...pending.map((p) => ({ accept: async () => ({ connect: () => p.promise }), refuse: async () => { refused++; } })),
    { accept: async () => { throw new Error("overflow must not be accepted"); }, refuse: async () => { refused++; } }];
  await access.acceptConnections({ acceptNext: async () => incoming.shift() ?? null }, access.lifetime);
  expect(access.admissions.size).toBe(4); expect(refused).toBe(1);
  f.client.close();
  const peers = pending.map(() => connection(f.endpointId));
  pending.forEach((p, i) => p.resolve(peers[i]!.native));
  await new Promise((r) => setTimeout(r, 0));
  expect(access.admissions.size).toBe(0);
  expect(peers.every((p) => p.closes() === 1)).toBe(true);
});

// --- A1: multi-stream admission (docs/iroh-reduction/stage-A-A1-contract.md §3.3) ---

test("setMaxConcurrentBiStreams(256n) is called before the first acceptBi", async () => {
  const f = fixture();
  try {
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    expect(peer.maxBiCalls).toEqual([BigInt(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION)]);
    expect(peer.order.indexOf("setMaxConcurrentBiStreams")).toBeGreaterThanOrEqual(0);
    expect(peer.order.indexOf("setMaxConcurrentBiStreams")).toBeLessThan(peer.order.indexOf("acceptBi"));
  } finally { f.client.close(); }
});

test("a connection on the stale ALPN antgrid/peer/1 is closed with code 2 before any stream is accepted", async () => {
  const f = fixture();
  try {
    const peer = connection(f.endpointId, undefined, "antgrid/peer/1");
    await f.access.acceptPeer(peer.native);
    expect(peer.closeCodes()).toEqual([2n]);
    expect(peer.acceptBiCalls()).toBe(0);
    expect(peer.maxBiCalls).toEqual([]);
  } finally { f.client.close(); }
});

test("a first stream declaring a non-session kind closes the connection with code 2", async () => {
  const f = fixture();
  const body = Array.from(encodeStreamOpen({ kind: "project", projectId: "p1" }));
  const peer = connectionWithRawFirstStream(f.endpointId, Promise.resolve(rawStream([lengthPrefix(body.length), body])));
  try {
    await f.access.acceptPeer(peer.native);
    expect(peer.closeCodes()).toEqual([2n]);
  } finally { f.client.close(); }
});

test("a first stream with an unparseable or oversized open frame closes the connection with code 2", async () => {
  const f = fixture();
  const garbage = [0xff, 0xfe, 0xfd];
  const unparseable = connectionWithRawFirstStream(f.endpointId, Promise.resolve(rawStream([lengthPrefix(garbage.length), garbage])));
  try {
    await f.access.acceptPeer(unparseable.native);
    expect(unparseable.closeCodes()).toEqual([2n]);
  } finally { f.client.close(); }

  const g = fixture();
  const oversized = connectionWithRawFirstStream(g.endpointId, Promise.resolve(rawStream([lengthPrefix(STREAM_OPEN_MAX_BYTES + 1)])));
  try {
    await g.access.acceptPeer(oversized.native);
    expect(oversized.closeCodes()).toEqual([2n]);
  } finally { g.client.close(); }
});

test("a first stream with no open frame within 5s retires the attempt", async () => {
  const timers: Array<{ ms: number; fire: () => void; cancelled: boolean }> = [];
  const schedule = (callback: () => void, ms: number) => {
    const timer = { ms, fire: () => { if (!timer.cancelled) callback(); }, cancelled: false };
    timers.push(timer);
    return () => { timer.cancelled = true; };
  };
  const f = fixture(undefined, schedule);
  const hanging = { send: { writeAll: async (_bytes: number[]) => {} }, recv: { readExact: () => new Promise<number[]>(() => {}) } };
  const peer = connectionWithRawFirstStream(f.endpointId, Promise.resolve(hanging));
  try {
    const admission = f.access.acceptPeer(peer.native);
    await until(() => timers.some((t) => t.ms === 5_000 && !t.cancelled));
    timers.find((t) => t.ms === 5_000 && !t.cancelled)!.fire();
    await admission;
    // `deadline()`'s own timeout callback closes once, and the
    // `retireOwnAttempt` it lands in closes again on the same code (1n) —
    // both calls agree on the code, which is what the retired-not-refused
    // half of D-3 requires.
    expect(peer.closeCodes().length).toBeGreaterThan(0);
    expect(peer.closeCodes().every((code) => code === 1n)).toBe(true);
  } finally { f.client.close(); }
});

/** A later stream with the full send/recv surface `PeerStreamAcceptor` and
 *  `refuseStream` drive, recording every write so a test can decode the
 *  in-band refusal. */
function laterStream(steps: number[][]) {
  const written: number[][] = [];
  const stops: bigint[] = [];
  let index = 0;
  return {
    stream: {
      send: {
        writeAll: async (bytes: number[]) => { written.push(bytes); },
        setPriority: async (_p: number) => {},
        reset: async (_code: bigint) => {},
        finish: async () => {},
      },
      recv: {
        readExact: async (_length: number): Promise<number[]> => {
          if (index >= steps.length) return new Promise<number[]>(() => {});
          return steps[index++]!;
        },
        stop: async (code: bigint) => { stops.push(code); },
      },
    },
    stops,
    refusalCode: (): string | undefined => {
      if (!written.length) return undefined;
      const all = Buffer.concat(written.map((bytes) => Buffer.from(bytes)));
      return decodeStreamRefused(all.subarray(4, 4 + all.readUInt32BE(0)))?.code;
    },
    written,
  };
}

test("a second bidi stream is refused in-band instead of retiring the connection", async () => {
  const f = fixture();
  const peer = connection(f.endpointId);
  try {
    await f.access.acceptPeer(peer.native);
    expect(peer.closeCodes()).toEqual([]);
    const body = Array.from(encodeStreamOpen({ kind: "project", projectId: "p1" }));
    const later = laterStream([lengthPrefix(body.length), body]);
    peer.pushLaterStream(later.stream);
    await until(() => later.stops.length > 0);
    // No hello has been exchanged, so the real `established` wiring must
    // answer NOT_READY; the connection stays up either way.
    expect(later.refusalCode()).toBe("NOT_READY");
    expect(peer.closeCodes()).toEqual([]);
    expect(f.access.nativePeers.size).toBe(1);
  } finally { f.client.close(); }
});

test("a refused later stream reaches netwatch tagged with the stream its open frame named", async () => {
  const f = fixture();
  const peer = connection(f.endpointId);
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(peer.native);
    const body = Array.from(encodeStreamOpen({ kind: "project", projectId: "p1" }));
    const later = laterStream([lengthPrefix(body.length), body]);
    peer.pushLaterStream(later.stream);
    await until(() => later.stops.length > 0);
    const refused = events.find((event) => event.msgType === "peer:stream-refused");
    expect(refused).toMatchObject({ streamKind: "project", streamId: "p1", detail: { code: "NOT_READY", kind: "project" } });
  } finally { observer.mockRestore(); f.client.close(); }
});

test("an established peer with a catalogued, attached project gets a project open admitted, and the first record is stream-ready", async () => {
  const f = fixture(undefined, undefined, () => true);
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1" });
  const peer = connection(f.endpointId);
  try {
    await establishedSlot(f, peer);
    const body = Array.from(encodeStreamOpen({ kind: "project", projectId: "p1" }));
    const later = laterStream([lengthPrefix(body.length), body]);
    peer.pushLaterStream(later.stream);
    await until(() => later.written.length > 0);

    expect(later.refusalCode()).toBeUndefined();
    const all = Buffer.concat(later.written.map((bytes) => Buffer.from(bytes)));
    const first = JSON.parse(all.subarray(4, 4 + all.readUInt32BE(0)).toString("utf8"));
    expect(first).toMatchObject({ type: "stream-ready", projectId: "p1" });
    expect(peer.closeCodes()).toEqual([]);
  } finally { handle.detach(); f.client.close(); }
});

test("a later stream opened after remote access is switched off writes nothing and retires the connection as unauthorized", async () => {
  const f = fixture();
  const peer = connection(f.endpointId);
  try {
    await f.access.acceptPeer(peer.native);
    f.setAllowed(false);
    const body = Array.from(encodeStreamOpen({ kind: "project", projectId: "p1" }));
    const later = laterStream([lengthPrefix(body.length), body]);
    peer.pushLaterStream(later.stream);
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([3n]);
    expect(later.written).toEqual([]);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

test("remote access switched off while the session open frame is read retires the attempt before admission", async () => {
  const f = fixture();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const record = Array.from(encodeStreamOpen({ kind: "session" }));
  let index = 0;
  const steps = [lengthPrefix(record.length), record];
  let reading = false;
  const first = {
    send: { writeAll: async (_bytes: number[]) => {} },
    recv: {
      readExact: async (_length: number): Promise<number[]> => {
        reading = true;
        await gate;
        if (index >= steps.length) return new Promise<number[]>(() => {});
        return steps[index++]!;
      },
    },
  };
  const peer = connectionWithRawFirstStream(f.endpointId, Promise.resolve(first));
  try {
    const admission = f.access.acceptPeer(peer.native);
    await until(() => reading);
    expect(f.access.nativePeers.size).toBe(1);
    const admit = spyOn(f.client.peers as unknown as { admitPeer: (peerId: string, pub: string) => void }, "admitPeer");
    f.setAllowed(false);
    release();
    await admission;
    // Identity is never registered for an attempt whose authorization lapsed
    // during the read; the session reader's own check would only catch it
    // afterwards, as unauthorized, with the peer already admitted.
    expect(admit).not.toHaveBeenCalled();
    expect(peer.closeCodes()).toEqual([1n]);
    expect(f.access.nativePeers.size).toBe(0);
  } finally { f.client.close(); }
});

test("a uni stream still retires the connection as a protocol violation", async () => {
  const f = fixture();
  const peer = connection(f.endpointId, undefined, PEER_ALPN, () => Promise.resolve({}));
  try {
    await f.access.acceptPeer(peer.native);
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([2n]);
  } finally { f.client.close(); }
});

// --- A2: terminal attachment streams (docs/iroh-reduction/stage-A-A2-contract.md §3.4) ---

/** Accepts `peer`, drives a real `session:hello`/lease-refresh round trip to
 *  the point `established()` reads true, and returns the resulting slot. The
 *  terminal-stream admission gate (`PeerStreamAcceptor`'s NOT_READY step)
 *  depends on this exactly as the legacy session path does. */
async function establishedSlot(
  f: ReturnType<typeof fixture>,
  peer: ReturnType<typeof connection>,
): Promise<string> {
  await f.access.acceptPeer(peer.native);
  const slot = `${f.peerId}#${f.client.deviceId}`;
  const owner = f.client.peers as unknown as {
    handleHello: (hello: { type: "session:hello"; attemptId: string }, peerId: string) => void;
    sessions: Map<string, unknown>;
  };
  owner.handleHello({ type: "session:hello", attemptId: "a1" }, slot);
  await until(() => owner.sessions.has(slot));
  return slot;
}

function terminalOpenRecord(projectId: string): number[][] {
  const body = Array.from(encodeStreamOpen({ kind: "terminal", projectId, requestId: crypto.randomUUID() }));
  return [lengthPrefix(body.length), body];
}

function projectOpenRecord(projectId: string): number[][] {
  const body = Array.from(encodeStreamOpen({ kind: "project", projectId }));
  return [lengthPrefix(body.length), body];
}

/** A4: terminal/tunnel admission now requires this peer to already hold an
 *  open project stream (`binding.hasOpenStream`) — opens it and waits for the
 *  `stream-ready` record so callers can push a terminal/tunnel open next. */
async function openProjectStream(peer: ReturnType<typeof connection>, projectId: string): Promise<void> {
  const later = laterStream(projectOpenRecord(projectId));
  peer.pushLaterStream(later.stream);
  await until(() => later.written.length > 0);
}

test("a terminal-kind stream reaches the terminal handler (no longer refused NOT_ALLOWED)", async () => {
  // A1 shipped an empty `handlers` table, so every terminal-kind open was
  // refused NOT_ALLOWED ("stream kind not allowed") before this wave wired
  // `TerminalStreamRegistry` in as `handlers.terminal`.
  const f = fixture(undefined, undefined, () => true);
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1" });
  const peer = connection(f.endpointId);
  try {
    const slot = await establishedSlot(f, peer);
    await openProjectStream(peer, "p1");
    const later = laterStream(terminalOpenRecord("p1"));
    peer.pushLaterStream(later.stream);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(later.written).toEqual([]); // admitted: no in-band stream:refused record
    expect(peer.closeCodes()).toEqual([]); // the connection itself is untouched
    const registry = f.client.peers as unknown as { terminalStreams: { attachmentCount: (peerId: string) => number } };
    expect(registry.terminalStreams.attachmentCount(slot)).toBe(1);
  } finally { handle.detach(); f.client.close(); }
});

test("a terminal-kind stream is refused NOT_ALLOWED when projectCataloged is not supplied", async () => {
  // `projectCataloged` absent must fail CLOSED (§3.2: "Absent => every open is
  // refused NOT_ALLOWED"), never fall back to admitting.
  const f = fixture();
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1" });
  const peer = connection(f.endpointId);
  try {
    const slot = await establishedSlot(f, peer);
    const later = laterStream(terminalOpenRecord("p1"));
    peer.pushLaterStream(later.stream);
    await until(() => later.written.length > 0);

    expect(later.refusalCode()).toBe("NOT_ALLOWED");
    expect(peer.closeCodes()).toEqual([]); // an in-band refusal, not a connection-fatal one
    const registry = f.client.peers as unknown as { terminalStreams: { attachmentCount: (peerId: string) => number } };
    expect(registry.terminalStreams.attachmentCount(slot)).toBe(0);
  } finally { handle.detach(); f.client.close(); }
});

test("retiring a peer drops its terminal bindings", async () => {
  const f = fixture(undefined, undefined, () => true);
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1" });
  const peer = connection(f.endpointId);
  try {
    const slot = await establishedSlot(f, peer);
    await openProjectStream(peer, "p1");
    const later = laterStream(terminalOpenRecord("p1"));
    peer.pushLaterStream(later.stream);
    await new Promise((resolve) => setTimeout(resolve, 50));
    const registry = f.client.peers as unknown as { terminalStreams: { attachmentCount: (peerId: string) => number } };
    expect(registry.terminalStreams.attachmentCount(slot)).toBe(1);

    // Drives the real retirePeer() path (as the existing recheckAuthorization
    // tests do) rather than calling a private method directly.
    f.setAllowed(false);
    f.client.recheckAuthorization();

    expect(f.access.nativePeers.size).toBe(0);
    expect(registry.terminalStreams.attachmentCount(slot)).toBe(0);
  } finally { handle.detach(); f.client.close(); }
});

// --- A3: tunnel streams (docs/iroh-reduction/stage-A-A3-contract.md §3.3) ---

function tunnelHttpOpenRecord(projectId: string): number[][] {
  const body = Array.from(encodeStreamOpen({ kind: "tunnel-http", projectId, requestId: crypto.randomUUID() }));
  return [lengthPrefix(body.length), body];
}

function tunnelWsOpenRecord(projectId: string): number[][] {
  const body = Array.from(encodeStreamOpen({ kind: "tunnel-ws", projectId, wsId: crypto.randomUUID() }));
  return [lengthPrefix(body.length), body];
}

/** A minimal TunnelStreamServer whose admit() always admits, with a manager
 *  nothing here calls into: these tests exercise stream-kind registration and
 *  peer retirement, not the HTTP/WS protocol (see tunnel-streams.test.ts and
 *  tunnel-manager-stream.test.ts for that). */
function fakeTunnelServer() {
  return { admit: () => ({ ok: true as const, manager: {} as never }) };
}

test("a tunnel-http-kind and tunnel-ws-kind stream both reach the tunnel handler (registered in the handler table)", async () => {
  // A2 shipped a handler table with only `terminal`; before this wave a
  // tunnel-kind open was refused NOT_ALLOWED ("stream kind not allowed").
  const f = fixture(undefined, undefined, () => true);
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1", tunnels: fakeTunnelServer() as never });
  const peer = connection(f.endpointId);
  try {
    await establishedSlot(f, peer);
    await openProjectStream(peer, "p1");

    const http = laterStream(tunnelHttpOpenRecord("p1"));
    peer.pushLaterStream(http.stream);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(http.written).toEqual([]); // admitted: no in-band stream:refused record
    expect(peer.closeCodes()).toEqual([]);

    const ws = laterStream(tunnelWsOpenRecord("p1"));
    peer.pushLaterStream(ws.stream);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(ws.written).toEqual([]);
    expect(peer.closeCodes()).toEqual([]);
  } finally { handle.detach(); f.client.close(); }
});

test("retiring a peer drops its tunnel bindings alongside its terminal bindings", async () => {
  const f = fixture(undefined, undefined, () => true);
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1", tunnels: fakeTunnelServer() as never });
  const peer = connection(f.endpointId);
  try {
    const slot = await establishedSlot(f, peer);
    await openProjectStream(peer, "p1");
    const terminal = laterStream(terminalOpenRecord("p1"));
    peer.pushLaterStream(terminal.stream);
    const http = laterStream(tunnelHttpOpenRecord("p1"));
    peer.pushLaterStream(http.stream);
    await new Promise((resolve) => setTimeout(resolve, 50));

    const access = f.client.peers as unknown as {
      terminalStreams: { attachmentCount: (peerId: string) => number };
      tunnelStreams: { streamCount: (peerId: string) => number };
    };
    expect(access.terminalStreams.attachmentCount(slot)).toBe(1);
    expect(access.tunnelStreams.streamCount(slot)).toBe(1);

    // Drives the real retirePeer() path, like the terminal-only test above.
    f.setAllowed(false);
    f.client.recheckAuthorization();

    expect(f.access.nativePeers.size).toBe(0);
    expect(access.terminalStreams.attachmentCount(slot)).toBe(0);
    expect(access.tunnelStreams.streamCount(slot)).toBe(0);
  } finally { handle.detach(); f.client.close(); }
});

// --- QUIC idle is the only liveness check the bridge runs on an app. ---

test("a QUIC idle close retires the peer", async () => {
  // The bridge never pings; a peer that stops acking is detected only through
  // `connection.closed()` resolving (QUIC keep-alive/idle), which must drop
  // exactly the same registries an explicit `retirePeer` does.
  const f = fixture(undefined, undefined, () => true);
  const bus = new MessageBus();
  const handle = f.client.attachStream(bus, { projectId: "p1", tunnels: fakeTunnelServer() as never });
  const closedGate = Promise.withResolvers<{ reason: string }>();
  const peer = connection(f.endpointId, undefined, PEER_ALPN, undefined, closedGate.promise);
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    const slot = await establishedSlot(f, peer);
    await openProjectStream(peer, "p1");
    const terminal = laterStream(terminalOpenRecord("p1"));
    peer.pushLaterStream(terminal.stream);
    const http = laterStream(tunnelHttpOpenRecord("p1"));
    peer.pushLaterStream(http.stream);
    await new Promise((resolve) => setTimeout(resolve, 50));

    const access = f.client.peers as unknown as {
      terminalStreams: { attachmentCount: (peerId: string) => number };
      tunnelStreams: { streamCount: (peerId: string) => number };
      projectStreams: { openStreamCount: (peerId: string) => number };
    };
    expect(access.terminalStreams.attachmentCount(slot)).toBe(1);
    expect(access.tunnelStreams.streamCount(slot)).toBe(1);
    expect(access.projectStreams.openStreamCount(slot)).toBe(1);

    closedGate.resolve({ reason: "timed out" });
    await until(() => f.access.nativePeers.size === 0);

    expect(f.client.peers.peerSession(slot)).toBeNull();
    expect(access.terminalStreams.attachmentCount(slot)).toBe(0);
    expect(access.tunnelStreams.streamCount(slot)).toBe(0);
    expect(access.projectStreams.openStreamCount(slot)).toBe(0);
    const retired = events.find((event) => event.msgType === "peer:native-retired");
    expect(retired?.detail).toMatchObject({ reason: "connection-lost" });
    expect(events.some((event) => event.dir === "tx" && event.msgType === "ping")).toBe(false);
  } finally { observer.mockRestore(); handle.detach(); f.client.close(); }
});

// --- The session stream: StreamRecordWriter/Reader, like every other stream. ---

/** A `{send, recv}` fake for the SESSION stream (the first stream) whose recv
 *  queue accepts records pushed AFTER construction — unlike `rawStream`'s
 *  fixed `steps`, N3-N5 push an inbound record only once the session is
 *  already established. `send` tracks call order so N1/N2 can assert
 *  `setPriority` lands exactly once, before the first `writeAll`. */
function queuedStream() {
  const written: number[][] = [];
  const priorities: number[] = [];
  const order: string[] = [];
  const queue: number[][] = [];
  const waiters: Array<(chunk: number[]) => void> = [];
  const push = (chunk: number[]) => {
    const waiter = waiters.shift();
    if (waiter) waiter(chunk);
    else queue.push(chunk);
  };
  return {
    stream: {
      send: {
        writeAll: async (bytes: number[]) => { order.push("writeAll"); written.push(bytes); },
        setPriority: async (p: number) => { order.push("setPriority"); priorities.push(p); },
        reset: async (_code: bigint) => {},
        finish: async () => {},
      },
      recv: {
        readExact: (_length: number): Promise<number[]> =>
          queue.length ? Promise.resolve(queue.shift()!) : new Promise((resolve) => waiters.push(resolve)),
      },
    },
    written,
    priorities,
    order,
    push,
    pushRecord: (frame: Uint8Array) => { push(Array.from(lengthPrefix(frame.length))); push(Array.from(frame)); },
  };
}

/** Builds the raw bytes of a peer frame BYPASSING `encodePeerFrame`'s own
 *  header validation, for N4: a real sender can never construct a header
 *  carrying `channel` (`PeerFrameHeader` is a strict zod object), so the only
 *  way to exercise the bridge's OWN rejection of one is to put it on the wire
 *  by hand. */
function rawPeerFrame(header: unknown, payload: Buffer): Buffer {
  const headerBytes = Buffer.from(JSON.stringify(header), "utf8");
  const frame = Buffer.alloc(4 + headerBytes.length + payload.length);
  frame[0] = FRAME_VERSION;
  frame[1] = FrameKind.message;
  frame.writeUInt16BE(headerBytes.length, 2);
  headerBytes.copy(frame, 4);
  payload.copy(frame, 4 + headerBytes.length);
  return frame;
}

test("N1: the session stream sets priority once, before its first write", async () => {
  const f = fixture();
  const q = queuedStream();
  const peer = connection(f.endpointId, Promise.resolve(q.stream));
  try {
    const slot = await establishedSlot(f, peer);
    const access = f.client.peers as unknown as {
      writeSessionRecord(peerId: string, kind: PeerFrameKind, payload: Buffer, diagnosticType: string): Promise<unknown> | null;
    };
    await access.writeSessionRecord(slot, "message", Buffer.from(JSON.stringify({ type: "pong" })), "pong");
    await access.writeSessionRecord(slot, "message", Buffer.from(JSON.stringify({ type: "pong" })), "pong");
    // Above terminal (1), project (0) and tunnel (-1) priorities (see
    // STREAM_PRIORITY_SESSION, native-host-connection.ts): liveness must not
    // queue behind bulk.
    expect(q.priorities).toEqual([2]);
    expect(q.order.indexOf("setPriority")).toBe(0);
    expect(q.order.filter((entry) => entry === "setPriority")).toHaveLength(1);
  } finally { f.client.close(); }
});

test("N2: a record near MAX_TRANSFER_BYTES on the session stream is written in <=256 KiB slices", async () => {
  const f = fixture();
  const q = queuedStream();
  const peer = connection(f.endpointId, Promise.resolve(q.stream));
  try {
    const slot = await establishedSlot(f, peer);
    const access = f.client.peers as unknown as {
      writeSessionRecord(peerId: string, kind: PeerFrameKind, payload: Buffer, diagnosticType: string): Promise<unknown> | null;
    };
    const payload = Buffer.alloc(MAX_TRANSFER_BYTES - 1024, 7);
    const outcome = await access.writeSessionRecord(slot, "message", payload, "file:content");
    expect(outcome).toBe("sent");
    for (const bytes of q.written) expect(bytes.length).toBeLessThanOrEqual(STREAM_RECORD_SLICE_BYTES);
    expect(q.written.length).toBeGreaterThanOrEqual(128);
  } finally { f.client.close(); }
});

test("N3: an inbound session record read after authorization is revoked retires the peer unauthorized (close code 3)", async () => {
  const f = fixture();
  const q = queuedStream();
  const peer = connection(f.endpointId, Promise.resolve(q.stream));
  try {
    const slot = await establishedSlot(f, peer);
    f.setAllowed(false);
    q.pushRecord(encodePeerFrame({ type: "message" }, Buffer.from(JSON.stringify({ type: "pong" }))));
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([3n]);
    expect(f.access.nativePeers.has(slot)).toBe(false);
  } finally { f.client.close(); }
});

test("N4: a session header carrying channel retires the peer protocol-violation (close code 2)", async () => {
  const f = fixture();
  const q = queuedStream();
  const peer = connection(f.endpointId, Promise.resolve(q.stream));
  try {
    const slot = await establishedSlot(f, peer);
    q.pushRecord(rawPeerFrame({ type: "message", channel: "control" }, Buffer.from(JSON.stringify({ type: "pong" }))));
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([2n]);
    expect(f.access.nativePeers.has(slot)).toBe(false);
  } finally { f.client.close(); }
});

test("N5: an inbound session record longer than PEER_MAX_RECORD_BYTES retires the peer protocol-violation", async () => {
  const f = fixture();
  const q = queuedStream();
  const peer = connection(f.endpointId, Promise.resolve(q.stream));
  try {
    await establishedSlot(f, peer);
    q.push(lengthPrefix(PEER_MAX_RECORD_BYTES + 1));
    await until(() => peer.closeCodes().length > 0);
    expect(peer.closeCodes()).toEqual([2n]);
  } finally { f.client.close(); }
});

test("N6: a session-stream write that never completes does not retire the peer on a timer", async () => {
  const timers: Array<{ ms: number; fire: () => void; cancelled: boolean }> = [];
  const schedule = (callback: () => void, ms: number) => {
    const timer = { ms, fire: () => { if (!timer.cancelled) callback(); }, cancelled: false };
    timers.push(timer);
    return () => { timer.cancelled = true; };
  };
  let clock = 0;
  const f = fixture(() => clock, schedule);
  const hold = Promise.withResolvers<void>();
  const peer = connection(f.endpointId, Promise.resolve({
    send: { writeAll: () => hold.promise, setPriority: async () => {}, reset: async () => {}, finish: async () => {} },
    recv: { readExact: (_length: number) => new Promise<number[]>(() => {}) },
  }));
  try {
    const slot = await establishedSlot(f, peer);
    const access = f.client.peers as unknown as {
      writeSessionRecord(peerId: string, kind: PeerFrameKind, payload: Buffer, diagnosticType: string): Promise<unknown> | null;
    };
    void access.writeSessionRecord(slot, "message", Buffer.from(JSON.stringify({ type: "pong" })), "pong");
    await new Promise((resolve) => setTimeout(resolve, 0));
    // Liveness, not a write timer, decides a slow peer is dead: nothing may be
    // armed inside a 5 s write window. Firing every scheduled timer would also
    // fire the lease's own (much longer) expiry/refresh timers and retire the
    // peer for an unrelated reason, so only that window is checked.
    clock += 5_001;
    expect(timers.some((t) => t.ms <= 5_000 && !t.cancelled)).toBe(false);
    expect(f.access.nativePeers.has(slot)).toBe(true);
  } finally { hold.resolve(); f.client.close(); }
});
