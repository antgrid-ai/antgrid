import { test, expect } from "bun:test";
import { setupTestEnv, handshakeWithoutPairing } from "../helpers/harness";
import type { RelayClient } from "../helpers/relay-client";
import { firstProjectStream } from "../support/stream";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Account-level trust survives an agent restart (design §5.1 + §6.3). After the
 * agent restarts (new epoch supersedes its old relay connection), the same phone
 * resumes routing WITHOUT re-pairing: peer-offline → peer-online, a fresh E2E
 * handshake over the surviving account-trust admission, and project verbs flow
 * again — because both halves of the answer are on disk in the abDir the restart
 * reuses: account-trust admission and the machine's mobile-access switch.
 */
async function fileRead(app: RelayClient, projectId: string): Promise<string> {
  await app.pullStateSnapshot();
  const streamId = await firstProjectStream(app, projectId, 10_000);
  app.sendOnStream(streamId, createMessage("file:read", { projectId, path: "README.md" }));
  const content = await app.waitForStreamAbType(streamId, "file:content", 8_000);
  return content.content ?? "";
}

test("trusted phone survives agent restart and resumes without re-pairing", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    // Baseline: setupTestEnv left the machine mobile-enabled — use firstProject
    // as a liveness probe.
    expect(await fileRead(env.app, env.projectId)).toContain("Eval Test Project");

    // Restart the agent, then let the phone reconnect its socket under the SAME
    // identity and re-handshake — with NO pairing at all. This resumes only
    // because the agent's on-disk trust (account-inventory admission) survived
    // the restart.
    await env.restartAgent();
    await env.app.disconnect();
    await env.app.reconnectAndAuth(env.relay.url);
    env.app.setPeerId(env.agentDeviceId);

    // Wait for the restarted agent to come back online (peer-online fires on
    // the agent's re-hello), then handshake — no re-pair. The retry loop
    // already lives in the helper, so a bare await is enough: it throws (and
    // fails the test) on exhaustion.
    await env.app.waitForType("peer-online", 25_000);
    await handshakeWithoutPairing(env.app, env.agentDeviceId, env.agent.ed25519Pubkey, {
      attempts: 10,
      perAttemptTimeoutMs: 10_000,
      gapMs: 300,
    });
    expect(await fileRead(env.app, env.projectId)).toContain("Eval Test Project");
  } finally {
    await env.teardown();
  }
}, 90_000);
