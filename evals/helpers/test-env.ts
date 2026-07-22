import { createHmac } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  allocatePort,
  generateEvalAuth,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  type AgentHandle,
  type EvalAuth,
  type FakeLicenseApi,
  type RelayHandle,
} from "./harness";
import { computeProjectId } from "../../bridge/src/project-id";
import { createTestProject, type TestProject } from "./fixtures";
import { LocalTestClient } from "./local-client";

/**
 * Env shape used by the new pair-flow E2E suite (Tasks 28-33). Boots a
 * relay + agent (NO auto-pair), exposes the agent's identity bits, and
 * provides hooks for opening the pairing window, killing/restarting the
 * agent, revoking via the relay's internal route, and connecting extra
 * local-WS clients.
 */
export interface TestEnv {
  relay: RelayHandle;
  agent: TestEnvAgent;
  licenseApi: TestEnvLicenseApi;
  abDir: string;
  projectId: string;
  /** Underlying project on disk (so restartAgent reuses cwd). */
  project: TestProject;
  /** Restart the agent reusing the same projectId + abDir. */
  restartAgent(): Promise<void>;
  /** Connect an additional local-WS client to the agent's local listener. */
  connectAdditionalClient(): Promise<LocalTestClient>;
  teardown(): Promise<void>;
}

export interface TestEnvAgent {
  /** Bare machine `deviceUuid` — what `pair-request` targets in v3 (one machine
   *  socket; compound `deviceUuid.projectId` registration ids are gone). */
  deviceId: string;
  /** @deprecated Collapsed into `deviceId` — both are now the bare deviceUuid.
   *  Kept as an equal alias so existing call sites keep compiling. */
  rawDeviceId: string;
  /** Agent's stable Ed25519 pubkey, base64. */
  ed25519Pubkey: string;
  /** Open the pairing window via the agent's ANTGRID_EVAL_TEST=1 hook. */
  openPairingWindow(opts?: { ttlMs?: number }): Promise<string>;
  /** SIGTERM the agent and await exit. */
  kill(): Promise<void>;
}

export interface TestEnvLicenseApi {
  /** POST /internal/revoke on the relay (HMAC-signed). */
  revokeDevice(deviceId: string): Promise<void>;
}

const RELAY_INTERNAL_SECRET = "x".repeat(16);

interface InternalAgentSlot {
  handle: AgentHandle;
  api: { port: number; host: string };
}

async function readAgentApiPort(abDir: string, timeoutMs = 10_000): Promise<number> {
  const portFile = join(abDir, "api.port");
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(portFile)) {
      const raw = readFileSync(portFile, "utf8").trim();
      const port = Number(raw);
      if (Number.isFinite(port) && port > 0) return port;
    }
    await Bun.sleep(50);
  }
  throw new Error("Agent api.port file did not appear");
}

/**
 * Boot a relay + agent for pair-flow E2E. The agent process is launched
 * with `ANTGRID_EVAL_TEST=1` so the test-only `/test/open-pairing-window`
 * route on the agent's local HTTP API is reachable.
 *
 * Unlike `setupTestEnv`, this does NOT pair an app — tests drive the
 * pair flow themselves via `TestApp`. The `auth` (device keypair + OAuth
 * client) is generated once and reused across `restartAgent()` so the agent's
 * relay identity and on-disk paired-phones.json stay stable across restarts.
 */
export async function setupPairFlowTestEnv(opts: {
  fixtureName?: string;
  replacements?: Record<string, string>;
  /** Seed the fake license API's account peer-key set. A phone presenting one
   *  of these keys (with a valid membership sig) is admitted on the control
   *  plane WITHOUT a pairCode — the QR-less same-account auto-pair path. The
   *  control-plane registration has no test-only pairing-window hook (that hook
   *  is per-project, on the AgentCore), so account-membership is how an eval
   *  pairs a phone against the bare deviceUuid. */
  accountPeerKeys?: string[];
} = {}): Promise<TestEnv> {
  const fixtureName = opts.fixtureName ?? "basic";
  const relayPort = allocatePort();
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-pair-eval-"));
  const relay = await startRelay({ port: relayPort, pairRequestTimeoutMs: 15_000 });
  const licenseApi: FakeLicenseApi = startFakeLicenseApi({ accountPeerKeys: opts.accountPeerKeys });
  const auth: EvalAuth = generateEvalAuth();

  const project = createTestProject(fixtureName, {
    "__RELAY_URL__": `ws://localhost:${relayPort}`,
    ...opts.replacements,
  });

  const projectId = computeProjectId(project.dir);
  // v3 pairs the bare machine deviceUuid (one socket; projects are streams).
  const deviceUuid = auth.deviceUuid;

  let slot: InternalAgentSlot;
  async function spawnFresh(): Promise<InternalAgentSlot> {
    const handle = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
      env: { ANTGRID_EVAL_TEST: "1" },
    });
    const port = await readAgentApiPort(abDir);
    return { handle, api: { port, host: "127.0.0.1" } };
  }

  slot = await spawnFresh();

  const env: TestEnv = {
    relay,
    project,
    abDir,
    projectId,
    agent: {
      deviceId: deviceUuid,
      rawDeviceId: deviceUuid,
      ed25519Pubkey: auth.ed25519Pub,
      async openPairingWindow(_o?: { ttlMs?: number }): Promise<string> {
        const url = `http://${slot.api.host}:${slot.api.port}/test/open-pairing-window`;
        const res = await fetch(url, { method: "POST" });
        if (!res.ok) {
          throw new Error(`open-pairing-window failed: ${res.status} ${await res.text()}`);
        }
        const body = (await res.json()) as { code: string; expiresAt: string };
        return body.code;
      },
      async kill(): Promise<void> {
        await slot.handle.kill();
      },
    },
    licenseApi: {
      async revokeDevice(deviceId: string): Promise<void> {
        const body = JSON.stringify({ deviceId });
        const sig = createHmac("sha256", RELAY_INTERNAL_SECRET).update(body).digest("hex");
        const res = await fetch(`${relay.httpUrl}/internal/revoke`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-antgrid-signature": sig },
          body,
        });
        if (!res.ok) {
          throw new Error(`/internal/revoke failed: ${res.status} ${await res.text()}`);
        }
      },
    },
    async restartAgent(): Promise<void> {
      await slot.handle.kill();
      // Remove the stale port file so readAgentApiPort waits for the
      // freshly-spawned agent rather than racing on the old value.
      try { rmSync(join(abDir, "api.port"), { force: true }); } catch { /* ignore */ }
      slot = await spawnFresh();
    },
    async connectAdditionalClient(): Promise<LocalTestClient> {
      // A second LOCAL-listener client (this env drives pairing itself and holds
      // no persistent machine phone socket). The v3 relay-side drill-in — one
      // machine socket, project:start → stream-ready → bind — is exercised
      // phone-side via `RelayClient.openProjectStream` (helpers/relay-client.ts).
      // agent.json is gone; obtain connect info via the control plane. The
      // first client (if any) must be closed by the caller — the local
      // listener enforces a single-owner invariant.
      // host.json lives under the child agent's ANTGRID_DIR (= abDir), not the
      // test process's, so read it from abDir directly rather than hostFilePath().
      const { readHostFile } = await import("../../bridge/src/host-discovery");
      const hf = readHostFile(join(abDir, "host.json"));
      if (!hf) throw new Error("no host.json for additional client");
      const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
        body: JSON.stringify({ id: "eval-extra", type: "project:open", projectId, projectPath: project.dir, mode: "local" }),
      });
      const body = (await res.json()) as { ok: boolean; connect?: { port: number; token: string } };
      if (!body.ok || !body.connect) throw new Error("project:open returned no connect info");
      const client = new LocalTestClient();
      await client.connect({ port: body.connect.port, token: body.connect.token });
      return client;
    },
    async teardown() {
      try { await slot.handle.kill(); } catch { /* ignore */ }
      relay.stop();
      licenseApi.stop();
      project.cleanup();
      try { rmSync(abDir, { recursive: true, force: true }); } catch { /* ignore */ }
    },
  };
  return env;
}
