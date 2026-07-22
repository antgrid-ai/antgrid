import { test, expect } from "bun:test";
import { generateKeyPairSync, randomBytes, randomUUID, sign } from "node:crypto";
import { buildPairRequestSigBody } from "../../bridge/src/pair-request-verify";
import { setupPairFlowTestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";
import { waitAgentPairable } from "../support/pairing";

/**
 * A pair-request carries an Ed25519 possession proof over its transcript
 * (bound to `phonePubkey`). An attacker who claims a victim's `phonePubkey` but
 * signs with its OWN key produces a signature that cannot verify against the
 * claimed key — the agent rejects it with `pair-rejected{BAD_SIGNATURE}` on a
 * still-open socket (design §3.3: application-layer failures never close). The
 * relay forwards the request verbatim (it never verifies the phone signature —
 * that is the agent's job), so the reject originates at the agent's verifier.
 *
 * v3 note: the attacker authenticates with a normal signed `hello` (its own
 * key); the v2 register/challenge handshake is gone.
 */
function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const spki = pub.export({ type: "spki", format: "der" });
  return Buffer.from(spki.subarray(spki.length - 32)).toString("base64");
}

test("attacker claiming a victim pubkey is rejected with BAD_SIGNATURE (socket open)", async () => {
  const env = await setupPairFlowTestEnv();
  try {
    await waitAgentPairable(env);

    // The victim identity the attacker tries to impersonate (never used to sign).
    const victimPubkey = rawEdPubB64(generateKeyPairSync("ed25519").publicKey);

    // The attacker authenticates to the relay under its OWN key (valid hello).
    const attacker = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "attacker" });
    const attackerKp = generateKeyPairSync("ed25519");
    const attackerDeviceId = randomUUID();
    try {
      let outcome: { kind: "rejected"; reason: string } | { kind: "offline" } | { kind: "other"; detail: string } | null = null;
      for (let i = 0; i < 50; i++) {
        const nonce = randomBytes(24).toString("base64");
        const requestedAt = new Date().toISOString();
        // Sign the transcript that claims the VICTIM's pubkey, but with the
        // ATTACKER's private key → the signature can't verify against victimPubkey.
        const sigBody = buildPairRequestSigBody({
          agentDeviceId: env.agent.deviceId,
          phonePubkey: victimPubkey,
          phoneDeviceId: attackerDeviceId,
          nonce,
          requestedAt,
        });
        const phoneSignature = sign(null, Buffer.from(sigBody), attackerKp.privateKey).toString("base64");

        const rejectedP = attacker.waitFor((m: any) => m.type === "pair-rejected" && m.phonePubkey === victimPubkey, 5_000).catch(() => null);
        const errorP = attacker.waitForType("error", 5_000).catch(() => null);
        attacker.sendRaw({
          type: "pair-request",
          agentDeviceId: env.agent.deviceId,
          phonePubkey: victimPubkey,
          phoneDeviceId: attackerDeviceId,
          nonce,
          requestedAt,
          deadline: Date.now() + 8_000,
          phoneSignature,
        });
        const winner = await Promise.race([
          rejectedP.then((m) => (m ? { kind: "rejected" as const, reason: m.reason } : null)),
          errorP.then((m) => (m ? (m.code === "AGENT_OFFLINE" ? { kind: "offline" as const } : { kind: "other" as const, detail: m.code }) : null)),
        ]);
        if (winner?.kind === "rejected") { outcome = winner; break; }
        if (winner?.kind === "other") { outcome = winner; break; }
        // AGENT_OFFLINE / null → the agent isn't reachable yet; retry.
        await Bun.sleep(100);
      }

      if (!outcome || outcome.kind !== "rejected") {
        // Only "rejected"/"other" are ever assigned (offline retries), so the
        // non-rejected survivor here is "other" or a timeout.
        throw new Error(`expected pair-rejected, got ${outcome ? outcome.detail : "timeout"}`);
      }
      expect(outcome.reason).toBe("BAD_SIGNATURE");
      // Rejection is application-layer — the attacker's socket must stay open.
      expect(attacker.isClosed).toBe(false);
    } finally {
      await attacker.disconnect();
    }
  } finally {
    await env.teardown();
  }
}, 60_000);
