import type { TestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/**
 * Block until the agent is actually live on the relay, absorbing the spawn
 * race: the agent writes `api.port` before it finishes authenticating, so an
 * early connect sees no peer. Under account trust a successful E2E handshake
 * IS the liveness proof — there is no ceremony left to probe with.
 *
 * Each probe attempt is NOT a harmless side effect on `env.app`. The relay
 * half is safe: `TestApp.connect`'s default slot keeps this probe's socket
 * distinct from `env.app`'s, so the relay never SUPERSEDED-closes it. But the
 * bridge's single-active-phone takeover (`bridge/src/relay-client.ts`, spec
 * 2026-07-24 §4.3) still fires on every successful attempt here, since it
 * sees a second same-account slot regardless of relay routing — it sends
 * `env.app` a sealed `session-takeover` and tears its E2E session down. A
 * single successful attempt is therefore enough to end `env.app`'s session;
 * a caller that still needs `env.app` afterwards must re-handshake it.
 */
export async function waitAgentReachable(env: TestEnv, attempts = 80): Promise<void> {
  for (let i = 0; i < attempts; i++) {
    try {
      const probe = await TestApp.connect(env);
      await probe.disconnect();
      return;
    } catch {
      await Bun.sleep(100);
    }
  }
  throw new Error("agent never became reachable on the relay in time");
}
