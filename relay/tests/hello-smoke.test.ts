import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connect,
  connectHello,
  makeHello,
  waitForMessage,
  type RelayServer,
} from "./helpers/relay-harness.js";

let relay: RelayServer | undefined;

afterEach(() => {
  relay?.stop();
  relay = undefined;
});

test("agent hello → welcome", async () => {
  relay = startServer(defaultConfig);
  const { welcome } = await connectHello(relay, { deviceId: "agent-1", deviceType: "agent" });
  expect(welcome.type).toBe("welcome");
  expect(welcome.deviceId).toBe("agent-1");
  expect(typeof welcome.serverTime).toBe("string");
});

test("app hello → welcome", async () => {
  relay = startServer(defaultConfig);
  const { welcome } = await connectHello(relay, { deviceId: "app-1", deviceType: "app" });
  expect(welcome.type).toBe("welcome");
  expect(welcome.deviceId).toBe("app-1");
});

test("non-hello first message → PROTOCOL_VIOLATION + close 1008", async () => {
  relay = startServer(defaultConfig);
  const ws = await connect(relay);
  const closed = new Promise<number>((resolve) => {
    ws.onclose = (e) => resolve(e.code);
  });
  const first = waitForMessage(ws);
  ws.send(JSON.stringify({ type: "stream-open", streamId: "s1" }));
  const err = await first;
  expect(err.type).toBe("error");
  expect(err.code).toBe("PROTOCOL_VIOLATION");
  expect(err.retryable).toBe(false);
  expect(await closed).toBe(1008);
});

test("clock-skewed ts → AUTH_FAILED with serverTime, retryable:true", async () => {
  relay = startServer(defaultConfig);
  const skewedTs = new Date(Date.now() - 10 * 60_000).toISOString();
  const { hello } = await makeHello(relay, { deviceId: "agent-skew", deviceType: "agent", ts: skewedTs });
  const ws = await connect(relay);
  const first = waitForMessage(ws);
  ws.send(JSON.stringify(hello));
  const err = await first;
  expect(err.type).toBe("error");
  expect(err.code).toBe("AUTH_FAILED");
  expect(err.retryable).toBe(true);
  expect(typeof err.serverTime).toBe("string");
});
