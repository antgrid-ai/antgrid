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

  // Larger than any control frame, but within the retired payload-frame bound.
  ws.send(new Uint8Array(128 * 1024));

  expect(await error).toMatchObject({
    type: "error",
    code: "PROTOCOL_VIOLATION",
    retryable: false,
  });
  expect(await closed).toBe(1008);
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
test("metrics expose control-plane state only", async () => {
  relay = startServer(defaultConfig);
  await connectHello(relay, { deviceId: "metrics-agent" });

  const response = await fetch(`http://localhost:${relay.server.port}/metrics`);
  expect(response.status).toBe(200);
  const metrics = (await response.json()) as Record<string, unknown>;
  expect(metrics).toMatchObject({ activeConnections: 1 });
  for (const retired of ["messagesPerSec", "backpressureDrops", "routeRateLimitDrops"]) {
    expect(metrics).not.toHaveProperty(retired);
  }
});