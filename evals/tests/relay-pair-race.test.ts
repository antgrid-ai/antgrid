import { test, expect } from "bun:test";
import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { setupPairFlowTestEnv, type TestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";

/**
 * v3 pairing resolves to a SINGLE active phone per machine (design §5.3). Two
 * phones (distinct identities, same account) that pair against one agent can't
 * both hold the grant: creating the second grant displaces the first, which
 * receives a typed `grant-revoked{PEER_REPLACED}` on a STILL-OPEN socket — never
 * a close, and never a clobbered rendezvous (the pending pair is keyed by the
 * relay-stamped `pairId`, not a client-claimed id, §5.2). This replaces the v2
 * single-use-pairCode race (the control-plane pairCode window has no eval
 * open-hook in v3 — evals pair via account membership, see setupTestEnv).
 */

function rawEdPubB64(pub: KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

async function pairMembership(
  env: TestEnv,
  accountKey: { pubB64: string; privateKey: KeyObject },
  name: string,
): Promise<RelayClient> {
  const app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name });
  for (let i = 0; i < 50; i++) {
    try {
      const r = await app.pairWith(env.agent.deviceId, { timeoutMs: 8_000, accountKey });
      app.setPeerId(r.peerId);
      await app.performE2EHandshake(env.agent.deviceId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });
      return app;
    } catch {
      if (app.isClosed) await app.reconnectAndAuth(env.relay.url);
      await Bun.sleep(150);
    }
  }
  await app.disconnect();
  throw new Error(`${name} never became pairable in time`);
}

test("second phone pairing displaces the first (grant-revoked PEER_REPLACED, sockets open)", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  const accountKey = { pubB64: accountPubB64, privateKey: accountKp.privateKey };
  let phoneA: RelayClient | null = null;
  let phoneB: RelayClient | null = null;
  try {
    phoneA = await pairMembership(env, accountKey, "phone-a");

    // Arm A's displacement notice BEFORE B pairs so the fast revoke isn't raced.
    const displacedP = phoneA.waitForType("grant-revoked", 8_000);
    phoneB = await pairMembership(env, accountKey, "phone-b");

    const displaced = await displacedP;
    expect(displaced.reason).toBe("PEER_REPLACED");
    expect(displaced.peerDeviceId).toBe(env.agent.deviceId);
    // The displaced phone keeps its socket — the notice is an error frame, not a close.
    expect(await phoneA.waitForClose(1_000)).toBe(false);
    expect(phoneA.isClosed).toBe(false);
    expect(phoneB.isClosed).toBe(false);
  } finally {
    await phoneA?.disconnect();
    await phoneB?.disconnect();
    await env.teardown();
  }
}, 60_000);
