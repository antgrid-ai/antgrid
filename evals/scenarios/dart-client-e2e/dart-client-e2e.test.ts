import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupDartTestEnv, type DartTestEnv } from "../../helpers/harness";

/**
 * Dart Client E2E — tests the REAL Dart relay client code path:
 *   relay ← agent (TS, Ed25519) ← relay → app (Dart CLI, Ed25519)
 *   v3 handshake + sealed `{s, m}` stream traffic.
 *
 * This catches protocol drift between the Dart and TS implementations.
 *
 * v3: project verbs ride the firstProject stream (`env.streamId`), and a
 * late-binding phone never sees the config-autostarted service's live
 * terminal:started/output — so terminal assertions drive terminals the phone
 * starts itself, exactly like the TS `terminal` scenario.
 */
describe("dart-client-e2e", () => {
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

  test("Dart client authenticates and binds a project stream", () => {
    expect(env.app).toBeDefined();
    expect(env.app.deviceId).toBeTruthy();
    expect(env.streamId).toBeTruthy();
  });

  test("receives agent:status via Dart client", async () => {
    const status = await env.app.waitForAgentStatus(env.streamId, 10_000);
    expect(status.data.type).toBe("agent:status");
    expect(status.data.terminals).toBeDefined();
    expect(status.data.agent).toBeDefined();
  }, 15_000);

  test("receives terminal output via Dart client", async () => {
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "dart-output-probe",
      command: "node",
      args: ["-e", "console.log('EVAL_READY'); setTimeout(() => {}, 60000)"],
    });
    await env.app.waitForTerminalStarted(env.streamId, "dart-output-probe", 10_000);

    const output = await env.app.waitForTerminalOutputContaining(
      env.streamId,
      "dart-output-probe",
      "EVAL_READY",
      15_000,
    );
    expect(output.data.data).toContain("EVAL_READY");
  }, 25_000);

  test("receives file tree via Dart client", async () => {
    const tree = await env.app.waitForFileTree(env.streamId, 10_000);
    expect(tree.data.type).toBe("tree:full");
    expect(tree.data.root).toBeDefined();
    expect(tree.data.root.type).toBe("directory");
    const names = tree.data.root.children.map((e: any) => e.name);
    expect(names).toContain("README.md");
  }, 15_000);

  test("sends terminal input and receives echo via Dart client", async () => {
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "dart-repl",
      command: "node",
      args: ["-i", "-e", ""],
    });
    await env.app.waitForTerminalStarted(env.streamId, "dart-repl", 10_000);

    // Let the REPL initialize before typing at it.
    await Bun.sleep(1_500);

    const marker = `DART_ECHO_${Date.now()}`;
    env.app.sendTerminalInput(env.streamId, "dart-repl", `console.log("${marker}")\n`);

    const output = await env.app.waitForTerminalOutputContaining(
      env.streamId,
      "dart-repl",
      marker,
      10_000,
    );
    expect(output.data.data).toContain(marker);
  }, 25_000);

  test("sends terminal resize via Dart client", async () => {
    env.app.sendTerminalResize(env.streamId, "dart-repl", 120, 40);

    // Verify the terminal is still alive by sending another command
    const marker = `RESIZE_CHECK_${Date.now()}`;
    env.app.sendTerminalInput(env.streamId, "dart-repl", `console.log("${marker}")\n`);

    const output = await env.app.waitForTerminalOutputContaining(
      env.streamId,
      "dart-repl",
      marker,
      10_000,
    );
    expect(output.data.data).toContain(marker);
  }, 15_000);

  test("requests file content via Dart client", async () => {
    const content = await env.app.requestFileContent(
      env.streamId,
      env.projectId,
      "README.md",
      10_000,
    );
    expect(content.data.type).toBe("file:content");
    expect(content.data.content).toContain("Eval Test Project");
    expect(content.data.size).toBeGreaterThan(0);
  }, 15_000);

  test("rejects path traversal via file:read", async () => {
    // The agent must refuse to serve files outside the project root.
    // A successful traversal would let a trusted client exfiltrate any file
    // the agent process can read.
    const result = await env.app.requestFileContent(
      env.streamId,
      env.projectId,
      "../../../etc/passwd",
      10_000,
    );
    expect(result.data.type).toBe("file:content");
    expect(result.data.error).toBeTruthy();
    // Either no content, or content unrelated to /etc/passwd
    if (result.data.content) {
      expect(result.data.content).not.toContain("root:");
    }
  }, 15_000);
});
