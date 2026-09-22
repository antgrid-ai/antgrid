import { expect, test, spyOn } from "bun:test";
import { netwatch } from "../src/netwatch";
import type { Connection } from "@number0/iroh";
import { NativeHostConnection, evalIrohBindAddress } from "../src/peer/native-host-connection";
import { generateEphemeralKeypair } from "../src/key-exchange";
import vector from "../../evals/fixtures/endpoint-registration-vectors.json";
import { FrameKind, encodeRouteFrame } from "antgrid-wire";
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
function fixture() {
  let allowed = true;
  const client = new NativeHostConnection({
    url: "ws://localhost:1", identity: { deviceId: vector.challenge.deviceId, deviceName: "test", createdAt: "",
      ed25519PublicKey: vector.devicePublic, ed25519PrivateKey: vector.deviceSeed },
    enrollment: vector.challenge, endpointSecret: vector.endpointSeed, licenseApiUrl: "https://backend.invalid",
    getLicenseToken: () => "test-only", generateKeypair: generateEphemeralKeypair,
    remoteAccessEnabled: () => allowed,
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
    resetE2eState: () => void;
    handleBinaryFrame: (frame: Buffer) => void;
    onSessionEstablished: (peerId: string) => void;
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

test("peer payload diagnostics classify all production payload frames as native", async () => {
  const f = fixture();
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(connection(f.endpointId).native);
    const access = f.client.peers as unknown as {
      onSealedPlaintext: (text: string, channel: "control", peerId: string, session: null) => void;
    };
    access.onSealedPlaintext("{}", "control", `${f.peerId}#${f.client.deviceId}`, null);
    access.onSealedPlaintext("{}", "control", "websocket-peer", null);
    expect(events.filter((event) => event.reason === "unrecognized-plaintext").map((event) => event.transport))
      .toEqual(["iroh", "iroh"]);
    expect(events.some((event) => event.kind === "lifecycle" && event.msgType === "peer:native-accepted")).toBe(true);
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
      sendPayload: (data: Buffer, to: string, channel: "control", kind: FrameKind, type: string) => boolean;
      sendScheduledPayload: (data: Buffer, to: string, frame: QueuedAppFrame) => PendingSinkWrite;
    };
    expect(access.sendPayload(payload, slot, "control", FrameKind.handshake, "handshake:agent-hello")).toBe(true);
    expect(events.filter((event) => event.dir === "tx")).toHaveLength(0);
    written.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const tx = events.filter((event) => event.dir === "tx");
    expect(tx).toHaveLength(1);
    expect(tx[0].transport).toBe("iroh");
    expect(tx[0].bytes).toBe(payload.length);
    const route = encodeRouteFrame({ type: "message", to: slot, channel: "control" }, payload, FrameKind.handshake);
    expect(tx[0].detail).toEqual({ routeBytes: route.length, recordBytes: route.length + 4, lengthPrefixBytes: 4 });
    expect(JSON.stringify(events)).not.toContain("private-test-payload");
    const scheduled = access.sendScheduledPayload(Buffer.alloc(48, 7), slot, {
      channel: "control", streamId: "project-stream", type: "file:content", plaintext: "private-file",
      plaintextBytes: 12,
    });
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
    sendPayload(data: Buffer, to: string): boolean;
    sendScheduledPayload(data: Buffer, to: string, frame: QueuedAppFrame): unknown;
    sendJson(data: object): void;
  };
  try {
    await access.lease.refresh();
    f.client.central.ws = { readyState: WebSocket.OPEN, send: (data: unknown) => sent.push(data) } as unknown as WebSocket;
    expect(access.sendPayload(Buffer.from("payload"), f.peerId)).toBe(false);
    expect(access.sendScheduledPayload(Buffer.from("sealed"), f.peerId, {
      channel: "control", streamId: "0", type: "terminal:input", plaintext: "input", plaintextBytes: 5,
    })).toBeNull();
    expect(sent).toEqual([]);
    f.client.central.sendJson({ type: "ping" });
    expect(sent).toEqual([JSON.stringify({ type: "ping" })]);
  } finally { f.client.central.ws = null; f.client.close(); }
});


test("a slow first stream cannot admit a duplicate peer writer", async () => {
  const f = fixture(); const stream = Promise.withResolvers<any>();
  try {
    const first = connection(f.endpointId, stream.promise);
    const pending = f.access.acceptPeer(first.native);
    await new Promise((r) => setTimeout(r, 0));
    const duplicate = connection(f.endpointId); await f.access.acceptPeer(duplicate.native);
    expect(duplicate.closes()).toBe(1);
    stream.resolve({ send: { writeAll: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
    await pending; expect(f.access.nativePeers.size).toBe(1);
  } finally { f.client.close(); }
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
    expect(f.access.nativePeers.size).toBe(1); expect(access.pendingAdmissions).toBe(1);
    slow.resolve({ send: { writeAll: async () => {} }, recv: { readExact: () => new Promise(() => {}) } });
    await new Promise((r) => setTimeout(r, 0));
    expect(f.access.nativePeers.size).toBe(2); expect(access.pendingAdmissions).toBe(0);
  } finally { f.client.close(); }
});


test("pending native admissions are bounded and late arrivals are retired after close", async () => {
  const f = fixture(); const access = f.client.peers as any;
  const pending = Array.from({ length: 4 }, () => Promise.withResolvers<Connection>());
  let refused = 0;
  const incoming = [...pending.map((p) => ({ accept: async () => ({ connect: () => p.promise }), refuse: async () => { refused++; } })),
    { accept: async () => { throw new Error("overflow must not be accepted"); }, refuse: async () => { refused++; } }];
  await access.acceptConnections({ acceptNext: async () => incoming.shift() ?? null }, access.lifetime);
  expect(access.pendingAdmissions).toBe(4); expect(refused).toBe(1);
  f.client.close();
  const peers = pending.map(() => connection(f.endpointId));
  pending.forEach((p, i) => p.resolve(peers[i]!.native));
  await new Promise((r) => setTimeout(r, 0));
  expect(access.pendingAdmissions).toBe(0);
  expect(peers.every((p) => p.closes() === 1)).toBe(true);
});
