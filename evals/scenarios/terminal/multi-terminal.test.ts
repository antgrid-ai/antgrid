import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../../helpers/harness";
import { createMessage } from "../../../bridge/src/protocol";
import { firstProjectStream } from "../../support/stream";
import { frameContaining } from "./frame-output";

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

    const frames = await Promise.all([["terminal-a", "TERMINAL_A"], ["terminal-b", "TERMINAL_B"]].map(async ([id, marker]) => {
      await env.app.waitFor((message) => message.type === "terminal:started" &&
        message._streamId === streamId && message.terminalId === id, 5_000);
      return frameContaining(env.app, streamId, id, marker);
    }));
    expect(frames[0].terminalId).toBe("terminal-a");
    expect(frames[0].ansi).toContain("TERMINAL_A");
    expect(frames[0].ansi).not.toContain("TERMINAL_B");
    expect(frames[1].terminalId).toBe("terminal-b");
    expect(frames[1].ansi).toContain("TERMINAL_B");
    expect(frames[1].ansi).not.toContain("TERMINAL_A");
  });
});
