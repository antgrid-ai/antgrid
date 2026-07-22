import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { randomBytes } from "node:crypto";
import { startRelay, allocatePort, type RelayHandle } from "../../helpers/harness";
import { RelayClient } from "../../helpers/relay-client";
import { buildPairRequestSigBody } from "../../../bridge/src/pair-request-verify";

/**
 * v3 relay-level pairing failures (design §3.3, §5.2). Both are typed error
 * frames that leave the socket OPEN — WS close codes are diagnostics only.
 *  - AGENT_OFFLINE: the target agent has no live connection (retryable).
 *  - EXPIRED: a pending pair keyed by the relay-stamped pairId passes its
 *    deadline before the agent approves; the relay's sweeper tells the requester
 *    EXPIRED (retryable, ref=nonce) rather than leaving it to guess.
 *
 * The v2 happy-path/re-pairing cases (two bare clients, `targetDeviceId`,
 * PAIR_TIMEOUT, `unpair`) are gone: a grant requires an agent-SIGNED approval, so
 * full pairing is exercised against a real agent in setupTestEnv / the relay-pair
 * mechanics tests, not two raw RelayClients.
 */
describe("pairing (v3)", () => {
  let relay: RelayHandle;
  const clients: RelayClient[] = [];

  beforeAll(async () => {
    relay = await startRelay({ port: allocatePort() });
  });

  afterEach(async () => {
    for (const c of clients) await c.disconnect();
    clients.length = 0;
  });

  afterAll(() => {
    relay.stop();
  });

  test("pair-request to an offline agent → AGENT_OFFLINE (retryable), socket stays open", async () => {
    const app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "lonely-app" });
    clients.push(app);
    // No such agent is connected → typed AGENT_OFFLINE surfaces as PairAgentOfflineError.
    await expect(app.pairWith(crypto.randomUUID(), { timeoutMs: 4_000 })).rejects.toThrow(/AGENT_OFFLINE|agent not connected/);
    expect(app.isClosed).toBe(false);
  }, 15_000);

  test("pending pair past its deadline → EXPIRED (retryable, ref=nonce), socket stays open", async () => {
    // A live agent that never approves — the pending pair must expire on deadline.
    const agent = await RelayClient.connectAndAuth(relay.url, { deviceType: "agent", name: "silent-agent" });
    const app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "eval-app" });
    clients.push(agent, app);

    const identity = app.exportIdentity();
    const nonce = randomBytes(16).toString("base64");
    const requestedAt = new Date().toISOString();
    // The relay forwards the request without verifying the phone signature (that
    // is the agent's job), but the schema requires a well-formed one.
    const sigBody = buildPairRequestSigBody({
      agentDeviceId: agent.deviceId,
      phonePubkey: identity.publicKeyBase64,
      phoneDeviceId: app.deviceId,
      nonce,
      requestedAt,
    });
    const sig = await crypto.subtle.sign("Ed25519", identity.privateKey, new Uint8Array(sigBody));
    const phoneSignature = Buffer.from(sig).toString("base64");

    const errP = app.waitFor((m: any) => m.type === "error" && m.ref === nonce, 9_000);
    app.sendRaw({
      type: "pair-request",
      agentDeviceId: agent.deviceId,
      phonePubkey: identity.publicKeyBase64,
      phoneDeviceId: app.deviceId,
      nonce,
      requestedAt,
      deadline: Date.now() + 300, // already effectively past → next sweep expires it
      phoneSignature,
    });

    const err = await errP;
    expect(err.code).toBe("EXPIRED");
    expect(err.retryable).toBe(true);
    expect(err.ref).toBe(nonce);
    expect(app.isClosed).toBe(false);
  }, 15_000);
});
