import { test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

let env: TestEnv;
let streamId: string;

beforeAll(async () => {
  env = await setupTestEnv({ fixtureName: "basic" });
  // v3: terminal verbs + notifications run on the firstProject stream.
  streamId = await firstProjectStream(env.app, env.projectId, 10_000);
}, 60_000);

afterAll(async () => {
  await env?.teardown();
});

test("OSC 9 emitted in a terminal reaches the app as terminal:notification", async () => {
  const terminalId = `osc9-test-${Date.now()}`;

  // Start a terminal that writes the OSC 9 sequence then stays alive long
  // enough for the notification to propagate (node -e, cross-platform).
  // \x1b]9;Build finished\x07 is ESC ] 9 ; <text> BEL — picked up by the
  // TerminalNotificationScanner in bridge/src/notification-scanner.ts.
  env.app.sendOnStream(streamId, 
    createMessage("terminal:start", {
      terminalId,
      name: terminalId,
      command: "node",
      args: [
        "-e",
        "process.stdout.write('\\x1b]9;Build finished\\x07'); setTimeout(() => {}, 5000);",
      ],
    }),
  );

  // Wait for terminal:started so we know the PTY is running.
  await env.app.waitForStreamAbType(streamId, "terminal:started", 5_000);

  // Collect terminal:notification messages with a 10 s deadline; filter to
  // ones that originated from our terminal and have kind === "osc9".
  const deadline = Date.now() + 10_000;
  let notification: any = null;
  while (Date.now() < deadline) {
    try {
      const msg = await env.app.waitForStreamAbType(streamId, 
        "terminal:notification",
        Math.max(100, deadline - Date.now()),
      );
      if ((msg as any).terminalId === terminalId) {
        notification = msg;
        break;
      }
    } catch {
      // timeout — break out of the polling loop
      break;
    }
  }

  expect(notification).not.toBeNull();
  expect((notification as any).kind).toBe("osc9");
  expect((notification as any).body).toContain("Build finished");
}, 30_000);
