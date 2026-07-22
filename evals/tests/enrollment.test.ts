/**
 * Bootstrap + pair end-to-end eval.
 *
 * Verifies that an agent booted from a stdin `BootstrapPayload` (remote mode)
 * mints a token from the fake license API, authenticates with the relay via a
 * signed v3 `hello`, and can be paired by an app. This replaces the old on-disk
 * enrollment model (seeded identity.json + jwt.json), removed in the OAuth
 * migration. v3: the phone pairs the bare machine deviceUuid (one socket;
 * projects are streams); the eval pairs via the QR-less account-membership path,
 * since the control-plane pairCode window has no eval open-hook.
 */
import { test, expect } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { setupPairFlowTestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";

function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

test("agent boots from stdin bootstrap, connects to relay, can be paired", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  let app: RelayClient | null = null;
  try {
    // Identity now comes from the bootstrap payload (no on-disk identity/jwt).
    // v3 registers the BARE deviceUuid — deviceId and the deprecated rawDeviceId
    // alias are the same machine uuid.
    expect(env.agent.deviceId).toBeTruthy();
    expect(env.agent.ed25519Pubkey).toBeTruthy();
    expect(env.agent.deviceId).toBe(env.agent.rawDeviceId);

    // Pairing only succeeds if the agent authenticated with the relay (which
    // required a successfully minted token). Retry the spawn race.
    app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "eval-phone" });
    let paired = false;
    for (let i = 0; i < 50; i++) {
      try {
        const r = await app.pairWith(env.agent.deviceId, {
          timeoutMs: 8_000,
          accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
        });
        app.setPeerId(r.peerId);
        await app.performE2EHandshake(env.agent.deviceId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });
        paired = true;
        break;
      } catch {
        if (app.isClosed) await app.reconnectAndAuth(env.relay.url);
        await Bun.sleep(150);
      }
    }
    expect(paired).toBe(true);
  } finally {
    await app?.disconnect();
    await env.teardown();
  }
}, 60_000);
