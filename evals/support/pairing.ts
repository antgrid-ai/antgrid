import type { TestEnv } from "../helpers/test-env";
import { TestApp } from "../helpers/test-app";

/**
 * Block until a `pair-request` actually REACHES the agent, absorbing the spawn
 * race: the agent writes `api.port` before it finishes authenticating to the
 * relay, so an early pair-request is answered by the relay with a typed
 * `error{AGENT_OFFLINE, retryable}` (v3 keeps the socket open). A stranger probe
 * (no pairCode) that comes back UNKNOWN_PHONE / PAIRING_WINDOW_CLOSED proves the
 * agent is live and pairable; only AGENT_OFFLINE means "not yet". Lives outside
 * `evals/helpers/` because the harness is a frozen shared surface.
 */
export async function waitAgentPairable(env: TestEnv, attempts = 80): Promise<void> {
  for (let i = 0; i < attempts; i++) {
    const probe = await TestApp.connect(env);
    try {
      const r = await probe.tryPairRequest(env.agent.deviceId);
      if (r.paired || !/AGENT_OFFLINE/.test(r.reason)) return;
    } finally {
      await probe.disconnect();
    }
    await Bun.sleep(100);
  }
  throw new Error("agent never became pairable on the relay in time");
}
