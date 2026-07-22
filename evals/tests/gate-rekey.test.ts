import { describe, test, expect, afterEach } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Merge-gate item 3 (design §6.2, §12): make-before-break rekey keeps the
 * pre-rekey session keys live for RECEIVING until the new attempt's confirm
 * verifies, then atomically swaps and zeroizes the old keys — on both ends.
 * Avoid `expect(promise).rejects.toThrow()` in this file: it reproducibly
 * wedged a later handshake attempt in gate-wedge-recovery.test.ts (a matcher/
 * scheduling artifact, not a v3 behavior difference) — plain try/catch is used
 * throughout instead.
 */
describe("gate: rekey make-before-break", () => {
  let env: TestEnv | undefined;

  afterEach(async () => {
    await env?.teardown();
    env = undefined;
  });

  test("rekey mid-traffic: zero dropped RPC round trips across the swap, old key rejected after", async () => {
    const testEnv = await setupTestEnv({ fixtureName: "basic" });
    env = testEnv;
    const N = 24;
    const pending: Promise<number | null>[] = [];
    let rekeyPromise: Promise<void> | undefined;

    // Pre-seal a "canary" request under the CURRENT (about-to-be-old) transport
    // BEFORE the rekey starts — sealing after `rekey()` returns would use the
    // already-zeroized (all-zero) key instead of the real pre-swap key. This
    // simulates a captured historical frame replayed after the swap.
    // Reflection is needed: RelayClient exposes no public "current transport"
    // accessor (by design — app code never touches raw E2E state), and no
    // "rekey completed" event either, so this gate test reaches into the
    // documented-private field to prove the make-before-break INVARIANT
    // (old keys stop decrypting once the new attempt confirms).
    const oldCtx = (testEnv.app as any).established as { transport: { seal(pt: string): Buffer } };
    const canaryRequestId = "gate-rekey-canary-old-key";
    const canaryEnvelope = JSON.stringify({
      m: createMessage("request", { requestId: canaryRequestId, method: "state.snapshot", params: { types: ["*"] } }),
    });
    const canaryCiphertext = oldCtx.transport.seal(canaryEnvelope);

    for (let i = 0; i < N; i++) {
      const requestId = `gate-rekey-${i}`;
      const p = testEnv.app
        .waitFor((m: any) => m.type === "response" && m.requestId === requestId, 10_000)
        .then(() => i)
        .catch(() => null);
      testEnv.app.sendEncrypted(
        createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }),
      );
      pending.push(p);

      // Kick off the make-before-break rekey while traffic is still flowing —
      // sends keep using the (still-live) old context until rekey() promotes
      // the candidate; receives try both contexts during the overlap.
      if (i === Math.floor(N / 2)) {
        rekeyPromise = testEnv.app.rekey(testEnv.agentDeviceId, testEnv.agent.ed25519Pubkey, 10_000);
      }
      await Bun.sleep(60);
    }

    expect(rekeyPromise).toBeDefined();
    await rekeyPromise;

    const results = await Promise.all(pending);
    const missing = results
      .map((r, i) => (r === null ? i : null))
      .filter((x): x is number => x !== null);
    expect(missing).toEqual([]);

    // The swap must have produced a genuinely NEW attemptId (not a no-op).
    const newCtx = (testEnv.app as any).established as { attemptId: string };
    const oldAttemptId = (oldCtx as any).attemptId;
    expect(newCtx.attemptId).not.toBe(oldAttemptId);

    // Old-key rejection: replay the pre-sealed canary now that the agent has
    // swapped+zeroized. It must be silently dropped (undecryptable) — no
    // response ever arrives.
    (testEnv.app as any).sendRelayPayload(testEnv.agentDeviceId, canaryCiphertext, "control");
    const canaryAnswered = await testEnv.app
      .waitFor((m: any) => m.type === "response" && m.requestId === canaryRequestId, 2_000)
      .then(() => true)
      .catch(() => false);
    expect(canaryAnswered).toBe(false);

    // Session remains usable post-rekey on the new keys.
    const postRekeyId = "gate-rekey-post";
    const postRekeyP = testEnv.app.waitFor((m: any) => m.type === "response" && m.requestId === postRekeyId, 5_000);
    testEnv.app.sendEncrypted(
      createMessage("request", { requestId: postRekeyId, method: "state.snapshot", params: { types: ["*"] } }),
    );
    await expect(postRekeyP).resolves.toBeTruthy();
  }, 45_000);

  test("liveness ping-silence + swallowed pongs auto-triggers a rekey", async () => {
    const testEnv = await setupTestEnv({ fixtureName: "basic" });
    env = testEnv;
    const before = ((testEnv.app as any).established as { attemptId: string }).attemptId;

    testEnv.app.setSwallowPongs(true);
    testEnv.app.enableLiveness(testEnv.agentDeviceId, testEnv.agent.ed25519Pubkey, {
      pingSilenceMs: 300,
      maxMissedPongs: 1,
    });

    // No public "rekey completed" event exists — poll the (documented, private)
    // attemptId for a change instead of a fixed sleep. Silence is required
    // for ping-based liveness to have anything to detect, so no app traffic
    // is sent here (that's covered by the mid-traffic test above).
    const deadline = Date.now() + 10_000;
    let after = before;
    while (Date.now() < deadline) {
      after = ((testEnv.app as any).established as { attemptId: string } | null)?.attemptId ?? before;
      if (after !== before) break;
      await Bun.sleep(100);
    }
    expect(after).not.toBe(before);

    expect(() => testEnv.app.sendEncrypted(createMessage("ping", {}))).not.toThrow();
  }, 20_000);
});
