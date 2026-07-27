import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/**
 * Failure-matrix row: the app's account token expires mid-session. Recovery
 * is time-based, not user-driven — the next redial mints a fresh token and
 * succeeds with no re-pair (mirrors the bridge's own `LICENSE_EXPIRED`
 * handling: terminal for THAT hello, but not identity-dead — see
 * `bridge/CLAUDE.md`'s `relay-client.ts` entry).
 *
 * `env.license.expireNextToken()` arms exactly the NEXT
 * `env.license.mintAppToken()` call to return an already-expired sentinel;
 * `TestApp.reconnect()` mints a fresh token on every redial (see its doc
 * comment), so the first post-arm reconnect presents the expired token and
 * the second mints normally again.
 *
 * What makes this go red without the fix: if the relay's fake license gate
 * didn't distinguish the expired sentinel from a normal token, the first
 * `reconnect()` would report `connected:true` instead of the expected
 * `LICENSE_EXPIRED` rejection — a real assertion failure, not a vacuous pass.
 */
test("a token that expires mid-session recovers on the next mint", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const app = await TestApp.connect(env);
    await app.waitForStateSnapshot();

    env.license.expireNextToken();
    app.dropSocket();

    const first = await app.reconnect();
    expect(first.connected).toBe(false);
    if (first.connected) throw new Error("unreachable"); // narrow for TS
    expect(first.reason).toMatch(/LICENSE_EXPIRED/);

    // The arm was consumed by the first reconnect's mint — this one is a
    // normal token again, no manual re-arming, no re-pair.
    const second = await app.reconnect();
    expect(second.connected).toBe(true);

    const snap = await app.waitForStateSnapshot({ timeoutMs: 15_000 });
    expect(snap.ok).toBe(true);

    await app.disconnect();
  } finally {
    await env.teardown();
  }
}, 45_000);
