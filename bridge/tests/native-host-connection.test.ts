import { expect, test, spyOn } from "bun:test";
import { netwatch } from "../src/netwatch";
import type { Connection } from "@number0/iroh";
import { NativeHostConnection, evalIrohBindAddress } from "../src/peer/native-host-connection";
import vector from "../../evals/fixtures/endpoint-registration-vectors.json";
import { encodePeerFrame } from "antgrid-wire";
import { MessageBus } from "../src/message-bus";
import type { PendingSinkWrite, QueuedAppFrame } from "../src/send-scheduler";

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
function fixture(now?: () => number) {
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
      ...(now ? { lifecycle: { now } } : {}),
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
  send: { writeAll: async (_bytes: number[]) => {} },
  recv: { readExact: (_length: number) => new Promise<number[]>(() => {}) },
})) {
  let streams = 0;
  let closes = 0;
  const fake = {
    remoteId: () => ({ toString: () => endpointId }),
    alpn: () => Array.from(Buffer.from("antgrid/peer/1")),
    acceptBi: () => streams++ === 0 ? firstStream : new Promise(() => {}),
    acceptUni: () => new Promise(() => {}),
    closed: () => new Promise(() => {}),
    close: () => { closes++; },
  };
  return { native: fake as unknown as Connection, closes: () => closes };
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
      onPeerPlaintext: (text: string, channel: "control", peerId: string, session: unknown) => void;
    };
    // Frag reassembly is checked unconditionally before classification runs,
    // so the fake stands in for a session with nothing buffered.
    const fakeSession = { frag: { accept: () => false } };
    access.onPeerPlaintext("{}", "control", `${f.peerId}#${f.client.deviceId}`, fakeSession);
    access.onPeerPlaintext("{}", "control", "websocket-peer", fakeSession);
    expect(events.filter((event) => event.reason === "unrecognized-plaintext").map((event) => event.transport))
      .toEqual(["iroh", "iroh"]);
    const accepted = events.find((event) => event.kind === "lifecycle" && event.msgType === "peer:native-accepted");
    expect(accepted?.detail?.attemptGeneration).toBe(1);
    expect(accepted?.detail?.leaseRemainingMs).toBeGreaterThan(59_000);
    const slot = `${f.peerId}#${f.client.deviceId}`;
    f.access.onSessionEstablished(slot);
    const established = events.find((event) => event.msgType === "peer:e2e-established");
    expect(established?.detail?.attemptGeneration).toBe(1);
    expect(established?.detail?.sessionGeneration).toBe(1);
    expect(established?.detail?.leaseRemainingMs).toBeGreaterThan(59_000);
    f.setAllowed(false);
    f.client.recheckAuthorization();
    const retired = events.find((event) => event.msgType === "peer:native-retired");
    expect(retired?.detail).toMatchObject({
      attemptGeneration: 1,
      sessionGeneration: 1,
      reason: "unauthorized",
      teardownOutcome: "requested",
    });
    expect(JSON.stringify(events)).not.toContain("private");
    expect(JSON.stringify(events)).not.toContain("test-only");
  } finally { observer.mockRestore(); f.client.close(); }
});

test("native write diagnostics await acceptance and separate payload from record framing", async () => {
  const f = fixture();
  const written = Promise.withResolvers<void>();
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(connection(f.endpointId, Promise.resolve({
      send: { writeAll: () => written.promise },
      recv: { readExact: (_length: number) => new Promise<number[]>(() => {}) },
    })).native);
    const slot = `${f.peerId}#${f.client.deviceId}`;
    const payload = Buffer.from("private-test-payload");
    const access = f.client.peers as unknown as {
      sendNativePayload: (data: Buffer, to: string, channel: "control", type: string) => boolean;
      sendNativeScheduled: (data: Buffer, to: string, frame: QueuedAppFrame) => PendingSinkWrite;
    };
    expect(access.sendNativePayload(payload, slot, "control", "session:hello")).toBe(true);
    expect(events.filter((event) => event.dir === "tx")).toHaveLength(0);
    written.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const tx = events.filter((event) => event.dir === "tx");
    expect(tx).toHaveLength(1);
    expect(tx[0].transport).toBe("iroh");
    expect(tx[0].bytes).toBe(payload.length);
    const peerFrame = encodePeerFrame({ type: "message", channel: "control" }, payload);
    expect(tx[0].detail).toEqual({ peerFrameBytes: peerFrame.length, recordBytes: peerFrame.length + 4, lengthPrefixBytes: 4 });
    expect(JSON.stringify(events)).not.toContain("private-test-payload");
    const scheduled = access.sendNativeScheduled(Buffer.alloc(48, 7), slot, {
      channel: "control", streamId: "project-stream", type: "file:content", plaintext: "private-file",
      plaintextBytes: 12,
    });
    // The window charge must equal what the receiver credits: payload bytes,
    // with no seal overhead added on this side only.
    expect(scheduled.bytes).toBe(48);
    expect(await scheduled.completed).toBe(true);
    const scheduledEvent = events.find((event) => event.msgType === "file:content");
    expect(scheduledEvent?.transport).toBe("iroh");
    expect(scheduledEvent?.bytes).toBe(48);
    expect(scheduledEvent?.streamId).toBe("project-stream");
    expect(JSON.stringify(events)).not.toContain("private-file");
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
    stream.resolve({ send: { writeAll: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
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
  const stream = Promise.withResolvers<{ send: { writeAll: (_bytes: number[]) => Promise<void> };
    recv: { readExact: (_length: number) => Promise<number[]> } }>();
  try {
    const peer = connection(f.endpointId, stream.promise);
    const admission = f.access.acceptPeer(peer.native);
    await Promise.resolve();
    await Promise.resolve();
    f.setAllowed(false);
    stream.resolve({ send: { writeAll: async () => {} }, recv: { readExact: async () => [] } });
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
    sendNativePayload(data: Buffer, to: string): boolean;
    sendNativeScheduled(data: Buffer, to: string, frame: QueuedAppFrame): unknown;
    sendJson(data: object): void;
  };
  try {
    await access.lease.refresh();
    f.client.central.ws = { readyState: WebSocket.OPEN, send: (data: unknown) => sent.push(data) } as unknown as WebSocket;
    expect(access.sendNativePayload(Buffer.from("payload"), f.peerId)).toBe(false);
    expect(access.sendNativeScheduled(Buffer.from("sealed"), f.peerId, {
      channel: "control", streamId: "0", type: "terminal:input", plaintext: "input", plaintextBytes: 5,
    })).toBeNull();
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
    stream.resolve({ send: { writeAll: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
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
    slow.resolve({ send: { writeAll: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
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
