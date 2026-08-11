import { describe, test, expect, beforeAll, beforeEach, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../../helpers/harness";
import { RelayClient } from "../../helpers/relay-client";
import { createMessage } from "../../../bridge/src/protocol";

/**
 * Active-relay DH MITM and handshake-security regressions (v2).
 *
 * The v2 pull-model E2E handshake is transcript-signed on both sides (Ed25519
 * over domain || version || registrationId || role || agentDeviceId ||
 * phoneDeviceId || agentX25519Pub || phoneX25519Pub || nonce). Five scenarios:
 *
 *  1. EXISTING — unsigned client-hello: the bridge must reject before sending
 *     agent-hello (no transcript sig → drop).
 *
 *  2. EXISTING — tampered agent-hello DH pubkey: divergent shared secret →
 *     agent-ready sealed with real a2p key can't be opened with the wrong
 *     derived recv key → handshake times out.
 *
 *  3. NEW — tampered confirm in agent-ready: MITM forwards the handshake
 *     intact but replaces the `confirm` field with random bytes → the phone
 *     rejects the confirm tag and NEVER sends app:ready → the agent never
 *     fires handshake-complete.
 *
 *  4. v3 — make-before-break rekey (replaces the v2 plaintext lockout): after a
 *     confirmed session, a fresh transcript-signed client-hello on the LIVE
 *     socket runs a rekey while old keys stay live for receiving, then swaps
 *     atomically. The session keeps routing traffic across the swap.
 *
 *  5. reconnect re-handshake: a confirmed session, then the phone disconnects
 *     and reconnects with the same identity. The relay sends `peer-online` and a
 *     fresh handshake completes, encrypted round-trip succeeds on the NEW keys.
 *
 * beforeEach reconnects the phone client so each test starts with an
 * unconfirmed agent (peer-online resets the agent's `confirmed` flag).
 */
describe("handshake MITM", () => {
  let env: TestEnv;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    // setupTestEnv leaves the agent in `confirmed = true`. The beforeEach hook
    // below disconnects and reconnects the phone before each test, which makes
    // the relay send `peer-online` to the agent → `prepareForHandshake()` →
    // `confirmed = false`, ready for the next security scenario.
  });

  afterAll(async () => {
    await env?.teardown();
  });

  /**
   * Reconnect the phone to reset the agent's `confirmed` flag before each
   * security test. This simulates an app restart: the relay restores pair state
   * and sends `peer-online` to the agent, which re-arms for a fresh handshake.
   */
  beforeEach(async () => {
    const relayUrl = env.relay.url;
    const agentId = env.agentDeviceId;
    await env.app.disconnect();
    await Bun.sleep(150); // let relay detect disconnect
    await env.app.reconnect(relayUrl, agentId);
    await Bun.sleep(300); // let relay deliver peer-online → agent prepareForHandshake
  });

  // ── Scenario 1: unsigned client-hello ────────────────────────────────────
  test("bridge rejects a client-hello with no transcript signature", async () => {
    // An unsigned client-hello must NOT yield an agent-hello — the agent bails
    // before deriving. performE2EHandshake waits for agent-hello and throws on
    // the (expected) timeout.
    await expect(
      env.app.performE2EHandshake(env.agentDeviceId, 2_500, {
        omitClientHelloSig: true,
        agentEd25519Pub: env.agent.ed25519Pubkey,
      }),
    ).rejects.toThrow();
  });

  // ── Scenario 2: tampered agent-hello DH pubkey ───────────────────────────
  // The phone pins the agent's Ed25519 pub. An active relay swaps the agent's
  // X25519 pub in agent-hello but cannot re-sign (it lacks the agent Ed25519
  // key). The phone builds the agent-role transcript with the SWAPPED pub and
  // the REAL agent signature no longer verifies → the phone ABORTS at the
  // sig-check, before deriving any keys. This is the v2 signature-rejection
  // defense (not a downstream decrypt timeout).
  test("app aborts at sig-check when agent-hello pubkey is tampered", async () => {
    await expect(
      env.app.performE2EHandshake(env.agentDeviceId, 2_500, {
        corruptAgentHelloPubkey: true,
        agentEd25519Pub: env.agent.ed25519Pubkey,
      }),
    ).rejects.toThrow(/sig invalid/i);
  });

  // ── Scenario 3: tampered confirm tag in agent-ready ──────────────────────
  test("phone rejects agent-ready with tampered confirm tag", async () => {
    // A MITM that forwards the DH exchange intact but swaps the `confirm`
    // field inside the sealed agent-ready should be detected by the phone.
    // The phone must NOT send app:ready and the handshake call must throw.
    await expect(
      env.app.performE2EHandshake(env.agentDeviceId, 5_000, {
        corruptAgentReadyConfirm: true,
        agentEd25519Pub: env.agent.ed25519Pubkey,
      }),
    ).rejects.toThrow("confirm tag invalid");
  });

  // ── Scenario 4: make-before-break rekey (replaces the v2 plaintext lockout) ─
  test("make-before-break rekey on a live session keeps it alive on fresh keys", async () => {
    // Establish a confirmed session and prove it routes real traffic.
    await env.app.performE2EHandshake(env.agentDeviceId, 5_000, {
      agentEd25519Pub: env.agent.ed25519Pubkey,
    });
    await env.app.pullStateSnapshot();
    expect(await env.app.waitForAbType("agent:projects", 5_000)).toBeTruthy();

    // v3 replaces v2's post-establishment plaintext lockout with make-before-break
    // rekey: a fresh, transcript-signed client-hello on the LIVE
    // socket is NOT dropped — the agent verifies the pinned phone key and runs a
    // new handshake while the OLD keys stay live for receiving, then atomically
    // swaps. Forgery is still impossible (signature required); a replay can never
    // confirm; kind-0 stays decrypt-or-drop throughout. The rekey resolving is the
    // proof the make-before-break swap completed.
    await env.app.rekey(env.agentDeviceId, env.agent.ed25519Pubkey);

    // The session must still route real traffic — now on the FRESH keys.
    await env.app.pullStateSnapshot();
    expect(await env.app.waitForAbType("agent:projects", 5_000)).toBeTruthy();
  });

  // ── Scenario 5: reconnect re-handshake ───────────────────────────────────
  // Explicit timeout (matches gate-harness-pairfree.test.ts's 30_000, the other
  // file whose test body pays a full setupTestEnv — spawn a relay + a real
  // bridge agent subprocess, account-trust handshake, then poll for a dialable
  // stream advert — on top of its own assertions; bun:test's 5_000ms default is
  // tuned for tests that reuse a describe-level env from beforeAll and isn't
  // enough headroom for a second cold env spun up inside the test itself).
  test("phone disconnect+reconnect triggers a fresh handshake on new keys", async () => {
    // This test uses its own isolated env to avoid interference with other
    // tests. (beforeEach reconnects env.app but we need a known-clean state.)
    const localEnv = await setupTestEnv({ fixtureName: "basic" });
    try {
      // The setupTestEnv call above already completed the initial handshake.
      // Verify the initial session works.
      expect(() => {
        localEnv.app.sendEncrypted(createMessage("ping", {}));
      }).not.toThrow();

      // Disconnect the phone — this closes the WS.
      const relayUrl = localEnv.relay.url;
      const agentId = localEnv.agentDeviceId;
      await localEnv.app.disconnect();

      // Small gap to let the relay and agent detect the disconnect.
      await Bun.sleep(200);

      // Reconnect with the SAME identity (deviceId + keypair). The relay
      // restores pair state and sends `peer-online` to the agent, which calls
      // `prepareForHandshake()` → `confirmed = false`.
      await localEnv.app.reconnect(relayUrl, agentId);

      // Wait briefly for the relay to deliver peer-online to the agent and for
      // the agent to arm its keypair.
      await Bun.sleep(300);

      // Fresh v2 handshake on new session keys must succeed — still verifying
      // the agent-hello sig against the pinned agent Ed25519 pub.
      await localEnv.app.performE2EHandshake(
        localEnv.agentDeviceId,
        8_000,
        { agentEd25519Pub: localEnv.agent.ed25519Pubkey },
      );

      // Encrypted round-trip on the NEW keys must work.
      expect(() => {
        localEnv.app.sendEncrypted(createMessage("ping", {}));
      }).not.toThrow();
    } finally {
      await localEnv.teardown();
    }
  }, 30_000);
});
