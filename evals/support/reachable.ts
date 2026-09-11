import type { TestEnv } from "../helpers/harness";
import { TestApp } from "../helpers/test-app";

/**
 * Block until the agent is actually live on the relay, absorbing the spawn
 * race: the agent writes `api.port` before it finishes authenticating, so an
 * early connect sees no peer. Under account trust a successful E2E handshake
 * IS the liveness proof — there is no ceremony left to probe with.
 *
 * A probe attempt is additive on both layers: `TestApp.connect`'s default slot
 * keeps this socket distinct from `env.app`'s, so the relay never
 * SUPERSEDED-closes it, and the bridge admits the probe's session ALONGSIDE
 * `env.app`'s rather than displacing it (`bridge/src/relay-client.ts` keeps one
 * session per app device). `env.app` needs no re-handshake afterwards. The only
 * residue is that each successful attempt leaves an unreachable session on the
 * bridge until its TTL reap.
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
