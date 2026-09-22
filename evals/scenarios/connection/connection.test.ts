import { describe, test, expect } from "bun:test";
import { startRelay, allocatePort } from "../../helpers/harness";
import { RelayClient } from "../../helpers/relay-client";

describe("central control resilience", () => {
  test("JSON control flood is rate-limited without closing the authenticated socket", async () => {
    const relay = await startRelay({
      port: allocatePort(),
      jsonRateLimitPerSec: 5,
      jsonRateLimitBurst: 5,
    });
    let app: RelayClient | null = null;
    try {
      app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app" });
      const limited = app.waitFor(
        (message: any) => message.type === "error" && message.code === "MESSAGE_RATE_LIMITED",
        5_000,
      );
      for (let sequence = 0; sequence < 60; sequence++) {
        app.sendRaw({ type: "unknown-control", sequence });
      }
      expect((await limited).retryable).toBe(true);
      expect(await app.waitForClose(500)).toBe(false);
    } finally {
      await app?.disconnect();
      relay.stop();
    }
  }, 20_000);
});