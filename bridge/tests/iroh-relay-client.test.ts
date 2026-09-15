import { expect, test, spyOn } from "bun:test";
import { netwatch } from "../src/netwatch";
import type { Connection } from "@number0/iroh";
import { IrohRelayClient } from "../src/peer/iroh-relay-client";
import { generateEphemeralKeypair } from "../src/key-exchange";
import vector from "../../evals/fixtures/endpoint-registration-vectors.json";
import { FrameKind, encodeRouteFrame } from "antgrid-wire";
import { MessageBus } from "../src/message-bus";
import type { PendingSinkWrite, QueuedAppFrame } from "../src/send-scheduler";

function fixture() {
  let allowed = true;
  const client = new IrohRelayClient({
    url: "ws://localhost:1", identity: { deviceId: vector.challenge.deviceId, deviceName: "test", createdAt: "",
      ed25519PublicKey: vector.devicePublic, ed25519PrivateKey: vector.deviceSeed },
    enrollment: vector.challenge, endpointSecret: vector.endpointSeed, licenseApiUrl: "https://backend.invalid",
    getLicenseToken: () => "test-only", generateKeypair: generateEphemeralKeypair,
    mode: "iroh-preferred", remoteAccessEnabled: () => allowed,
  });
  const endpointId = "a".repeat(64);
  const peerId = "11111111-1111-4111-8111-111111111111";
  const snapshot = { accountId: vector.challenge.accountId, deviceId: vector.challenge.deviceId,
    enrollmentId: vector.challenge.enrollmentId, policyGeneration: "1", registrationGeneration: "1",
    allowed: true, leaseMs: 60_000, endpoint: { endpointId: vector.challenge.endpointId, generation: "1" },
    peers: [{ deviceId: peerId, ed25519Pub: vector.devicePublic, endpoint: { endpointId, generation: "1" } }], relayUrls: [] };
  const access = client as unknown as {
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

test("peer payload diagnostics classify native and relay frames independently", async () => {
  const f = fixture();
  const events: Parameters<typeof netwatch.record>[0][] = [];
  const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
  try {
    await f.access.acceptPeer(connection(f.endpointId).native);
    const access = f.client as unknown as {
      onSealedPlaintext: (text: string, channel: "control", peerId: string, session: null) => void;
    };
    access.onSealedPlaintext("{}", "control", `${f.peerId}#${f.client.deviceId}`, null);
    access.onSealedPlaintext("{}", "control", "websocket-peer", null);
    expect(events.filter((event) => event.reason === "unrecognized-plaintext").map((event) => event.transport))
      .toEqual(["iroh", "relay"]);
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
    const access = f.client as unknown as {
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

test("a local project awaits native E2E readiness rather than a central acknowledgement", async () => {
  const f = fixture();
  try {
    let admitted = 0;
    const handle = f.client.attachStream(new MessageBus(), { onAdmitted: () => { admitted++; } });
    expect(admitted).toBe(0);
    await f.access.acceptPeer(connection(f.endpointId).native);
    expect(admitted).toBe(0);
    f.access.onSessionEstablished(`${f.peerId}#${f.client.deviceId}`);
    expect(admitted).toBe(1);
    f.access.onSessionEstablished(`${f.peerId}#${f.client.deviceId}`);
    expect(admitted).toBe(1);
    handle.detach();
  } finally { f.client.close(); }
});

test("selected WebSocket hello retires a late native carrier before native E2E starts", async () => {
  const f = fixture();
  try {
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    f.access.handleBinaryFrame(Buffer.from(encodeRouteFrame({ type: "message", from: `${f.peerId}#${f.client.deviceId}`, channel: "control" },
      Buffer.from(JSON.stringify({ type: "handshake:client-hello", attemptId: "selected-websocket" })), FrameKind.handshake)));
    expect(f.access.nativePeers.size).toBe(0);
    expect(peer.closes()).toBe(1);
  } finally { f.client.close(); }
});

test("central presence/reconnect preserves native selection; remote-access-off closes it immediately", async () => {
  const f = fixture();
  try {
    const peer = connection(f.endpointId);
    await f.access.acceptPeer(peer.native);
    const slot = `${f.peerId}#${f.client.deviceId}`;
    expect(f.access.nativePeers.has(slot)).toBe(true);
    f.access.handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: slot }));
    f.access.resetE2eState();
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
