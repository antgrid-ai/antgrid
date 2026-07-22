import { test, expect } from "bun:test";
import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { setupPairFlowTestEnv, type TestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";

/**
 * v3 disconnect semantics (design §6.4): there is NO cascade close. When the
 * agent quits or is license-revoked, the granted phone's socket STAYS OPEN and
 * it is told the peer went away (`peer-offline`, plus `grant-revoked` on revoke)
 * — an error-frame notice, never a `PARENT_AGENT_DISCONNECTED` close (that close
 * reason no longer exists). This inverts the v2 cascade test.
 */

function rawEdPubB64(pub: KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

/** Pair a fresh RelayClient against the control plane via the QR-less
 *  account-membership proof, retrying the startup race (agent writes api.port
 *  before it finishes authenticating to the relay → typed AGENT_OFFLINE). */
async function pairApp(
  env: TestEnv,
  accountKey: { pubB64: string; privateKey: KeyObject },
): Promise<RelayClient> {
  const app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "eval-phone" });
  for (let i = 0; i < 50; i++) {
    try {
      const r = await app.pairWith(env.agent.deviceId, { timeoutMs: 8_000, accountKey });
      app.setPeerId(r.peerId);
      await app.performE2EHandshake(env.agent.deviceId, 10_000, {
        agentEd25519Pub: env.agent.ed25519Pubkey,
      });
      return app;
    } catch {
      if (app.isClosed) await app.reconnectAndAuth(env.relay.url);
      await Bun.sleep(150);
    }
  }
  await app.disconnect();
  throw new Error("agent never reached a pairable state in time");
}

test("agent normal quit: phone stays connected and gets peer-offline (no cascade close)", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  let app: RelayClient | null = null;
  try {
    app = await pairApp(env, { pubB64: accountPubB64, privateKey: accountKp.privateKey });

    const offlineP = app.waitForType("peer-offline", 8_000);
    await env.agent.kill();

    const offline = await offlineP;
    expect(offline.peerId).toBe(env.agent.deviceId);
    // The phone's socket must NOT be cascade-closed.
    expect(await app.waitForClose(1_000)).toBe(false);
    expect(app.isClosed).toBe(false);
  } finally {
    await app?.disconnect();
    await env.teardown();
  }
}, 60_000);

test("agent license revoke: phone stays connected and gets grant-revoked + peer-offline", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  let app: RelayClient | null = null;
  try {
    app = await pairApp(env, { pubB64: accountPubB64, privateKey: accountKp.privateKey });

    const revokedP = app.waitForType("grant-revoked", 8_000);
    const offlineP = app.waitForType("peer-offline", 8_000);
    // /internal/revoke closes the agent's socket (4002) and severs its grants;
    // granted phones get grant-revoked + peer-offline, sockets stay open.
    await env.licenseApi.revokeDevice(env.agent.deviceId);

    const revoked = await revokedP;
    expect(revoked.peerDeviceId).toBe(env.agent.deviceId);
    expect(revoked.reason).toBe("REVOKED");
    const offline = await offlineP;
    expect(offline.peerId).toBe(env.agent.deviceId);
    expect(await app.waitForClose(1_000)).toBe(false);
    expect(app.isClosed).toBe(false);
  } finally {
    await app?.disconnect();
    await env.teardown();
  }
}, 60_000);
