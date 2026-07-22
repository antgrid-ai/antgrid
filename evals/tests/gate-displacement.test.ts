import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { setupPairFlowTestEnv, type TestEnv } from "../helpers/test-env";
import { RelayClient, PairAgentOfflineError } from "../helpers/relay-client";
import { createMessage } from "../../bridge/src/protocol";

function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

/**
 * Merge-gate item 7 (design §5.3, §12): v3 keeps the "one active phone per
 * machine" policy, enforced structurally at grant creation — a second phone's
 * pair-approval displaces the first phone's grant. The displaced phone gets a
 * `grant-revoked{reason:"PEER_REPLACED"}` NOTICE frame (relay/src/server.ts's
 * pair-approval handler), never a socket close (grants/routing errors leave
 * the socket open per the v3 error contract).
 */
describe("gate: displacement — second phone pairs, first is displaced", () => {
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

  async function pairFreshPhone(name: string): Promise<RelayClient> {
    const app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name });
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

  test("first phone gets grant-revoked{PEER_REPLACED} on a still-open socket; its sends then get NOT_AUTHORIZED", async () => {
    const phone1 = await pairFreshPhone("gate-displacement-1");
    try {
      await phone1.performE2EHandshake(env.agent.deviceId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });

      // Baseline: phone1's session is live before the second phone shows up.
      const baselineId = "gate-displacement-baseline";
      const baselineP = phone1.waitFor((m: any) => m.type === "response" && m.requestId === baselineId, 5_000);
      phone1.sendEncrypted(createMessage("request", { requestId: baselineId, method: "state.snapshot", params: { types: ["*"] } }));
      await baselineP;

      const revokedP = phone1.waitFor((m: any) => m.type === "grant-revoked", 10_000);

      const phone2 = await pairFreshPhone("gate-displacement-2");
      try {
        await phone2.performE2EHandshake(env.agent.deviceId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });

        const revoked = await revokedP;
        expect(revoked.peerDeviceId).toBe(env.agent.deviceId);
        expect(revoked.reason).toBe("PEER_REPLACED");

        // Socket-open law: grant/routing errors never close the socket.
        expect(await phone1.waitForClose(1_500)).toBe(false);

        // A routed send from the displaced phone now has no live grant behind
        // it — the relay answers NOT_AUTHORIZED, socket still open.
        const naError = phone1.waitFor((m: any) => m.type === "error" && m.code === "NOT_AUTHORIZED", 5_000);
        phone1.sendEncrypted(createMessage("ping", {}));
        const err = await naError;
        expect(err.code).toBe("NOT_AUTHORIZED");
        expect(await phone1.waitForClose(1_000)).toBe(false);

        // Meanwhile the NEW phone's own grant is fully functional.
        const postId = "gate-displacement-phone2-post";
        const postP = phone2.waitFor((m: any) => m.type === "response" && m.requestId === postId, 5_000);
        phone2.sendEncrypted(createMessage("request", { requestId: postId, method: "state.snapshot", params: { types: ["*"] } }));
        expect(((await postP) as any).ok).toBe(true);
      } finally {
        await phone2.disconnect();
      }
    } finally {
      await phone1.disconnect();
    }
  }, 40_000);
});
