// evals/tests/handler.test.ts
import { test, expect, beforeAll, afterAll } from "bun:test";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

let env: TestEnv;
let streamId: string;
beforeAll(async () => {
  env = await setupTestEnv({ fixtureName: "basic" });
  // v3: handler:* are project verbs → the firstProject stream.
  streamId = await firstProjectStream(env.app, env.projectId, 10_000);
}, 60_000);
afterAll(async () => { await env?.teardown(); });

test("Watchdog: a handler-event triggers a handler:escalation at the app", async () => {
  // Enable Handler in Watchdog mode for this project.
  env.app.sendOnStream(streamId, createMessage("handler:configure", {
    projectId: env.projectId, enabled: true, template: "watchdog",
  }));
  await env.app.waitForStreamAbType(streamId, "handler:status", 5_000);

  // Simulate an injected hook firing by POSTing /handler-event to the agent's local API.
  // The agent's API port is discoverable from its ~/.antgrid/api.port file (written at startup).
  const portFile = `${env.abDir}/api.port`;
  const port = (await Bun.file(portFile).text()).trim();
  // Use any live agent terminalId from the snapshot; fall back to a synthetic one the
  // engine still escalates on (Watchdog escalates regardless of terminal validity).
  await fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "agent-main", event: "awaiting_input", agent: "claude" }),
  });

  const esc = await env.app.waitForStreamAbType(streamId, "handler:escalation", 8_000);
  expect((esc as any).projectId).toBe(env.projectId);
  expect((esc as any).terminalId).toBe("agent-main");
}, 40_000);
