import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { z } from "zod";
import { RelayClient } from "../../bridge/src/relay-client";
import { MessageBus } from "../../bridge/src/message-bus";
import { generateEphemeralKeypair } from "../../bridge/src/key-exchange";
import { TrustedPeersProvider } from "../../bridge/src/trusted-peers";
import { createMessage, AbMessageSchema } from "../../bridge/src/protocol";
import { TerminalSession } from "../../bridge/src/terminal-session";
import { TerminalFrameSource } from "../../bridge/src/terminal-frames/source";
import { TERMINAL_PROTOCOL_VERSION } from "../../bridge/src/terminal-frames/protocol";
import { setLogLevel } from "../../bridge/src/logger";
import { ClientMessage, RouteHeader, FrameKind, decodeRouteFrame, encodeRouteFrame } from "../../packages/antgrid-wire/src/index";
import { Records } from "./records";

const { Endpoint, presetMinimal } = require("@number0/iroh/index.js");
const machineId = "iroh-prototype-machine";
const appId = "iroh-prototype-app";
const alpn = Array.from(Buffer.from("antgrid/peer/1"));
const readySchema = z.object({
  endpointId: z.string().regex(/^[0-9a-f]{64}$/),
  publicKey: z.string().base64(),
});
const resultSchema = z.object({
  check: z.literal("encrypted-terminal-pass"),
  establishments: z.literal(2), projects: z.literal(2),
  sameConnection: z.literal(true),
});

setLogLevel("fatal");
const executable = process.env.IROH_QUALIFICATION_DART;
if (!executable) throw new Error("Set IROH_QUALIFICATION_DART to dart.exe or the compiled prototype client");
const compiled = process.env.IROH_QUALIFICATION_COMPILED === "1";
const testCase = z.enum(["terminal", "bad-agent-key", "bad-app-key", "oversize-record", "wrong-destination", "extra-stream", "disconnect",
  "client-oversize-record", "client-wrong-destination", "client-extra-stream"])
  .parse(process.env.IROH_QUALIFICATION_CASE ?? "terminal");
const base = compiled ? resolve(".tmp/iroh-qualification") : resolve(import.meta.dir, "../../.tmp/iroh-qualification");
mkdirSync(base, { recursive: true });
const scratch = mkdtempSync(join(base, "prototype-"));
const key = generateKeyPairSync("ed25519");
const machinePublic = key.publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
const machineSeed = key.privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32).toString("base64");
const child = spawn(executable, compiled ? [] : ["run", "bin/prototype.dart"], {
  cwd: compiled ? undefined : resolve(import.meta.dir, "dart"),
  stdio: ["pipe", "pipe", "inherit"],
});
const exited = new Promise<number | null>((resolve, reject) => {
  child.once("exit", resolve); child.once("error", reject);
});
void exited.catch(() => {});
const failed = Promise.withResolvers<never>();
void failed.promise.catch(() => {});
const fail = (error: unknown) => failed.reject(error);
const watchdog = setTimeout(() => {
  for (const project of projects.values()) project.terminal.kill();
  child.kill();
  console.error("FAIL: qualification prototype exceeded 60 seconds");
  process.exit(1);
}, 60_000);
const projects = new Map<string, {
  streamId: string; terminal: TerminalSession; source: TerminalFrameSource;
  bus: MessageBus; timer: ReturnType<typeof setInterval>;
}>();
let endpoint: any;
let connection: any;
let records: Records | undefined;
let client: RelayClient | undefined;
let server: ReturnType<typeof Bun.serve> | undefined;
let fixtureSocket: any;
let establishments = 0;
let terminalInputs = 0;
let shuttingDown = false;

try {
  const lines = createInterface({ input: child.stdout });
  const iterator = lines[Symbol.asyncIterator]();
  const first = await Promise.race([iterator.next(), failed.promise]);
  assert.equal(first.done, false);
  const app = readySchema.parse(JSON.parse(first.value!));
  console.error("prototype: Dart identity ready");
  const inventoryFile = join(scratch, "peers.json");
  writeFileSync(inventoryFile, JSON.stringify([{ deviceId: appId,
    ed25519Pub: testCase === "bad-app-key" ? machinePublic : app.publicKey }]));
  const trustedPeers = new TrustedPeersProvider({ filePath: inventoryFile,
    licenseApiUrl: "http://127.0.0.1:1", getToken: () => "qualification-fixture" });
  const control = new MessageBus();
  const pathToken = randomUUID();
  const authenticated = Promise.withResolvers<void>();

  // Local socket glue preserves the production RelayClient driver. It never
  // reaches LocalListener/HostServer's loopback command-authorization exemption.
  server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    fetch(request, server) {
      if (new URL(request.url).pathname !== `/${pathToken}` || fixtureSocket) return new Response(null, { status: 403 });
      return server.upgrade(request, { data: null }) ? undefined : new Response(null, { status: 400 });
    },
    websocket: {
      open(ws) { fixtureSocket = ws; },
      message(ws, raw) {
        try {
          if (typeof raw === "string") {
            const message = ClientMessage.parse(JSON.parse(raw));
            if (message.type === "hello") {
              assert.equal(message.deviceId, machineId);
              assert.equal(message.publicKey, machinePublic);
              ws.send(JSON.stringify({ type: "welcome", deviceId: machineId,
                epoch: message.epoch, serverTime: new Date().toISOString() }));
            } else if (message.type === "stream-open") {
              ws.send(JSON.stringify({ type: "stream-opened", streamId: message.streamId }));
            } else if (message.type === "ping") ws.send(JSON.stringify({ type: "pong" }));
            return;
          }
          const decoded = decodeRouteFrame(raw);
          assert.equal(RouteHeader.parse(decoded.header).to, appId);
          assert.ok(records, "Payload cannot precede the selected Iroh connection");
          records.send(raw);
        } catch (error) { fail(error); }
      },
      close() { if (!shuttingDown) fail(new Error("Fixture control socket lost")); },
    },
  });
  client = new RelayClient({
    url: `ws://127.0.0.1:${server.port}/${pathToken}`,
    identity: { deviceId: machineId, deviceName: "qualification", createdAt: "",
      ed25519PublicKey: machinePublic, ed25519PrivateKey: machineSeed },
    generateKeypair: generateEphemeralKeypair, trustedPeers,
    autoReconnect: false, getLicenseToken: () => "qualification-fixture",
    onAuthenticated: () => authenticated.resolve(),
    onHandshakeComplete: () => { establishments++; },
    onError: (code) => fail(new Error(code)),
  });
  client.setBus(control);
  const snapshot = (bus: MessageBus, msg: any) => {
    if (msg.type !== "request") return false;
    if (msg.method === "qualification.drop") {
      connection.close(42n, []);
      return true;
    }
    bus.publish(createMessage("response", { requestId: msg.requestId, ok: true, result: { frames: [] } }), "control");
    return true;
  };
  control.setInboundHandler((message, _channel, source) => {
    try {
      assert.equal(source, "relay");
      if (snapshot(control, message)) return;
      if (message.type !== "project:start") return;
      const projectId = message.projectId;
      assert.ok(["prototype-a", "prototype-b"].includes(projectId));
      let project = projects.get(projectId);
      if (!project) {
        const bus = new MessageBus();
        const screen = new TerminalFrameSource(100, 20);
        const runId = randomUUID();
        let attachmentId = randomUUID();
        let sequence = 0;
        let subscribed = false;
        let acknowledged = -1;
        const terminal = new TerminalSession({
          terminalId: projectId, cols: 100, rows: 20, cwd: scratch,
          command: process.platform === "win32" ? process.env.ComSpec ?? "cmd.exe" : "/bin/sh",
          args: process.platform === "win32" ? ["/d", "/q"] : [],
          onMessage(message) { if (message.type === "terminal:output") screen.feed(message.data); },
        });
        const handle = client!.attachStream(bus, { projectId,
          mayDeliver: () => !shuttingDown,
          mayAcceptFrom: (peer) => peer?.checkoutRouting ? null : { code: "NOT_ALLOWED", message: "checkout capability required" },
        });
        bus.setInboundHandler((message, _channel, source) => {
          try {
            assert.equal(source, "relay");
            if (snapshot(bus, message)) return;
            const msg = AbMessageSchema.parse(message);
            if (msg.type === "terminal:subscribe") {
              assert.equal(msg.terminalId, projectId);
              assert.equal(msg.version, TERMINAL_PROTOCOL_VERSION);
              attachmentId = randomUUID(); sequence = 0; acknowledged = -1;
              subscribed = true;
              bus.publish(createMessage("terminal:subscribed", { terminalId: projectId, runId, attachmentId,
                requestId: msg.requestId, version: TERMINAL_PROTOCOL_VERSION }), "control");
            } else if (msg.type === "terminal:ack" && msg.attachmentId === attachmentId) acknowledged = msg.sequence;
            else if (msg.type === "terminal:input") {
              assert.equal(msg.terminalId, projectId);
              const allowed = process.platform === "win32"
                ? ["set /a 731*37\r", "set /a 947*19\r"]
                : ["echo $((731*37))\n", "echo $((947*19))\n"];
              assert.ok(allowed.includes(msg.data));
              terminalInputs++;
              terminal.write(msg.data);
            }
          } catch (error) { fail(error); }
        });
        const timer = setInterval(() => {
          try {
            if (!subscribed || sequence - acknowledged > 2) return;
            const frame = screen.capture(performance.now());
            if (!frame) return;
            bus.publish(AbMessageSchema.parse(createMessage("terminal:frame", {
              ...frame, terminalId: projectId, runId, attachmentId, sequence: sequence++,
            })), "control");
          } catch (error) { fail(error); }
        }, 30);
        project = { streamId: handle.streamId, terminal, source: screen, bus, timer };
        projects.set(projectId, project);
        terminal.spawn();
      }
      control.publish(createMessage("stream-ready", { projectId, streamId: project.streamId }), "control");
    } catch (error) { fail(error); }
  });
  client.connect();
  await Promise.race([authenticated.promise, failed.promise]);
  console.error("prototype: bridge driver ready");
  const builder = Endpoint.builder();
  presetMinimal(builder);
  builder.bindAddr("127.0.0.1:0"); builder.alpns([alpn]);
  endpoint = await builder.bind();
  child.stdin.end(JSON.stringify({ endpointId: endpoint.id().toString(),
    addresses: endpoint.boundSockets().filter((x: string) => x.startsWith("127.0.0.1:")),
    machinePublic: testCase === "bad-agent-key" ? app.publicKey : machinePublic,
    machineId, appId, windows: process.platform === "win32", testCase,
    terminalVersion: TERMINAL_PROTOCOL_VERSION }) + "\n");
  const incoming = await endpoint.acceptNext();
  assert.ok(incoming);
  connection = await (await incoming.accept()).connect();
  console.error("prototype: Iroh connected");
  assert.equal(connection.remoteId().toString(), app.endpointId);
  assert.deepEqual(connection.alpn(), alpn);
  const stream = await connection.acceptBi();
  records = new Records(stream, fail);
  void connection.acceptBi().then(() => fail(new Error("EXTRA_STREAM")), () => {});
  void connection.acceptUni().then(() => fail(new Error("EXTRA_STREAM")), () => {});
  if (testCase.startsWith("client-")) {
    if (testCase === "client-oversize-record") await stream.send.writeAll([255, 255, 255, 255]);
    else if (testCase === "client-wrong-destination") {
      const raw = encodeRouteFrame({ type: "message", to: "wrong-app", channel: "control" }, Buffer.from("{}"), FrameKind.handshake);
      const prefix = Buffer.alloc(4); prefix.writeUInt32BE(raw.length);
      await stream.send.writeAll([...prefix, ...raw]);
    } else {
      const extra = await connection.openBi(); await extra.send.writeAll([1]);
    }
  } else void (async () => {
    try {
      while (!shuttingDown) {
        const frame = decodeRouteFrame(await records!.read());
        const header = RouteHeader.parse(frame.header);
        if (header.to !== machineId) throw new Error("INVALID_DESTINATION");
        fixtureSocket.send(encodeRouteFrame({ type: "message", from: appId,
          channel: header.channel, ts: Date.now() }, frame.payload, frame.kind));
      }
    } catch (error) {
      const expectedClose = String(error).includes("ApplicationClosed") ||
        (testCase === "disconnect" && String(error).includes("LocallyClosed"));
      if (!shuttingDown && !expectedClose) fail(error);
    }
  })();
  const result = await Promise.race([iterator.next(), failed.promise]);
  assert.equal(result.done, false);
  if (testCase === "terminal") {
    resultSchema.parse(JSON.parse(result.value!));
    assert.equal(establishments, 2);
    assert.equal(terminalInputs, 3, "No duplicate terminal inputs across project switches or rekey");
    assert.equal(projects.size, 2);
  } else if (testCase.startsWith("client-")) {
    z.object({ check: z.literal("peer-protocol-rejected"), testCase: z.literal(testCase) }).parse(JSON.parse(result.value!));
    assert.equal(establishments, 0); assert.equal(terminalInputs, 0); assert.equal(projects.size, 0);
  } else if (testCase === "disconnect") {
    z.object({ check: z.literal("pending-failed"), code: z.literal("E_SESSION_DOWN") }).parse(JSON.parse(result.value!));
    assert.equal(establishments, 1); assert.equal(terminalInputs, 0);
  } else {
    z.object({ check: z.literal("identity-rejected"), testCase: z.literal(testCase) }).parse(JSON.parse(result.value!));
    assert.equal(establishments, 0); assert.equal(terminalInputs, 0); assert.equal(projects.size, 0);
  }
  shuttingDown = true;
  lines.close();
  assert.equal(await exited, 0);
  console.log(JSON.stringify({ check: "encrypted-terminal-prototype", testCase, status: "pass", establishments,
    projects: projects.size, terminalInputs, framesSent: records.sent, framesReceived: records.received,
    peakQueuedBytes: records.peakQueuedBytes, profile: "loopback-no-relay",
    fixtures: ["account inventory", "control admission", "project catalog and dispatch"] }));
} catch (error) {
  const expected: Record<string, string> = {
    "oversize-record": "INVALID_RECORD_LENGTH", "wrong-destination": "INVALID_DESTINATION", "extra-stream": "EXTRA_STREAM",
  };
  if (!(error instanceof Error) || error.message !== expected[testCase]) throw error;
  assert.equal(terminalInputs, 0); assert.equal(projects.size, 0);
  console.log(JSON.stringify({ check: "native-protocol-rejection", testCase, status: "pass", reason: error.message, terminalInputs }));
} finally {
  shuttingDown = true;
  records?.close(); connection?.close(0n, []); child.kill();
  for (const project of projects.values()) {
    clearInterval(project.timer); project.source.dispose(); await project.terminal.close(0);
  }
  client?.close(); server?.stop(true); await endpoint?.close(); clearTimeout(watchdog);
}
