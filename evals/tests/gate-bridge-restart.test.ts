import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/** A bridge restart retires the native connection and its in-memory E2E keys.
 * Recovery redials the same enrolled endpoint and establishes fresh E2E without
 * changing the independent central control connection. */test("a bridge restart mid-session re-establishes with no user action", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const app = await TestApp.connect(env);
    await app.waitForStateSnapshot();

    // No re-pair, no reconnect call on `app` here — only the agent process
    // is touched. `restart()` mutates `env.agent` in place (same object), so
    // `env.agent.ed25519Pubkey` below still reads the (stable) identity.
    await env.agent.restart();

    const snap = await app.waitForStateSnapshot({ timeoutMs: 30_000 });
    expect(snap.ok).toBe(true);

    await app.disconnect();
  } finally {
    await env.teardown();
  }
}, 60_000);
