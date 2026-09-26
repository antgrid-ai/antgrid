import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connectHello,
  waitForMessage,
  waitForClose,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

test("post-auth binary frame -> PROTOCOL_VIOLATION + close 1008", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "binary-agent" });
  const error = waitForMessage(ws);
  const closed = waitForClose(ws);

  // The relay is control-only: any binary frame is a violation regardless of
  // size, so a small one is enough to prove the rejection isn't size-gated.
  ws.send(new Uint8Array(1024));

  expect(await error).toMatchObject({
    type: "error",
    code: "PROTOCOL_VIOLATION",
    retryable: false,
  });
  expect(await closed).toBe(1008);
});

test("over-bound text frame closes the socket", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "oversized-agent" });
  const closed = waitForClose(ws);

  // One byte past MAX_CONTROL_FRAME_BYTES (server.ts `maxPayloadLength`).
  // Bun/uWebSockets enforces that cap by dropping the connection without a
  // close frame, so the client observes 1006, not 1009.
  const oversized = "x".repeat(64 * 1024 + 1);
  ws.send(oversized);

  expect(await closed).toBe(1006);
});

test("push:deliver at the schema maximum for every field is accepted", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "push-agent-max" });
  const resultP = waitForMessage(ws);

  ws.send(JSON.stringify({
    type: "push:deliver",
    pushToken: "t".repeat(4096),
    provider: "fcm",
    blob: { epk: "e".repeat(256), box: "b".repeat(8192) },
  }));

  const result = await resultP;
  // No fcmSender configured on this server; "unconfigured" still proves the
  // frame parsed and was routed, not rejected on size or schema.
  expect(result).toEqual({ type: "push:result", pushToken: "t".repeat(4096), ok: false, reason: "unconfigured" });
});

test("JSON control-message flood is rate limited without closing the socket", async () => {
  relay = startServer({ ...defaultConfig, jsonRateLimitPerSec: 2, jsonRateLimitBurst: 2 });
  const { ws } = await connectHello(relay, { deviceId: "control-flood" });

  for (let i = 0; i < 2; i++) {
    const pong = waitForMessage(ws);
    ws.send(JSON.stringify({ type: "ping" }));
    expect(await pong).toEqual({ type: "pong" });
  }

  const limited = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "ping" }));
  expect(await limited).toMatchObject({
    type: "error",
    code: "MESSAGE_RATE_LIMITED",
    retryable: true,
  });
  expect(ws.readyState).toBe(WebSocket.OPEN);

  await new Promise((resolve) => setTimeout(resolve, 1_100));
  const pong = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "ping" }));
  expect(await pong).toEqual({ type: "pong" });
}, 8_000);

test("unknown control messages remain recoverable INVALID_MESSAGE errors", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "unknown-control" });
  const error = waitForMessage(ws);

  ws.send(JSON.stringify({ type: "future-control-verb" }));

  expect(await error).toMatchObject({
    type: "error",
    code: "INVALID_MESSAGE",
    retryable: false,
  });
  expect(ws.readyState).toBe(WebSocket.OPEN);
});
