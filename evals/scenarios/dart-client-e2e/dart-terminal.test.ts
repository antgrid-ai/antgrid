import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupDartTestEnv, type DartTestEnv } from "../../helpers/harness";

/**
 * Dart Terminal E2E — mirrors terminal.test.ts but routes through the real
 * Dart client (antgrid_eval_client CLI subprocess) to exercise the production
 * Dart crypto and relay code paths.
 */
// TODO(evals,v3): setupDartTestEnv can't pair in v3 — the Dart eval CLI (packages/antgrid_eval_client)
// only supports pairCode pairing, but v3 pairs the bare deviceUuid via the QR-less
// account-membership proof, which the frozen helpers (setupDartTestEnv + DartAppClient.pairWith)
// do not thread an accountKey through. Extending only the Dart package is insufficient
// while those helpers are frozen, so this suite is skipped until the harness grows a
// Dart account-membership pair path. Project verbs would also need the stream data plane.
describe.skip("dart-terminal", () => {
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
    const status = await env.app.waitForAgentStatus(10_000);
    expect(status.data.type).toBe("agent:status");
    expect(status.data.terminals).toBeDefined();
    expect(status.data.agent).toBeDefined();
    expect(status.data.agent.name).toBeTruthy();
  }, 15_000);

  test("receives terminal:started for auto-start terminal", async () => {
    const started = await env.app.waitForTerminalStarted("echo-test", 10_000);
    expect(started.data.terminalId).toBe("echo-test");
    expect(started.data.shell).toBeTruthy();
    expect(started.data.cols).toBeGreaterThan(0);
    expect(started.data.rows).toBeGreaterThan(0);
  }, 15_000);

  test("receives terminal output via Dart client", async () => {
    const output = await env.app.waitForTerminalOutputContaining(
      "echo-test",
      "EVAL_READY",
      15_000,
    );
    expect(output.data.data).toContain("EVAL_READY");
  }, 20_000);

  test("sends terminal input and receives echo", async () => {
    env.app.sendTerminalStart({
      terminalId: "dart-term-repl",
      command: "node",
      args: ["-i", "-e", ""],
    });

    await Bun.sleep(1_500);

    const marker = `DART_TERM_${Date.now()}`;
    env.app.sendTerminalInput("dart-term-repl", `console.log("${marker}")\n`);

    const output = await env.app.waitForTerminalOutputContaining(
      "dart-term-repl",
      marker,
      10_000,
    );
    expect(output.data.data).toContain(marker);
  }, 20_000);

  test("terminal resize stays responsive", async () => {
    env.app.sendTerminalResize("echo-test", 120, 40);

    // Prove the agent is still alive by round-tripping a fresh terminal:start.
    // (agent:status is one-shot per state change, so a fresh request like
    // terminal:start gives a deterministic response.)
    env.app.sendTerminalStart({
      terminalId: "post-resize-check",
      command: "node",
      args: ["-e", "process.exit(0)"],
    });

    const started = await env.app.waitForTerminalStarted("post-resize-check", 10_000);
    expect(started.data.terminalId).toBe("post-resize-check");
  }, 15_000);

  test("terminal exit reports exit code", async () => {
    env.app.sendTerminalStart({
      terminalId: "exit-test",
      command: "node",
      args: ["-e", "process.exit(0)"],
    });

    const exited = await env.app.waitForTerminalExited("exit-test", 10_000);
    expect(exited.data.terminalId).toBe("exit-test");
    expect(exited.data.exitCode).toBe(0);
  }, 15_000);
});
