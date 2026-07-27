import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connect,
  connectHello,
  waitForMessage,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

test("post-hello ping is answered with pong on the same socket", async () => {
  relay = startServer(defaultConfig);
  const { ws } = await connectHello(relay, { deviceId: "ping-agent" });

  const reply = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "ping" }));
  expect(await reply).toEqual({ type: "pong" });
  expect(ws.readyState).toBe(WebSocket.OPEN);
});

test("ping before hello is still a protocol violation", async () => {
  relay = startServer(defaultConfig);
  const ws = await connect(relay);
  const closed = new Promise<number>((resolve) => {
    ws.onclose = (e) => resolve(e.code);
  });
  const first = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "ping" }));
  const err = await first;
  expect(err.type).toBe("error");
  expect(err.code).toBe("PROTOCOL_VIOLATION");
  expect(err.retryable).toBe(false);
  expect(await closed).toBe(1008);
});
