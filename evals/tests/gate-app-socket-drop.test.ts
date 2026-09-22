import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/** A central socket drop is independent of the healthy leased native payload.
 * Reconnecting authenticates control again without redialing or rekeying Iroh. */test("a central socket drop reconnects without disturbing native payloads", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const app = await TestApp.connect(env);
    await app.waitForStateSnapshot();

    app.dropSocket();
    const reconnected = await app.reconnect();
    expect(reconnected.connected).toBe(true);

    const snap = await app.waitForStateSnapshot({ timeoutMs: 15_000 });
    expect(snap.ok).toBe(true);

    await app.disconnect();
  } finally {
    await env.teardown();
  }
}, 45_000);
