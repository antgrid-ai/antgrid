import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  generateAppIdentity,
  generateEvalAuth,
  handshakeWithoutPairing,
  RELAY_INTERNAL_SECRET,
  spawnAgent,
  startFakeLicenseApi,
  type AgentHandle,
  type FakeLicenseApi,
} from "../helpers/harness";
import { startRestartableRelay } from "../helpers/restartable-relay";
import { RelayClient } from "../helpers/relay-client";
import { createTestProject } from "../helpers/fixtures";
import { createMessage } from "../../bridge/src/protocol";

/**
 * Merge-gate item 5 (design §5.1, §5.4, §6.4, §12): a relay restart wipes all
 * in-memory connection/grant state; recovery is the AGENT'S OWN reconnect
 * (real bridge backoff, unattended) landing a fresh `hello`, followed by the
 * phone re-establishing its E2E session with NO pairing at all — admission is
 * relay same-account routing (`mayRoute`) + the bridge's account-inventory
 * trust source (`TrustedPeersProvider`), both of which survive a relay
 * restart unattended (the phone's identity was never un-registered).
 *
 * HELPER GAP 1: `harness.ts`'s `startRelay().stop()` calls Bun's
 * `server.stop()` with no `closeActiveConnections` argument, which defaults to
 * a GRACEFUL stop — it stops accepting new connections but leaves existing
 * WebSockets (e.g. the agent's) open indefinitely. The agent then has nothing
 * to reconnect FROM (confirmed empirically: using `startRelay`/`env.relay` for
 * this test, the agent never redials within 30s). So the restart goes through
 * `startRestartableRelay` (helpers/restartable-relay.ts), which force-closes
 * each live `ws` and brings the relay back on a FRESH OS-assigned port behind
 * a stable-port TcpForwarder — the agent keeps dialing the forwarder's stable
 * URL unattended, and no same-port rebind means no Windows EADDRINUSE window.
 *
 * HELPER GAP 2: `evals/helpers/relay-client.ts`'s fake phone has NO built-in
 * post-close backoff/auto-reconnect — that logic exists only in the real app
 * (`app/lib/relay/...RelayConnectionManager`), not in this TS test double. A
 * literal "zero nudge on either side" gate test therefore isn't achievable
 * without editing relay-client.ts. This test verifies the AGENT side fully
 * unattended (only waits, no manual reconnect calls touch the agent process)
 * and the PHONE side with a clearly-marked, explicit reconnect+re-handshake
 * standing in for what the real app's reconnect logic does automatically.
 * The v3 behavior actually under test — grant-free recovery via account
 * trust, no re-pair needed — is fully exercised either way.
 */

/** Bound to an OS-assigned port (0) so each (re)start avoids the same-port
 *  EADDRINUSE rebind window; the stable client-facing address is the
 *  TcpForwarder's, wired up by `startRestartableRelay`. */
const RELAY_CONFIG = {
  port: 0,
  maxConnections: 100,
  rateLimitConnPerIp: 10,
  rateLimitMsgPerSec: 100,
  jsonRateLimitPerSec: 100,
  jsonRateLimitBurst: 200,
  clockSkewMs: 120_000,
  replayTtlMs: 300_000,
  pingIntervalMs: 30_000,
  pongTimeoutMs: 10_000,
  logLevel: "error" as const,
  licenseApiUrl: "http://license-api.eval",
  relayInternalSecret: RELAY_INTERNAL_SECRET,
  licenseCacheMaxEntries: 1000,
};

const RELAY_DEPS = {
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
};

test("relay restart: agent reconnects unattended; account trust recovers with no re-pair; session resumes", async () => {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-gate-restart-"));
  const appIdentity = await generateAppIdentity();

  const { startServer } = await import("../../relay/src/server");
  const relay = startRestartableRelay(() => startServer(RELAY_CONFIG, RELAY_DEPS));
  const relayWsUrl = relay.url; // stable forwarder URL, survives restarts
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({
    accountDevices: [{ deviceId: appIdentity.deviceId, ed25519Pub: appIdentity.publicKeyBase64 }],
  });
  const auth = generateEvalAuth();
  const project = createTestProject("basic", { "__RELAY_URL__": relayWsUrl.replace(/\/ws$/, "") });

  let agent: AgentHandle | undefined;
  let app: RelayClient | undefined;
  try {
    agent = await spawnAgent({
      relayUrl: relayWsUrl,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const deviceUuid = auth.deviceUuid;

    app = await RelayClient.connectAndAuth(relayWsUrl, {
      deviceType: "app",
      name: "gate-restart-app",
      identity: appIdentity,
      deviceId: appIdentity.deviceId,
    });
    // Never a pair-request: admission is relay same-account routing + bridge
    // inventory trust (Tasks 1, 5-6).
    await handshakeWithoutPairing(app, deviceUuid, auth.ed25519Pub);

    // Baseline traffic before the restart.
    const baselineId = "gate-restart-baseline";
    const baselineP = app.waitFor((m: any) => m.type === "response" && m.requestId === baselineId, 5_000);
    app.sendEncrypted(createMessage("request", { requestId: baselineId, method: "state.snapshot", params: { types: ["*"] } }));
    await baselineP;

    // Restart the relay on a FRESH port behind the same stable forwarder URL.
    // Neither the agent process nor `app` is touched here — the agent's own
    // bridge process notices the severed socket and redials the (unchanged)
    // forwarder URL on its jittered backoff entirely on its own.
    relay.restart();

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
    await app.reconnectAndAuth(relayWsUrl);
    await handshakeWithoutPairing(app, deviceUuid, auth.ed25519Pub);

    const postId = "gate-restart-post";
    const postP = app.waitFor((m: any) => m.type === "response" && m.requestId === postId, 5_000);
    app.sendEncrypted(createMessage("request", { requestId: postId, method: "state.snapshot", params: { types: ["*"] } }));
    const postRes = await postP;
    expect((postRes as any).ok).toBe(true);
  } finally {
    await app?.disconnect();
    await agent?.kill();
    relay.stop();
    licenseApi.stop();
    project.cleanup();
    try { rmSync(abDir, { recursive: true, force: true }); } catch {}
  }
}, 60_000);
