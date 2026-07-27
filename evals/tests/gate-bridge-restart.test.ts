import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/**
 * Failure-matrix row: a bridge (agent) process restart mid-session. The
 * app↔relay socket is never touched — only the agent's process dies and
 * respawns (fresh epoch, no in-memory E2E keys) — so recovery has to come
 * from the E2E session re-establishing itself, not from any relay-level
 * reconnect. `TestApp.waitForStateSnapshot` is what actually drives that: it
 * tries the live session first, and on failure re-runs the E2E handshake on
 * the SAME socket (no new WebSocket, no re-pair) until it succeeds or times
 * out — see its doc comment in `../helpers/test-app.ts`.
 *
 * What makes this go red without the fix: if `AgentHandle.restart()` didn't
 * actually respawn against the SAME `abDir` (so `paired-phones.json` trust
 * survived) and the SAME auth/deviceUuid/pubkey, the post-restart handshake
 * attempts would keep failing (unknown identity / pubkey mismatch) until
 * `waitForStateSnapshot`'s deadline, and the test would time out and fail.
 */
test("a bridge restart mid-session re-establishes with no user action", async () => {
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
