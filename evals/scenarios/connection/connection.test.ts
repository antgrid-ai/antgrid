import { describe, test, expect } from "bun:test";
import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { startRelay, allocatePort } from "../../helpers/harness";
import { setupPairFlowTestEnv, type TestEnv } from "../../helpers/test-env";
import { RelayClient } from "../../helpers/relay-client";

/**
 * v3 connection resilience. The v2 offline-queue behaviour is GONE (design §6.4):
 * a routed frame to an offline peer is rejected with `error{PEER_OFFLINE,
 * retryable:true}` and never queued — queued ciphertext could only ever be
 * undecryptable after the reconnect rekey, so the queue was deleted. The error
 * contract (design §3.3) keeps the socket open for every application-layer
 * failure (PEER_OFFLINE, NOT_AUTHORIZED, MESSAGE_RATE_LIMITED).
 */

function rawEdPubB64(pub: KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

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

describe("connection resilience (v3)", () => {
  test("routed send to an offline peer is rejected PEER_OFFLINE and never queued", async () => {
    const accountKp = generateKeyPairSync("ed25519");
    const accountPubB64 = rawEdPubB64(accountKp.publicKey);
    const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
    let app: RelayClient | null = null;
    try {
      // Pairing + a completed E2E handshake already prove routing works while the
      // agent is live (both required relayed round-trips).
      app = await pairApp(env, { pubB64: accountPubB64, privateKey: accountKp.privateKey });

      const offlineP = app.waitForType("peer-offline", 8_000);
      await env.agent.kill();
      await offlineP;

      // Each send to the now-offline agent must be REJECTED immediately, not
      // absorbed into a queue (the v2 behaviour). We repeat to show every send
      // bounces — a queue would have silently accepted them.
      for (let i = 0; i < 3; i++) {
        const errP = app.waitForType("error", 4_000);
        app!.sendMessage(env.agent.deviceId, "control", JSON.stringify({ type: "test", seq: i }));
        const err = await errP;
        expect(err.code).toBe("PEER_OFFLINE");
        expect(err.retryable).toBe(true);
      }
      // Application-layer failure — the phone's socket stays open.
      expect(app.isClosed).toBe(false);
    } finally {
      await app?.disconnect();
      await env.teardown();
    }
  }, 60_000);

  test("JSON control flood is rate-limited (MESSAGE_RATE_LIMITED), socket stays open", async () => {
    // A tiny per-connection JSON budget so a short burst trips the limiter.
    const relay = await startRelay({ port: allocatePort(), jsonRateLimitPerSec: 5, jsonRateLimitBurst: 5 });
    let app: RelayClient | null = null;
    try {
      app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app" });
      const limitedP = app.waitFor((m: any) => m.type === "error" && m.code === "MESSAGE_RATE_LIMITED", 5_000);
      // Flood well past the burst. Malformed pair-requests are fine: the rate
      // check precedes parsing, so the limiter trips before any pairing work.
      for (let i = 0; i < 60; i++) {
        app.sendRaw({ type: "pair-request", agentDeviceId: "nobody", nonce: String(i) });
      }
      const limited = await limitedP;
      expect(limited.code).toBe("MESSAGE_RATE_LIMITED");
      expect(limited.retryable).toBe(true);
      // Rate limiting drops the message but never closes the socket (design §3.3).
      expect(await app.waitForClose(500)).toBe(false);
    } finally {
      await app?.disconnect();
      relay.stop();
    }
  }, 20_000);

  test("unpaired routed send is rejected NOT_AUTHORIZED without close", async () => {
    const relay = await startRelay({ port: allocatePort() });
    let app: RelayClient | null = null;
    try {
      app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app" });
      const errP = app.waitForType("error", 5_000);
      // No grant links this phone to the target → routing is refused.
      app.sendMessage(crypto.randomUUID(), "control", "should-fail");
      const error = await errP;
      expect(error.code).toBe("NOT_AUTHORIZED");
      expect(error.retryable).toBe(false);
      // The rejection is application-layer, so the socket must remain open.
      expect(await app.waitForClose(500)).toBe(false);
    } finally {
      await app?.disconnect();
      relay.stop();
    }
  }, 15_000);
});
