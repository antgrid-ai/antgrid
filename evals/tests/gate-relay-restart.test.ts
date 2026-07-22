import { test, expect } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  allocatePort,
  generateEvalAuth,
  spawnAgent,
  startFakeLicenseApi,
  TEST_LICENSE_TOKEN,
  type AgentHandle,
  type FakeLicenseApi,
} from "../helpers/harness";
import { RelayClient } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Merge-gate item 5 (design §5.1, §5.4, §6.4, §12): a relay restart wipes all
 * in-memory connection/grant state; recovery is the AGENT'S OWN reconnect
 * (real bridge backoff, unattended) landing a fresh `hello`, followed by the
 * agent-side TRUSTED-RECONNECT pair path (the phone pubkey is already in
 * `paired-phones.json`, so `pair-request` needs no pairCode/accountKey this
 * time — `relay-client.ts`'s `handleInboundPairRequest` admits on
 * `pairedPhones.has(phonePubkey)` alone).
 *
 * HELPER GAP 1: `harness.ts`'s `startRelay().stop()` calls Bun's
 * `server.stop()` with no `closeActiveConnections` argument, which defaults to
 * a GRACEFUL stop — it stops accepting new connections but leaves existing
 * WebSockets (e.g. the agent's) open indefinitely. The agent then has nothing
 * to reconnect FROM (confirmed empirically: using `startRelay`/`env.relay` for
 * this test, the agent never redials within 30s). `relay/src/server.ts`'s
 * `RelayServer.server` (the raw Bun server) is exposed publicly, so this test
 * calls `startServer` directly (bypassing the harness.ts wrapper, which is
 * read-only this phase) and force-closes with `server.server.stop(true)` to
 * get an actual severed connection.
 *
 * HELPER GAP 2: `evals/helpers/relay-client.ts`'s fake phone has NO built-in
 * post-close backoff/auto-reconnect — that logic exists only in the real app
 * (`app/lib/relay/...RelayConnectionManager`/`PairingService`), not in this TS
 * test double. A literal "zero nudge on either side" gate test therefore isn't
 * achievable without editing relay-client.ts. This test verifies the AGENT
 * side fully unattended (only waits, no manual reconnect calls touch the
 * agent process) and the PHONE side with a clearly-marked, explicit
 * reconnect+re-pair+re-handshake standing in for what the real app's
 * reconnect logic does automatically. The v3 behavior actually under test —
 * grant recovery via the trusted-reconnect path, no fresh pairCode/accountKey
 * needed — is fully exercised either way.
 */

function rawEdPubB64(pub: import("node:crypto").KeyObject): string {
  const der = pub.export({ format: "der", type: "spki" });
  return Buffer.from(der.subarray(der.length - 32)).toString("base64");
}

async function startForceStoppableRelay(port: number) {
  const { startServer } = await import("../../relay/src/server");
  const server = startServer(
    {
      port,
      maxConnections: 100,
      rateLimitConnPerIp: 10,
      pairRequestTimeoutMs: 15_000,
      pairRateLimitPerIp: 20,
      rateLimitMsgPerSec: 100,
      jsonRateLimitPerSec: 100,
      jsonRateLimitBurst: 200,
      clockSkewMs: 120_000,
      replayTtlMs: 300_000,
      staleGrantDays: 30,
      pingIntervalMs: 30_000,
      pongTimeoutMs: 10_000,
      logLevel: "error",
      licenseApiUrl: "http://license-api.eval",
      relayInternalSecret: "x".repeat(16),
      licenseCacheMaxEntries: 1000,
    },
    {
      licenseGate: {
        async verify(token: string, deviceId: string, _publicKeyBase64: string) {
          if (!token) return { ok: false as const, code: "LICENSE_INVALID" as const };
          return {
            ok: true as const,
            entry: { jti: `eval-jti-${deviceId}`, deviceId, userId: "eval-user", tier: "pro" as const, sessionLimit: 100, pk: _publicKeyBase64, revoked: false },
          };
        },
        async verifyAppToken(token: string) {
          if (!token) return { ok: false as const, code: "LICENSE_INVALID" as const };
          return {
            ok: true as const,
            entry: { jti: "eval-jti-app", deviceId: "app-eval-user", userId: "eval-user", tier: "pro" as const, sessionLimit: 100, pk: "eval-fake-app-pk", revoked: false },
          };
        },
      },
    },
  );
  return {
    url: `ws://localhost:${port}/ws`,
    connectionCount: () => server.connections.getConnectionCount(),
    /** Force-closes live sockets (unlike harness.ts's graceful RelayHandle.stop(),
     *  which leaves existing WebSockets open — confirmed empirically: the agent
     *  never redialed within 30s against a gracefully-stopped harness.ts relay).
     *  Explicitly closing each live connection's raw `ws` is what actually severs
     *  it; `server.server.stop(true)` alone was NOT sufficient in practice. */
    forceStop: () => {
      for (const c of server.connections.listConnections()) {
        const conn = server.connections.getByDeviceId(c.deviceId);
        try { conn?.ws.close(); } catch { /* already closing */ }
      }
      server.stop();
      server.server.stop(true);
    },
  };
}

test("relay restart: agent reconnects unattended; grant recovers via trusted reconnect; session resumes", async () => {
  const port = allocatePort();
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-restart-"));
  const accountKp = generateKeyPairSync("ed25519");
  const accountPubB64 = rawEdPubB64(accountKp.publicKey);

  let relay = await startForceStoppableRelay(port);
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({ accountPeerKeys: [accountPubB64] });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", { "__RELAY_URL__": `ws://localhost:${port}` });

  let agent: AgentHandle | undefined;
  let app: RelayClient | undefined;
  try {
    agent = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const deviceUuid = auth.deviceUuid;

    app = await RelayClient.connectAndAuth(relay.url, { deviceType: "app", name: "gate-restart-app", licenseToken: TEST_LICENSE_TOKEN });
    for (let i = 0; i < 30; i++) {
      try {
        const r = await app.pairWith(deviceUuid, {
          timeoutMs: 8_000,
          accountKey: { pubB64: accountPubB64, privateKey: accountKp.privateKey },
        });
        app.setPeerId(r.peerId);
        break;
      } catch {
        await Bun.sleep(200);
      }
    }
    await app.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub: auth.ed25519Pub });

    // Baseline traffic before the restart.
    const baselineId = "gate-restart-baseline";
    const baselineP = app.waitFor((m: any) => m.type === "response" && m.requestId === baselineId, 5_000);
    app.sendEncrypted(createMessage("request", { requestId: baselineId, method: "state.snapshot", params: { types: ["*"] } }));
    await baselineP;

    relay.forceStop();

    // Restart the relay ON THE SAME PORT. Neither the agent process nor
    // `app` is touched here — the agent's own bridge process notices the
    // severed socket and redials on its jittered backoff entirely on its own.
    relay = await startForceStoppableRelay(port);

    // Agent side, fully unattended: poll (no event exposed for "an agent
    // reconnected") until the restarted relay sees a live connection.
    const deadline = Date.now() + 30_000;
    let agentBack = false;
    while (Date.now() < deadline) {
      if (relay.connectionCount() >= 1) {
        agentBack = true;
        break;
      }
      await Bun.sleep(200);
    }
    expect(agentBack).toBe(true);

    // Phone side (HELPER GAP 2 above): a deliberate, explicit stand-in for
    // the app's own reconnect logic, not a silent nudge.
    await app.reconnectAndAuth(relay.url);
    const pairResult = await app.pairWith(deviceUuid, { timeoutMs: 10_000 });
    expect(pairResult.peerId).toBe(deviceUuid); // trusted reconnect: no pairCode/accountKey needed
    app.setPeerId(pairResult.peerId);
    await app.performE2EHandshake(deviceUuid, 10_000, { agentEd25519Pub: auth.ed25519Pub });

    const postId = "gate-restart-post";
    const postP = app.waitFor((m: any) => m.type === "response" && m.requestId === postId, 5_000);
    app.sendEncrypted(createMessage("request", { requestId: postId, method: "state.snapshot", params: { types: ["*"] } }));
    const postRes = await postP;
    expect((postRes as any).ok).toBe(true);
  } finally {
    await app?.disconnect();
    await agent?.kill();
    relay.forceStop();
    licenseApi.stop();
    project.cleanup();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  }
}, 60_000);
