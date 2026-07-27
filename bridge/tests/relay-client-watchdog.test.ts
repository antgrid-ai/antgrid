// Task 1 added a relay json `{"type":"ping"}` -> `{"type":"pong"}` echo on the
// same socket. The heartbeat previously fired `ws.ping()`, whose reply is
// unobservable from a browser-style WebSocket, so a half-open socket (e.g.
// after machine sleep) lingered until the OS TCP timeout. This suite proves
// the heartbeat now probes with the observable json ping and force-closes a
// socket whose probe goes unanswered for a full interval — the EXISTING close
// handler (relay-client.ts:558-572) then owns reconnection; this suite never
// reimplements that decision, only observes it via a real close event.
import { test, expect, afterEach } from "bun:test";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { RelayClient } from "../src/relay-client";
import { generateEphemeralKeypair } from "../src/key-exchange";
import vector from "../../evals/fixtures/relay-hello-vector.json";

let clients: RelayClient[] = [];
let servers: ReturnType<typeof Bun.serve>[] = [];
afterEach(() => {
  for (const c of clients.splice(0)) try { c.close(); } catch {}
  for (const s of servers.splice(0)) try { s.stop(true); } catch {}
});

/** Minimal relay stub: authenticates any `hello` with a `welcome`, and — unless
 *  `answerPing` is false — echoes `{"type":"pong"}` for every inbound
 *  `{"type":"ping"}`, mirroring Task 1's relay-side echo. `nextMessage()`
 *  resolves the next time the relay sees a message, race-free because it's
 *  armed before the client sends. */
function startStubRelay(opts: { answerPing?: boolean } = {}) {
  let onMessage: ((text: string) => void) | null = null;
  const server = Bun.serve({
    port: 0,
    fetch: (req, srv) => (srv.upgrade(req) ? undefined : new Response("no")),
    websocket: {
      message(ws, raw) {
        const text = String(raw);
        const cb = onMessage;
        onMessage = null;
        cb?.(text);
        const msg = JSON.parse(text);
        if (msg.type === "hello") {
          ws.send(JSON.stringify({ type: "welcome", deviceId: msg.deviceId, epoch: 1, serverTime: new Date().toISOString() }));
        } else if (msg.type === "ping" && opts.answerPing !== false) {
          ws.send(JSON.stringify({ type: "pong" }));
        }
      },
    },
  });
  servers.push(server);
  return {
    server,
    nextMessage: () => new Promise<string>((resolve) => { onMessage = resolve; }),
  };
}

function makeClient(url: string) {
  const client = new RelayClient({
    url,
    identity: {
      deviceId: vector.fields.deviceId,
      deviceName: "agent",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: vector.fields.publicKey,
      ed25519PrivateKey: Buffer.from(vector.ed25519.seedHex, "hex").toString("base64"),
    },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: () => vector.fields.licenseToken,
  });
  clients.push(client);
  return client;
}

/** Connects a real client to a real (stubbed) relay through `welcome`, and
 *  returns `advanceHeartbeat` — calling `heartbeatTick()` directly rather than
 *  faking the 25s `setInterval` clock. */
async function connectToWelcome(relayOpts: { answerPing?: boolean } = {}) {
  const relay = startStubRelay(relayOpts);
  const client = makeClient(`ws://127.0.0.1:${relay.server.port}`);
  const welcomed = new Promise<void>((resolve) => { (client as any).opts.onAuthenticated = resolve; });
  client.connect();
  await welcomed;
  const advanceHeartbeat = () => (client as any).heartbeatTick();
  return { client, relay, advanceHeartbeat };
}

test("heartbeat sends a json ping and arms the watchdog", async () => {
  const { client, relay, advanceHeartbeat } = await connectToWelcome();

  const nextMsg = relay.nextMessage(); // armed before the send — race-free
  advanceHeartbeat();

  expect(await nextMsg).toBe(JSON.stringify({ type: "ping" }));
  expect((client as any).awaitingPong).toBe(true);
});

test("missed pong for a full interval force-closes the socket, and the close handler schedules reconnect", async () => {
  const { client, advanceHeartbeat } = await connectToWelcome({ answerPing: false });
  let scheduled = false;
  (client as any).scheduleReconnect = () => { scheduled = true; };
  const disconnected = new Promise<void>((resolve) => { (client as any).opts.onDisconnected = resolve; });

  advanceHeartbeat(); // ping sent, awaitingPong = true
  advanceHeartbeat(); // no pong arrived since -> force close
  await disconnected; // real "close" listener ran synchronously before this resolves

  expect((client as any).ws?.readyState).not.toBe(WebSocket.OPEN);
  expect(scheduled).toBe(true);
});

test("a pong (or any inbound frame) clears the pending watchdog", async () => {
  const { client, advanceHeartbeat } = await connectToWelcome(); // answerPing defaults true
  const gotPong = new Promise<void>((resolve) => {
    const orig = (client as any).handleTextMessage.bind(client);
    (client as any).handleTextMessage = (raw: string) => {
      orig(raw);
      if (raw.includes('"pong"')) resolve();
    };
  });

  advanceHeartbeat(); // ping sent, awaitingPong = true
  await gotPong;
  expect((client as any).awaitingPong).toBe(false);

  advanceHeartbeat(); // watchdog cleared -> this just sends another ping, no close
  expect((client as any).ws?.readyState).toBe(WebSocket.OPEN);
});

test("a decoded binary frame clears the pending watchdog, not just JSON traffic", () => {
  // Uses the `forTest` + `encodeRouteFrame` seam from handshake-pull.test.ts
  // rather than a real socket: a busy binary connection (sealed terminal/file
  // data) must count as liveness even when JSON pongs are delayed, and
  // `handleBinaryFrame` is exercised directly there too. The frame's sealed
  // payload is garbage and will fail to decrypt (no established/pending E2E
  // session on a bare forTest client) — that's fine, since a structurally
  // valid route frame is itself proof the socket delivered real bytes, before
  // handleBinaryFrame dispatches to the handshake/sealed handler.
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: "phone-1",
    deviceId: "agent-1",
  });
  clients.push(client);
  (client as any).awaitingPong = true;

  const frame = encodeRouteFrame(
    { type: "message", from: "phone-1", channel: "control" },
    Buffer.from("not a real ciphertext"),
    FrameKind.sealed,
  );
  (client as any).handleBinaryFrame(Buffer.from(frame));

  expect((client as any).awaitingPong).toBe(false);
});
