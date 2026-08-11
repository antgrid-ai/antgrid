import { test, expect } from "bun:test";
import { createHmac } from "node:crypto";
import { RELAY_INTERNAL_SECRET, setupTestEnv } from "../helpers/harness";

/**
 * v3 disconnect semantics: there is NO cascade close. When the
 * agent quits or is license-revoked, the phone's socket STAYS OPEN and it is
 * told the peer went away (`peer-offline`, fanned out by same-account
 * presence, `relay/src/server.ts`'s `fanOutPeerPresence`) — an error-frame
 * notice, never a `PARENT_AGENT_DISCONNECTED` close (that close reason no
 * longer exists). This inverts the v2 cascade test.
 *
 * `grant-revoked` is NOT asserted here, and can no longer even be asserted:
 * there is no relay code path that emits it and no wire schema that would let
 * a phone parse one if it arrived. A pure account-trust phone (this file) was
 * never eligible for a grant in the first place, so its absence here is not a
 * gap in this test's coverage — it is enforced by the wire type not existing.
 */

/** POST /internal/revoke on the relay (HMAC-signed) — mirrors what web's
 *  device-revocation flow does in production. */
async function revokeDevice(relayHttpUrl: string, deviceId: string): Promise<void> {
  const body = JSON.stringify({ deviceId });
  const sig = createHmac("sha256", RELAY_INTERNAL_SECRET).update(body).digest("hex");
  const res = await fetch(`${relayHttpUrl}/internal/revoke`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-antgrid-signature": sig },
    body,
  });
  if (!res.ok) {
    throw new Error(`/internal/revoke failed: ${res.status} ${await res.text()}`);
  }
}

test("agent normal quit: phone stays connected and gets peer-offline (no cascade close)", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const app = env.app;
    const offlineP = app.waitForType("peer-offline", 8_000);
    await env.agent.kill();

    const offline = await offlineP;
    expect(offline.peerId).toBe(env.agentDeviceId);
    // The phone's socket must NOT be cascade-closed.
    expect(await app.waitForClose(1_000)).toBe(false);
    expect(app.isClosed).toBe(false);
  } finally {
    await env.teardown();
  }
}, 60_000);

test("agent license revoke: phone stays connected and gets peer-offline", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    const app = env.app;
    const offlineP = app.waitForType("peer-offline", 8_000);
    // /internal/revoke closes the agent's socket (4002, LICENSE_REVOKED); the
    // resulting close fans out peer-offline to same-account phones. Sockets
    // stay open.
    await revokeDevice(env.relay.httpUrl, env.agentDeviceId);

    const offline = await offlineP;
    expect(offline.peerId).toBe(env.agentDeviceId);
    expect(await app.waitForClose(1_000)).toBe(false);
    expect(app.isClosed).toBe(false);
  } finally {
    await env.teardown();
  }
}, 60_000);
