import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../../helpers/harness";
import { createMessage } from "../../../bridge/src/protocol";
import { firstProjectStream } from "../../support/stream";

/**
 * v3: multiple terminals multiplex over the ONE firstProject stream, each keyed
 * by its terminalId. A late-binding phone misses the config-autostarted services'
 * live output, so this starts both terminals itself and asserts their outputs
 * come back correctly tagged — the same multi-terminal fan-out, over the stream.
 */
describe("multiple terminals", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    env = await setupTestEnv({ fixtureName: "multi-terminal" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("receives output from both terminals with correct IDs", async () => {
    for (const [id, marker] of [["terminal-a", "TERMINAL_A"], ["terminal-b", "TERMINAL_B"]] as const) {
      env.app.sendOnStream(streamId, createMessage("terminal:start", {
        terminalId: id,
        name: id,
        command: "node",
        args: ["-e", `console.log('${marker}'); setTimeout(() => {}, 60000)`],
      }));
    }

    const deadline = Date.now() + 15_000;
    let outputA = "";
    let outputB = "";
    while (Date.now() < deadline) {
      if (outputA.includes("TERMINAL_A") && outputB.includes("TERMINAL_B")) break;
      try {
        const msg = await env.app.waitForStreamAbType(streamId, "terminal:output", 2_000);
        const data = (msg as any).data ?? "";
        const termId = (msg as any).terminalId;
        if (termId === "terminal-a") outputA += data;
        if (termId === "terminal-b") outputB += data;
      } catch { break; }
    }

    expect(outputA).toContain("TERMINAL_A");
    expect(outputB).toContain("TERMINAL_B");
  });
});
