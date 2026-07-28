import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { relaySlotId } from "antgrid-wire";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
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
describe("gate: wedge recovery", () => {
  let env: TestEnv;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
  });

  afterAll(async () => {
    await env?.teardown();
  });

  /**
   * Fresh, account-trusted connection: reuses `env.appIdentity` (already
   * registered with the fake account inventory — a never-registered identity
   * cannot be admitted), on its OWN per-machine relay slot so the relay
   * doesn't SUPERSEDED-close `env.app`'s socket — but the bridge's
   * single-active-phone takeover still tears down `env.app`'s own E2E session
   * once this fresh phone's client-hello is admitted (see `TestApp.connect`'s
   * docstring in `helpers/test-app.ts`); only the relay-level collision is
   * avoided here, not the bridge-level one. No pairing ceremony at all —
   * admission is relay same-account routing + bridge inventory trust, and by
   * this point the trusted-peers cache is already warm from `setupTestEnv`'s
   * own handshake.
   */
  async function freshPhone(): Promise<RelayClient> {
    const helloDeviceId = relaySlotId(env.appIdentity.deviceId, crypto.randomUUID());
    const app = await RelayClient.connectAndAuth(env.relay.url, {
      deviceType: "app",
      name: "gate-wedge",
      identity: env.appIdentity,
      deviceId: helloDeviceId,
      transcriptDeviceId: env.appIdentity.deviceId,
    });
    app.setPeerId(env.agentDeviceId);
    return app;
  }

  test("dropped first app:ready — the 2s retransmit still establishes", async () => {
    const app = await freshPhone();
    try {
      await app.performE2EHandshake(env.agentDeviceId, 8_000, {
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
    const app = await freshPhone();
    try {
      await app.performE2EHandshake(env.agentDeviceId, 8_000, {
        agentEd25519Pub: env.agent.ed25519Pubkey,
        dropEstablished: true,
      });
      expect(() => app.sendEncrypted(createMessage("ping", {}))).not.toThrow();
    } finally {
      await app.disconnect();
    }
  }, 15_000);

  test("noRetransmit + dropped app:ready times out, then a FRESH attempt recovers (no permanent wedge)", async () => {
    const app = await freshPhone();
    try {
      // Plain try/catch, not `expect(...).rejects.toThrow()`: the latter's
      // extra microtask/scheduling overhead around the rejection was enough
      // to reliably wedge the FOLLOWING fresh attempt in this exact scenario
      // (reproduced independently of spawnAgent/describe/setupTestEnv —
      // isolated to that specific matcher). Not a v3 behavior difference, just
      // a test-authoring pitfall; avoided here rather than chased further.
      let timedOut = false;
      try {
        await app.performE2EHandshake(env.agentDeviceId, 3_000, {
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
      await app.performE2EHandshake(env.agentDeviceId, 8_000, {
        agentEd25519Pub: env.agent.ed25519Pubkey,
      });
      expect(() => app.sendEncrypted(createMessage("ping", {}))).not.toThrow();
    } finally {
      await app.disconnect();
    }
  }, 20_000);
});
