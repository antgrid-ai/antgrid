import { test, expect } from "bun:test";
import { setupTestEnv } from "../helpers/harness";
import { firstProjectStream } from "../support/stream";
import { createMessage } from "../../bridge/src/protocol";

/**
 * v3 reconnect without re-pairing (design §5.1). Pairing is an authorization
 * FACT the relay holds (a grant keyed by agent + phone pubkey), not a connection
 * state. When the phone's socket drops and it reconnects under the SAME identity,
 * the grant still exists, so routing resumes immediately after a fresh E2E
 * handshake — no second pair-request, no QR. This replaces the v2 trusted-
 * reconnect-via-pairCode test (the control-plane pairCode window has no eval
 * open-hook in v3 — evals pair via the account-membership path, see setupTestEnv).
 */
test("phone reconnects under the same identity and routes without re-pairing", async () => {
  const env = await setupTestEnv({ fixtureName: "basic" });
  try {
    // Baseline: the grant + session route project traffic on the firstProject stream.
    const before = await firstProjectStream(env.app, env.projectId, 10_000);
    env.app.sendOnStream(before, createMessage("file:read", { projectId: env.projectId, path: "README.md" }));
    expect((await env.app.waitForStreamAbType(before, "file:content", 8_000)).path).toBe("README.md");

    // Drop the phone socket, then reconnect with the SAME phone identity. No
    // pairWith() call — the relay-side grant must carry routing across the drop.
    const peerId = env.agentDeviceId;
    const identity = env.app.exportIdentity();
    const deviceId = env.app.deviceId;
    await env.app.disconnect();

    const { RelayClient } = await import("../helpers/relay-client");
    const app2 = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "eval-phone-2", identity, deviceId });
    try {
      app2.setPeerId(peerId);
      // Fresh session over the surviving grant — succeeds ONLY because routing is
      // authorized without a new pair ceremony.
      await app2.performE2EHandshake(peerId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });
      await app2.pullStateSnapshot();

      const after = await firstProjectStream(app2, env.projectId, 10_000);
      app2.sendOnStream(after, createMessage("file:read", { projectId: env.projectId, path: "README.md" }));
      const content = await app2.waitForStreamAbType(after, "file:content", 8_000);
      expect(content.path).toBe("README.md");
      expect(content.content).toContain("Eval Test Project");
    } finally {
      await app2.disconnect();
    }
  } finally {
    await env.teardown();
  }
}, 60_000);
