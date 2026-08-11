/**
 * Bootstrap + admission end-to-end eval.
 *
 * Verifies that an agent booted from a stdin `BootstrapPayload` (remote mode)
 * mints a token from the fake license API, authenticates with the relay via a
 * signed v3 `hello`, and can be reached by an app with no pairing ceremony —
 * account-trust admission is the production path (the app-side pairing
 * surface is deleted; `autoOpen`/`reconnect` connect exactly as
 * `setupTestEnv` does here). This replaces the old on-disk enrollment model
 * (seeded identity.json + jwt.json), removed in the OAuth migration.
 */
import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";

test("agent boots from stdin bootstrap, connects to relay, and admits an account-trusted app", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    // v3 registers the BARE deviceUuid — one machine socket, projects are streams.
    expect(env.agentDeviceId).toBeTruthy();
    expect(env.agent.ed25519Pubkey).toBeTruthy();

    // setupTestEnv already completed a full E2E handshake with no pair-request
    // ever sent (see gate-account-trust.test.ts for the dedicated proof); issue
    // the state.snapshot RPC directly and assert `ok:true` (mirrors
    // gate-account-trust.test.ts's assertSnapshot) — this is the positive proof
    // this eval cares about. `pullStateSnapshot` is NOT that proof: it swallows
    // its own wait-for-response timeout (`.catch(() => null)`) and falls
    // through silently when `res` is falsy, so an agent that never answers
    // wouldn't fail this test.
    const requestId = "enrollment-snapshot";
    const responseP = env.app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
    env.app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
    const res = (await responseP) as { ok?: boolean };
    expect(res.ok).toBe(true);
  } finally {
    await env.teardown();
  }
}, 60_000);
