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

for (const type of ["stream-open", "stream-close"] as const) {
  test(`${type} is a protocol violation and closes 1008`, async () => {
    relay = startServer({ ...defaultConfig, jsonRateLimitPerSec: 0, jsonRateLimitBurst: 0 });
    const { ws } = await connectHello(relay, { deviceId: `retired-${type}` });
    const error = waitForMessage(ws);
    const closed = waitForClose(ws);

    ws.send(JSON.stringify({ type, streamId: "s1" }));

    expect(await error).toMatchObject({
      type: "error",
      code: "PROTOCOL_VIOLATION",
      retryable: false,
    });
    expect(await closed).toBe(1008);
  });
}