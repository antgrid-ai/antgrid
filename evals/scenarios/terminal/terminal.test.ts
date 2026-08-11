import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../../helpers/harness";
import { createMessage } from "../../../bridge/src/protocol";
import { firstProjectStream } from "../../support/stream";

/**
 * v3: terminals run on the firstProject STREAM, not the control
 * plane. A late-binding phone can't observe the config-autostarted service's
 * live terminal:started/output (they precede the bind and the snapshot carries no
 * scrollback), so these drive terminals the phone STARTS itself — the same E2E
 * relay path, fully observable on the stream.
 */
describe("terminal", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("receives terminal:started for a phone-started terminal", async () => {
    env.app.sendOnStream(streamId, createMessage("terminal:start", {
      terminalId: "started-probe",
      name: "started-probe",
      command: "node",
      args: ["-e", "setTimeout(() => {}, 60000)"],
    }));
    const started = await env.app.waitForStreamAbType(streamId, "terminal:started", 5_000);
    expect(started.terminalId).toBe("started-probe");
    expect(started.shell).toBeTruthy();
    expect(started.cols).toBeGreaterThan(0);
    expect(started.rows).toBeGreaterThan(0);
  });

  test("receives terminal output", async () => {
    env.app.sendOnStream(streamId, createMessage("terminal:start", {
      terminalId: "output-probe",
      name: "output-probe",
      command: "node",
      args: ["-e", "console.log('EVAL_READY'); setTimeout(() => {}, 60000)"],
    }));
    await env.app.waitForStreamAbType(streamId, "terminal:started", 5_000);

    const deadline = Date.now() + 10_000;
    let output = "";
    while (Date.now() < deadline) {
      try {
        const msg = await env.app.waitForStreamAbType(streamId, "terminal:output", 2_000);
        if ((msg as any).terminalId === "output-probe") output += (msg as any).data;
        if (output.includes("EVAL_READY")) break;
      } catch { break; }
    }
    expect(output).toContain("EVAL_READY");
  });

  test("can send terminal input and receive echoed output", async () => {
    env.app.sendOnStream(streamId, createMessage("terminal:start", {
      terminalId: "input-repl",
      name: "input-repl",
      command: "node",
      args: ["-i", "-e", ""],
    }));
    await env.app.waitForStreamAbType(streamId, "terminal:started", 5_000);
    await Bun.sleep(1_500); // let the REPL initialize

    const marker = `ANTGRID_INPUT_${Date.now()}`;
    env.app.sendOnStream(streamId, createMessage("terminal:input", {
      terminalId: "input-repl",
      data: `console.log("${marker}")\n`,
    }));

    const deadline = Date.now() + 10_000;
    let output = "";
    while (Date.now() < deadline) {
      try {
        const msg = await env.app.waitForStreamAbType(streamId, "terminal:output", 2_000);
        if ((msg as any).terminalId === "input-repl") output += (msg as any).data;
        if (output.includes(marker)) break;
      } catch { break; }
    }
    expect(output).toContain(marker);
  });
});
