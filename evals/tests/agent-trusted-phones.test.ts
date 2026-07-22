import { test, expect } from "bun:test";
import { generateKeyPairSync, type KeyObject } from "node:crypto";
import { setupPairFlowTestEnv, type TestEnv } from "../helpers/test-env";
import { RelayClient } from "../helpers/relay-client";
import { loadPairedPhones } from "../../bridge/src/paired-phones";
import { firstProjectStream } from "../support/stream";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Machine-level trust survives an agent restart (design §5.1 + §6.3). After the
 * agent restarts (new epoch supersedes its old relay connection), the relay-side
 * grant persists and the agent reloads its on-disk paired-phones trust list — so
 * the same phone resumes routing WITHOUT re-pairing: peer-offline → peer-online,
 * a fresh E2E handshake over the surviving grant, and project verbs flow again.
 * (v2 drove this via a pairCode reconnect; the control-plane pairCode window has
 * no eval open-hook in v3 — evals pair via the account-membership path.)
 */
function rawEdPubB64(pub: KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

async function pairAndAllow(
  env: TestEnv,
  accountKey: { pubB64: string; privateKey: KeyObject },
): Promise<RelayClient> {
  const app = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "eval-phone" });
  for (let i = 0; i < 50; i++) {
    try {
      const r = await app.pairWith(env.agent.deviceId, { timeoutMs: 8_000, accountKey });
      app.setPeerId(r.peerId);
      await app.performE2EHandshake(env.agent.deviceId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });
      return app;
    } catch {
      if (app.isClosed) await app.reconnectAndAuth(env.relay.url);
      await Bun.sleep(150);
    }
  }
  await app.disconnect();
  throw new Error("agent never became pairable in time");
}

async function fileRead(app: RelayClient, projectId: string): Promise<string> {
  await app.pullStateSnapshot();
  const streamId = await firstProjectStream(app, projectId, 10_000);
  app.sendOnStream(streamId, createMessage("file:read", { projectId, path: "README.md" }));
  const content = await app.waitForStreamAbType(streamId, "file:content", 8_000);
  return content.content ?? "";
}

test("trusted phone survives agent restart and resumes without re-pairing", async () => {
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);
  const env = await setupPairFlowTestEnv({ accountPeerKeys: [accountPubB64] });
  let app: RelayClient | null = null;
  try {
    app = await pairAndAllow(env, { pubB64: accountPubB64, privateKey: accountKp.privateKey });

    // Allow the firstProject so we can drive a verb as a liveness probe.
    const store = loadPairedPhones(env.abDir);
    store.allowProject(app.exportIdentity().publicKeyBase64, env.projectId);
    await Bun.sleep(400);
    expect(await fileRead(app, env.projectId)).toContain("Eval Test Project");

    // Restart the agent, then let the phone reconnect its socket under the SAME
    // identity and re-handshake — with NO pairWith() call. This resumes only
    // because the relay grant + the agent's on-disk trust survived the restart.
    const identity = app.exportIdentity();
    const deviceId = app.deviceId;
    const peerId = env.agent.deviceId;
    await env.restartAgent();
    await app.disconnect();

    const app2 = await RelayClient.connectAndAuth(env.relay.url, { deviceType: "app", name: "eval-phone-2", identity, deviceId });
    app = app2;
    app2.setPeerId(peerId);
    // Wait for the restarted agent to come back online over the surviving grant
    // (peer-online fires on the agent's re-hello), then handshake — no re-pair.
    await app2.waitForType("peer-online", 25_000);
    let handshook = false;
    for (let i = 0; i < 10; i++) {
      try {
        await app2.performE2EHandshake(peerId, 10_000, { agentEd25519Pub: env.agent.ed25519Pubkey });
        handshook = true;
        break;
      } catch {
        await Bun.sleep(300);
      }
    }
    expect(handshook).toBe(true);
    expect(await fileRead(app2, env.projectId)).toContain("Eval Test Project");
  } finally {
    await app?.disconnect();
    await env.teardown();
  }
}, 90_000);
