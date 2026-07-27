import { test, expect } from "bun:test";
import { setupTestEnv, handshakeWithoutPairing } from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
import { createMessage } from "../../bridge/src/protocol";

/** Round-trip the control-plane `state.snapshot` RPC and assert a sane
 *  (`ok:true`) response — mirrors `gate-account-trust.test.ts`'s helper of
 *  the same shape (not imported, to keep this file's dependency on that one
 *  minimal; the RPC itself is the shared contract, not the helper). */
async function assertSnapshot(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-inventory-miss-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

/**
 * Failure-matrix row: a phone is added to the account AFTER the agent
 * already started (and cached its account-device inventory). The bridge's
 * `TrustedPeersProvider` misses the unknown identity on its first
 * client-hello, throttled-refreshes from `/account/devices/me/peers`
 * (`noteMiss()`), and a LATER client-hello attempt is admitted — no pairing
 * ceremony, no bridge restart.
 *
 * `env.license.addAccountDevice({ kind: "app" })` registers a FRESH identity
 * with the fake license API's account inventory strictly AFTER
 * `setupTestEnv` already returned — i.e. after the agent's own startup
 * fetch — so this is a genuinely late addition, unlike the up-front seeding
 * `setupTestEnv` does for `env.appIdentity`. See its doc comment.
 *
 * This drives the retry itself via `handshakeWithoutPairing` (SAME socket,
 * resending `client-hello` — the bridge drops an unknown identity's first
 * hello silently rather than answering with anything the phone could
 * distinguish from "not yet", so a bare single-shot handshake attempt here
 * would deterministically time out; only a RESENT hello lands after the
 * inventory refresh completes) rather than `TestApp.connect` (documented
 * single-shot).
 *
 * What makes this go red without the fix: if the bridge only ever consulted
 * its STARTUP-time inventory snapshot (no `noteMiss()`/refresh), every
 * resend would keep missing and `handshakeWithoutPairing` would exhaust its
 * retry budget and throw — a real, catchable failure, not a vacuous pass.
 */
test("a phone added to the account after agent start is admitted without ceremony", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  let phone: RelayClient | undefined;
  try {
    const late = await env.license.addAccountDevice({ kind: "app" });

    phone = await RelayClient.connectAndAuth(env.relay.url, {
      deviceType: "app",
      name: "gate-inventory-miss-app",
      deviceId: late.deviceId,
      identity: late,
    });
    // Bounded well under this test's 60s timeout (15 * (2000+300) ~= 34.5s
    // worst case) so a genuine admission failure surfaces as this function's
    // own thrown assertion, not an opaque Bun test-timeout.
    await handshakeWithoutPairing(phone, env.agentDeviceId, env.agent.ed25519Pubkey, { attempts: 15 });

    await assertSnapshot(phone, "baseline");
  } finally {
    await phone?.disconnect();
    await env.teardown();
  }
}, 60_000);
