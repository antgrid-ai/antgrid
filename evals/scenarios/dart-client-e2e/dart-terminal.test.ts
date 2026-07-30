import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupDartTestEnv, type DartTestEnv } from "../../helpers/harness";

/**
 * Dart Terminal E2E — mirrors terminal.test.ts but routes through the real
 * Dart client (antgrid_eval_client CLI subprocess) to exercise the production
 * Dart crypto, session and stream code paths.
 *
 * Like the TS scenario, every terminal here is one the phone STARTS: the
 * config-autostarted service's `terminal:started`/output are live events that
 * precede the bind, and the snapshot carries no scrollback.
 */
describe("dart-terminal", () => {
  let env: DartTestEnv;

  beforeAll(async () => {
    env = await setupDartTestEnv({
      fixtureName: "basic",
      clientName: "eval-dart-terminal",
    });
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("receives agent:status with terminal info", async () => {
    const status = await env.app.waitForAgentStatus(env.streamId, 10_000);
    expect(status.data.type).toBe("agent:status");
    expect(status.data.terminals).toBeDefined();
    expect(status.data.agent).toBeDefined();
    expect(status.data.agent.name).toBeTruthy();
  }, 15_000);

  test("receives terminal:started for a phone-started terminal", async () => {
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "dart-started-probe",
      command: "node",
      args: ["-e", "setTimeout(() => {}, 60000)"],
    });

    const started = await env.app.waitForTerminalStarted(
      env.streamId,
      "dart-started-probe",
      10_000,
    );
    expect(started.data.terminalId).toBe("dart-started-probe");
    expect(started.data.shell).toBeTruthy();
    expect(started.data.cols).toBeGreaterThan(0);
    expect(started.data.rows).toBeGreaterThan(0);
  }, 15_000);

  test("receives terminal output via Dart client", async () => {
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "dart-term-output",
      command: "node",
      args: ["-e", "console.log('EVAL_READY'); setTimeout(() => {}, 60000)"],
    });
    await env.app.waitForTerminalStarted(env.streamId, "dart-term-output", 10_000);

    const output = await env.app.waitForTerminalOutputContaining(
      env.streamId,
      "dart-term-output",
      "EVAL_READY",
      15_000,
    );
    expect(output.data.data).toContain("EVAL_READY");
  }, 25_000);

  test("sends terminal input and receives echo", async () => {
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "dart-term-repl",
      command: "node",
      args: ["-i", "-e", ""],
    });
    await env.app.waitForTerminalStarted(env.streamId, "dart-term-repl", 10_000);

    await Bun.sleep(1_500);

    const marker = `DART_TERM_${Date.now()}`;
    env.app.sendTerminalInput(env.streamId, "dart-term-repl", `console.log("${marker}")\n`);

    const output = await env.app.waitForTerminalOutputContaining(
      env.streamId,
      "dart-term-repl",
      marker,
      10_000,
    );
    expect(output.data.data).toContain(marker);
  }, 25_000);

  test("terminal resize stays responsive", async () => {
    env.app.sendTerminalResize(env.streamId, "dart-term-repl", 120, 40);

    // Prove the agent is still alive by round-tripping a fresh terminal:start.
    // (agent:status is one-shot per state change, so a fresh request like
    // terminal:start gives a deterministic response.)
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "post-resize-check",
      command: "node",
      args: ["-e", "process.exit(0)"],
    });

    const started = await env.app.waitForTerminalStarted(
      env.streamId,
      "post-resize-check",
      10_000,
    );
    expect(started.data.terminalId).toBe("post-resize-check");
  }, 15_000);

  test("terminal exit reports exit code", async () => {
    env.app.sendTerminalStart(env.streamId, {
      terminalId: "exit-test",
      command: "node",
      args: ["-e", "process.exit(0)"],
    });

    const exited = await env.app.waitForTerminalExited(env.streamId, "exit-test", 10_000);
    expect(exited.data.terminalId).toBe("exit-test");
    expect(exited.data.exitCode).toBe(0);
  }, 15_000);
});
