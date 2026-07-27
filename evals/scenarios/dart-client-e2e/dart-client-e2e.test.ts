import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupDartTestEnv, type DartTestEnv } from "../../helpers/harness";

/**
 * Dart Client E2E — tests the REAL Dart relay client code path:
 *   relay ← agent (TS, Ed25519) ← relay → app (Dart CLI, Ed25519)
 *   ECDH handshake + encrypted AbMessage exchange.
 *
 * This catches protocol drift between the Dart and TS implementations.
 */
// setupDartTestEnv admits the Dart client via account trust, but the Dart
// eval CLI's `_handleHandshake` (packages/antgrid_eval_client/lib/src/commands.dart)
// addresses the agent via `_relay.currentState.peerDeviceId`, which nothing
// sets any more — its JSON action protocol has no `handshake` param to target
// an agent directly, so a pair-free Dart handshake cannot succeed until the
// Dart CLI grows one (see harness.ts's `setupDartTestEnv`).
describe.skip("dart-client-e2e", () => {
  let env: DartTestEnv;

  beforeAll(async () => {
    env = await setupDartTestEnv({
      fixtureName: "basic",
      clientName: "eval-dart-app",
    });
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("Dart client authenticates and pairs through central relay", () => {
    expect(env.app).toBeDefined();
    expect(env.app.deviceId).toBeTruthy();
  });

  test("receives agent:status via Dart client", async () => {
    const status = await env.app.waitForAgentStatus(10_000);
    expect(status.data.type).toBe("agent:status");
    expect(status.data.terminals).toBeDefined();
    expect(status.data.agent).toBeDefined();
  }, 15_000);

  test("receives terminal output via Dart client", async () => {
    const output = await env.app.waitForTerminalOutputContaining(
      "echo-test",
      "EVAL_READY",
      15_000,
    );
    expect(output.data.data).toContain("EVAL_READY");
  }, 20_000);

  test("receives file tree via Dart client", async () => {
    const tree = await env.app.waitForFileTree(10_000);
    expect(tree.data.type).toBe("tree:full");
    expect(tree.data.root).toBeDefined();
    expect(tree.data.root.type).toBe("directory");
    const names = tree.data.root.children.map((e: any) => e.name);
    expect(names).toContain("README.md");
  }, 15_000);

  test("sends terminal input and receives echo via Dart client", async () => {
    env.app.sendTerminalStart({
      terminalId: "dart-repl",
      command: "node",
      args: ["-i", "-e", ""],
    });

    // Wait for REPL to initialize
    await Bun.sleep(1_500);

    const marker = `DART_ECHO_${Date.now()}`;
    env.app.sendTerminalInput("dart-repl", `console.log("${marker}")\n`);

    const output = await env.app.waitForTerminalOutputContaining("dart-repl", marker, 10_000);
    expect(output.data.data).toContain(marker);
  }, 20_000);

  test("sends terminal resize via Dart client", async () => {
    env.app.sendTerminalResize("dart-repl", 120, 40);

    // Verify the terminal is still alive by sending another command
    const marker = `RESIZE_CHECK_${Date.now()}`;
    env.app.sendTerminalInput("dart-repl", `console.log("${marker}")\n`);

    const output = await env.app.waitForTerminalOutputContaining("dart-repl", marker, 10_000);
    expect(output.data.data).toContain(marker);
  }, 15_000);

  test("requests file content via Dart client", async () => {
    const content = await env.app.requestFileContent(env.projectId, "README.md", 10_000);
    expect(content.data.type).toBe("file:content");
    expect(content.data.content).toContain("Eval Test Project");
    expect(content.data.size).toBeGreaterThan(0);
  }, 15_000);

  test("rejects path traversal via file:read", async () => {
    // The agent must refuse to serve files outside the project root.
    // A successful traversal would let a paired client exfiltrate any file
    // the agent process can read.
    const result = await env.app.requestFileContent(env.projectId, "../../../etc/passwd", 10_000);
    expect(result.data.type).toBe("file:content");
    expect(result.data.error).toBeTruthy();
    // Either no content, or content unrelated to /etc/passwd
    if (result.data.content) {
      expect(result.data.content).not.toContain("root:");
    }
  }, 15_000);
});
