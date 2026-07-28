import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/**
 * Failure-matrix row: the app's socket drops (network blip, backgrounding,
 * etc.) — an unintentional close, not a deliberate `disconnect()`. Recovery
 * is a plain redial under the SAME identity: no pairing ceremony, since
 * admission is account trust (Phase B), not a grant tied to a specific
 * socket.
 *
 * `TestApp.dropSocket()` hard-closes the WS without touching E2E/session
 * bookkeeping (see its doc comment) — a real network drop looks the same
 * from the app's side. `reconnect()` then has to open a fresh authenticated
 * socket AND re-run the E2E handshake to prove the session is actually live
 * again, not just that the transport reconnected.
 *
 * What makes this go red without the fix: if the bridge's single-active-phone
 * tracking didn't let the SAME identity redial after a drop (e.g. treated the
 * stale socket as still "active" and rejected the new one), `reconnect()`
 * would report `connected:false`, or the post-reconnect `waitForStateSnapshot`
 * would time out because the new socket's handshake was silently dropped.
 */
test("an app socket drop re-establishes on redial without re-pairing", async () => {
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
