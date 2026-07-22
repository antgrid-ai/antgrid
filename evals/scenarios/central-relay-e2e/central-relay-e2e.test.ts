import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  agentRegistrationId,
  generateEvalAuth,
  spawnAgent,
  startFakeLicenseApi,
  startRelay,
  type AgentHandle,
  type FakeLicenseApi,
  type RelayHandle,
} from "../../helpers/harness";
import { createTestProject, type TestProject } from "../../helpers/fixtures";
import { RelayClient } from "../../helpers/relay-client";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

/**
 * Central Relay E2E — tests the full production path:
 *   relay ← agent (Ed25519 auth) ← relay → app (Ed25519 auth)
 *   then ECDH handshake through relay message routing,
 *   then encrypted AbMessage exchange.
 */
// TODO Tasks 28-33 will replace this with new pair-request v3 evals.
// Old pair-request shape is incompatible with the current relay protocol.
describe.skip("central-relay-e2e", () => {
  let relay: RelayHandle;
  let agent: AgentHandle;
  let app: RelayClient;
  let project: TestProject;
  let abDir: string;
  let licenseApi: FakeLicenseApi;

  const relayPort = 19500 + Math.floor(Math.random() * 500);

  beforeAll(async () => {
    // 1. Create isolated antgrid dir (avoids polluting ~/.antgrid/)
    abDir = mkdtempSync(join(tmpdir(), "antgrid-eval-home-"));

    // 2. Start central relay with longer pair timeout (agent needs time to start)
    relay = await startRelay({ port: relayPort, pairRequestTimeoutMs: 15_000 });
    licenseApi = startFakeLicenseApi();
    const auth = generateEvalAuth();

    // 3. Create test project with relay URL in config
    project = createTestProject("central-relay", {
      "__RELAY_URL__": `ws://localhost:${relayPort}`,
    });

    // 4. Spawn agent in remote mode (identity comes from the stdin bootstrap
    //    payload; the agent mints a token from the fake license API).
    agent = await spawnAgent({
      relayUrl: relay.url,
      licenseApiUrl: licenseApi.url,
      abDir,
      projectDir: project.dir,
      auth,
    });

    // 5. The agent registers on the relay as `${deviceUuid}.${projectId}`.
    const registrationId = agentRegistrationId(auth.deviceUuid, project.dir);

    // 6. Connect app to relay, authenticate, pair with agent
    app = await RelayClient.connectAndAuth(relay.url, {
      deviceType: "app",
      name: "eval-app",
    });

    const pairResult = await app.pairWith(registrationId, 15_000);
    app.setPeerId(pairResult.peerId);

    // 7. Perform E2E handshake through relay
    await app.performE2EHandshake(registrationId, 15_000);
  }, 30_000);

  afterAll(async () => {
    await app?.disconnect();
    await agent?.kill();
    relay?.stop();
    licenseApi?.stop();
    project?.cleanup();
    if (abDir) rmSync(abDir, { recursive: true, force: true });
  });

  test("agent authenticates and pairs through central relay", async () => {
    // If we got here, auth + pairing + E2E handshake all succeeded
    expect(app).toBeDefined();

    // If we got here, auth + pairing + E2E handshake all succeeded
  });

  test("receives agent:status with terminal info", async () => {
    const status = await app.waitForAbType("agent:status", 10_000);
    expect(status.type).toBe("agent:status");
    expect(status.terminals).toBeDefined();
    expect(status.agent).toBeDefined();
    expect(status.agent.name).toBe("eval-agent-relay");
  }, 15_000);

  test("receives terminal output through relay", async () => {
    // The echo-test terminal prints EVAL_READY
    let found = false;
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      const output = await app.waitFor(
        (msg: any) => msg.type === "terminal:output" && msg.terminalId === "echo-test",
        5_000,
      ).catch(() => null);
      if (!output) break;
      if (output.data?.includes("EVAL_READY")) {
        found = true;
        break;
      }
    }
    expect(found).toBe(true);
  }, 20_000);

  test("sends terminal input and receives echo through relay", async () => {
    // Start an interactive node REPL terminal
    const { createMessage } = await import("../../../bridge/src/protocol");
    app.sendEncrypted(
      createMessage("terminal:start", {
        terminalId: "relay-repl",
        name: "relay-repl",
        command: "node",
        args: ["-i", "-e", ""],
      }),
    );

    // Wait for REPL to initialize
    await Bun.sleep(1_500);

    // Send input
    const marker = `RELAY_ECHO_${Date.now()}`;
    app.sendEncrypted(
      createMessage("terminal:input", {
        terminalId: "relay-repl",
        data: `console.log("${marker}")\n`,
      }),
    );

    // Collect output until we find the marker
    let found = false;
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const output = await app.waitFor(
        (msg: any) => msg.type === "terminal:output" && msg.terminalId === "relay-repl",
        5_000,
      ).catch(() => null);
      if (!output) break;
      if (output.data?.includes(marker)) {
        found = true;
        break;
      }
    }
    expect(found).toBe(true);
  }, 20_000);

  test("receives file tree through relay", async () => {
    const tree = await app.waitForAbType("tree:full", 10_000);
    expect(tree.type).toBe("tree:full");
    expect(tree.root).toBeDefined();
    expect(tree.root.type).toBe("directory");
    // Root should have children containing our test files
    expect(tree.root.children).toBeDefined();
    expect(tree.root.children!.length).toBeGreaterThan(0);
    const names = tree.root.children!.map((e: any) => e.name);
    expect(names).toContain("README.md");
  }, 15_000);
});
