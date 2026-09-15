import assert from "node:assert/strict";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Endpoint, EndpointAddr } from "@number0/iroh/index.js";
import { FrameKind, decodeRouteFrame, encodeRouteFrame } from "antgrid-wire";
import { HostServer } from "../src/host-server";
import { PeerRecords } from "../src/peer/records";
import { computeProjectId } from "../src/project-id";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { buildTranscript, deriveSessionKeys, E2eTransport, phoneConfirmTag, signTranscript } from "../src/e2e";
import { createMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";

// Transport qualification only: HTTP authorization and central authentication
// are fixtures. The native connection, HostServer, E2E and project services run
// their production implementations; this is not backend-auth qualification.
setLogLevel("fatal");
function device() {
  const pair = generateKeyPairSync("ed25519");
  return { id: randomUUID(), public: pair.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64"),
    secret: pair.privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64") };
}
const machine = device();
const phone = device();
const endpointSecret = randomBytes(32);
const machineNativeBuilder = Endpoint.builder();
machineNativeBuilder.applyMinimal();
machineNativeBuilder.secretKey(Array.from(endpointSecret));
const temporaryIdentity = await machineNativeBuilder.bind();
const machineEndpointId = temporaryIdentity.id().toString();
await temporaryIdentity.close();
const appBuilder = Endpoint.builder();
appBuilder.applyMinimal();
appBuilder.bindAddr("127.0.0.1:0");
const app = await appBuilder.bind();
const accountId = "native-host-smoke-account";
const enrollmentId = "native-host-smoke-credential";
const snapshot = { accountId, deviceId: machine.id, enrollmentId, policyGeneration: "1", registrationGeneration: "1",
  allowed: true, leaseMs: 60_000, endpoint: { endpointId: machineEndpointId, generation: "1" },
  peers: [{ deviceId: phone.id, ed25519Pub: phone.public, endpoint: { endpointId: app.id().toString(), generation: "1" } }],
  relayUrls: ["https://relay.invalid/"] };
let centralOnline = true;
let centralSocket: { close: () => void } | undefined;
const backend = Bun.serve({ hostname: "127.0.0.1", port: 0,
  fetch(request, server) {
    const url = new URL(request.url);
    if (url.pathname === "/account/devices/me/authorization") return Response.json(snapshot);
    if (request.headers.get("upgrade") === "websocket") {
      if (!centralOnline) return new Response(null, { status: 503 });
      return server.upgrade(request) ? undefined : new Response(null, { status: 400 });
    }
    return Response.json({ devices: [{ deviceId: phone.id, ed25519Pub: phone.public }] });
  },
  websocket: {
    open(ws) { centralSocket = ws; },
    message(ws, raw) {
      if (typeof raw !== "string") throw new Error("Payload unexpectedly used central WebSocket");
      const frame = JSON.parse(raw);
      if (frame.type === "hello") ws.send(JSON.stringify({ type: "welcome", deviceId: machine.id,
        epoch: frame.epoch, serverTime: new Date().toISOString() }));
      if (frame.type === "ping") ws.send(JSON.stringify({ type: "pong" }));
      // Stream admission is deliberately absent: native project readiness must
      // remain independent of a central WebSocket registration acknowledgement.
    },
  },
});
const root = mkdtempSync(join(tmpdir(), "antgrid-native-host-smoke-"));
const previousDirectory = process.env.ANTGRID_DIR;
const previousMode = process.env.ANTGRID_PEER_TRANSPORT;
process.env.ANTGRID_DIR = join(root, "state");
process.env.ANTGRID_PEER_TRANSPORT = "iroh-preferred";
const host = new HostServer({ remote: {
  relayUrl: `ws://127.0.0.1:${backend.port}`, licenseApiUrl: `http://127.0.0.1:${backend.port}`,
  identity: { deviceId: machine.id, deviceName: "native-host-smoke", createdAt: "",
    ed25519PublicKey: machine.public, ed25519PrivateKey: machine.secret },
  auth: { clientId: enrollmentId, clientSecret: "test-only", deviceUuid: machine.id,
    userId: accountId, endpointSecret: endpointSecret.toString("base64") }, onAuthRevoked: () => {},
}, remoteRuntimeFactory: async () => ({ maint: { getToken: () => "test-only", stop: () => {} } }) });
let records: PeerRecords | undefined;
let connection: Awaited<ReturnType<Endpoint["connect"]>> | undefined;
const timeout = setTimeout(() => { console.error("native-host-smoke timed out"); process.exitCode = 1; void host.shutdown(); }, 30_000);
try {
  await host.startControlPlane();
  await host.handleRemoteAccessVerb({ id: "enable", type: "mobile-access:set", enabled: true });
  const projects: { id: string; name: string }[] = [];
  for (const name of ["alpha", "beta"]) {
    const folder = join(root, name);
    mkdirSync(folder);
    writeFileSync(join(folder, "antgrid.yaml"), `name: ${name}\nagent:\n  tool: claude-code\n`);
    writeFileSync(join(folder, "proof.txt"), `${name}:native-host-proof`);
    writeFileSync(join(folder, "native-echo.cjs"), "process.stdin.resume();process.stdin.on('data',data=>process.stdout.write('NATIVE_ECHO:'+data.toString().trim()+'\\n'));\n");
    for (const args of [["init"], ["config", "user.email", "native-smoke@example.invalid"],
      ["config", "user.name", "Native smoke"], ["add", "."], ["commit", "-m", "fixture"]]) {
      const child = Bun.spawn(["git", ...args], { cwd: folder, stdout: "ignore", stderr: "pipe" });
      assert.equal(await child.exited, 0, await new Response(child.stderr).text());
    }
    const id = computeProjectId(folder);
    await host.open(id, folder, name === "alpha" ? "remote" : "local");
    projects.push({ id, name });
  }
  const endpoint = await until(() => (host as unknown as { controlPlaneRelay?: { endpoint?: Endpoint } }).controlPlaneRelay?.endpoint);
  const addresses = endpoint.boundSockets().filter((address) => address.startsWith("0.0.0.0:") || address.startsWith("127.0.0.1:"))
    .map((address) => address.replace("0.0.0.0:", "127.0.0.1:"));
  connection = await app.connect(new EndpointAddr(endpoint.id(), undefined, addresses), Array.from(Buffer.from("antgrid/peer/1")));
  const stream = await connection.openBi();
  records = new PeerRecords(stream, () => true, () => connection?.close(1n, []));
  const ephemeral = generateEphemeralKeypair();
  const nonce = randomBytes(32);
  const attemptId = randomUUID();
  const transcript = { registrationId: machine.id, agentDeviceId: machine.id, phoneDeviceId: phone.id,
    phoneX25519Pub: ephemeral.publicKey, nonce };
  await records.send(encodeRouteFrame({ type: "message", to: machine.id, channel: "control" }, Buffer.from(JSON.stringify({
    type: "handshake:client-hello", attemptId, pubkey: ephemeral.publicKey.toString("base64"), nonce: nonce.toString("base64"),
    sig: signTranscript(buildTranscript({ ...transcript, role: "phone", agentX25519Pub: Buffer.alloc(0) }), Buffer.from(phone.secret, "base64")),
  })), FrameKind.handshake));
  const hello = JSON.parse(Buffer.from(decodeRouteFrame(await records.read()).payload).toString());
  assert.equal(hello.type, "handshake:agent-hello");
  const agentPub = Buffer.from(hello.pubkey, "base64");
  const keys = deriveSessionKeys(deriveSharedSecret(ephemeral.privateKey, agentPub),
    buildTranscript({ ...transcript, role: "agent", agentX25519Pub: agentPub }));
  const e2e = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });
  const send = (value: object) => records!.send(encodeRouteFrame({ type: "message", to: machine.id, channel: "control" }, e2e.seal(JSON.stringify(value)), FrameKind.sealed));
  const read = async (predicate: (value: any) => boolean): Promise<any> => {
    for (;;) {
      const frame = decodeRouteFrame(await records!.read());
      const clear = e2e.open(Buffer.from(frame.payload));
      assert.notEqual(clear, null);
      const value = JSON.parse(clear!);
      const message = value.m ?? value;
      if (message.type === "terminal:frame") {
        await send({ s: value.s, m: createMessage("terminal:ack", { terminalId: message.terminalId,
          runId: message.runId, attachmentId: message.attachmentId, sequence: message.sequence,
          checkoutId: message.checkoutId }) });
      }
      if (predicate(message)) return message;
    }
  };
  await send({ type: "app:ready", attemptId, confirm: phoneConfirmTag(keys.confirm).toString("base64"),
    capabilities: { checkoutRouting: true, pullsTree: true, terminalFramesV1: true } });
  await read((value) => value.type === "established");
  const nativeConnectionId = connection.stableId();
  centralOnline = false;
  centralSocket?.close();
  for (const project of projects) {
    await send({ m: createMessage("project:start", { projectId: project.id }) });
    const ready = await read((value) => value.type === "stream-ready" && value.projectId === project.id);
    await send({ s: ready.streamId, m: createMessage("file:read", { projectId: project.id, path: "proof.txt" }) });
    const file = await read((value) => value.type === "file:content" && value.projectId === project.id);
    assert.equal(file.content, `${project.name}:native-host-proof`);
    if (project.name === "alpha") {
      const requestId = randomUUID();
      await send({ s: ready.streamId, m: createMessage("session:create", {
        requestId, name: "native-checkout", isolation: "worktree",
      }) });
      const created = await read((value) => value.type === "session:result" && value.requestId === requestId);
      assert.equal(created.ok, true);
      assert.equal(created.session.checkoutKind, "managed-worktree");
      await send({ s: ready.streamId, m: createMessage("git:list-branches", {
        projectId: project.id, checkoutId: created.session.checkoutId,
      }) });
      const branches = await read((value) => value.type === "git:branches" && value.checkoutId === created.session.checkoutId);
      assert.equal(branches.current, created.session.checkoutBranch);

      const terminalId = "native-echo";
      await send({ s: ready.streamId, m: createMessage("terminal:start", {
        terminalId, name: terminalId, command: "node", args: ["native-echo.cjs"],
      }) });
      await read((value) => value.type === "terminal:started" && value.terminalId === terminalId);
      const subscribeId = randomUUID();
      await send({ s: ready.streamId, m: createMessage("terminal:subscribe", {
        terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId: subscribeId,
      }) });
      await read((value) => value.type === "terminal:subscribed" && value.requestId === subscribeId);
      await send({ s: ready.streamId, m: createMessage("terminal:input", { terminalId, data: "native-roundtrip\r" }) });
      const output = await read((value) => value.type === "terminal:frame" && value.terminalId === terminalId &&
        value.ansi.includes("NATIVE_ECHO:native-roundtrip"));
      assert.ok(output.sequence > 0);
      await send({ s: ready.streamId, m: createMessage("terminal:stop", { terminalId }) });
      await read((value) => value.type === "terminal:display:status" && value.terminalId === terminalId && value.code === "ENDED");
    }
    assert.equal(connection.stableId(), nativeConnectionId);
  }
  await host.handleRemoteAccessVerb({ id: "disable", type: "mobile-access:set", enabled: false });
  await connection.closed();
  console.log(JSON.stringify({ result: "pass", authorization: "fixture", native: "real", host: "real", e2e: "real",
    projects: projects.length, sharedConnection: true, centralOutage: true, remoteAccessOffClosed: true,
    terminalInputOutput: true, terminalFramesAcknowledged: true, managedCheckoutGit: true }));
} finally {
  clearTimeout(timeout);
  records?.close();
  await host.shutdown();
  await app.close();
  backend.stop(true);
  if (previousDirectory === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = previousDirectory;
  if (previousMode === undefined) delete process.env.ANTGRID_PEER_TRANSPORT; else process.env.ANTGRID_PEER_TRANSPORT = previousMode;
  rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 });
}

async function until<T>(read: () => T | undefined | null): Promise<T> {
  for (let attempt = 0; attempt < 200; attempt++) {
    const result = read();
    if (result) return result;
    await Bun.sleep(25);
  }
  throw new Error("Native endpoint did not start");
}
