import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { setupPairFlowTestEnv, type TestEnv } from "../helpers/test-env";
import { RelayClient, PairAgentOfflineError } from "../helpers/relay-client";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Merge-gate item 2 (design §6.1, §12): the acked handshake's step 5 kills the
 * asymmetric-establishment wedge by construction — the phone retransmits
 * `app:ready` every 2s until `established`, and neither side dispatches app
 * traffic before its own terminal event. These three scenarios each exercise
 * ONE fresh, never-established RelayClient — `performE2EHandshake` clobbers
 * `established` unconditionally on receiving agent-hello (it's the INITIAL
 * handshake path; make-before-break for an ALREADY-established session is
 * `rekey()`, covered by gate-rekey.test.ts), so reusing a confirmed client
 * across sub-scenarios here would conflate the two code paths.
 */
function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

describe("gate: wedge recovery", () => {
  let env: TestEnv;
  let accountKp: { publicKey: import("node:crypto").KeyObject; privateKey: import("node:crypto").KeyObject };
  let accountPubB64: string;

  beforeAll(async () => {
    accountKp = generateKeyPairSync("ed25519");
    accountPubB64 = rawEdPubB64(accountKp.publicKey);
    env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  });

  afterAll(async () => {
    await env?.teardown();
  });

  /** Fresh phone identity, paired via the account-membership auto-pair path
   *  (no pairCode/window needed). Retries absorb the startup race documented
   *  in harness.ts's setupTestEnv (api.port appears before the agent finishes
   *  authenticating to the relay). */
  async function pairFreshPhone(): Promise<RelayClient> {
    const app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "gate-wedge" });
    for (let i = 0; i < 30; i++) {
      try {
        const r = await app.pairWith(env.agent.deviceId, {
          timeoutMs: 8_000,
          accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
        });
        app.setPeerId(r.peerId);
        return app;
      } catch (err) {
        if (err instanceof PairAgentOfflineError) {
          if (app.isClosed) await app.reconnectAndAuth(env.relay.url);
          await Bun.sleep(200);
          continue;
        }
        throw err;
      }
    }
    throw new Error("pairing never succeeded");
  }

  test("dropped first app:ready — the 2s retransmit still establishes", async () => {
    const app = await pairFreshPhone();
    try {
      await app.performE2EHandshake(env.agent.deviceId, 8_000, {
        agentEd25519Pub: env.agent.ed25519Pubkey,
        dropFirstAppReady: true,
      });
      // Session must be usable post-establishment (sendEncrypted throws if
      // there's no confirmed transport).
      expect(() => app.sendEncrypted(createMessage("ping", {}))).not.toThrow();
    } finally {
      await app.disconnect();
    }
  }, 15_000);

  test("suppressed agent `established` once — phone retransmits app:ready and establishes", async () => {
    const app = await pairFreshPhone();
    try {
      await app.performE2EHandshake(env.agent.deviceId, 8_000, {
        agentEd25519Pub: env.agent.ed25519Pubkey,
        dropEstablished: true,
      });
      expect(() => app.sendEncrypted(createMessage("ping", {}))).not.toThrow();
    } finally {
      await app.disconnect();
    }
  }, 15_000);

  test("noRetransmit + dropped app:ready times out, then a FRESH attempt recovers (no permanent wedge)", async () => {
    const app = await pairFreshPhone();
    try {
      // Plain try/catch, not `expect(...).rejects.toThrow()`: the latter's
      // extra microtask/scheduling overhead around the rejection was enough
      // to reliably wedge the FOLLOWING fresh attempt in this exact scenario
      // (reproduced independently of spawnAgent/describe/setupPairFlowTestEnv —
      // isolated to that specific matcher). Not a v3 behavior difference, just
      // a test-authoring pitfall; avoided here rather than chased further.
      let timedOut = false;
      try {
        await app.performE2EHandshake(env.agent.deviceId, 3_000, {
          agentEd25519Pub: env.agent.ed25519Pubkey,
          dropFirstAppReady: true,
          noRetransmit: true,
        });
      } catch {
        timedOut = true;
      }
      expect(timedOut).toBe(true);

      // Same socket/identity, no hooks this time. If either side retained
      // half-open state from the failed attempt, this would wedge too.
      await app.performE2EHandshake(env.agent.deviceId, 8_000, {
        agentEd25519Pub: env.agent.ed25519Pubkey,
      });
      expect(() => app.sendEncrypted(createMessage("ping", {}))).not.toThrow();
    } finally {
      await app.disconnect();
    }
  }, 20_000);
});
