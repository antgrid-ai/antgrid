// evals/tests/handler.test.ts
import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

// Each test owns its env: the brief-lifecycle scenario needs agent-process env
// vars (the scripted judge) that a shared beforeAll env can't carry.
let env: TestEnv | undefined;
let streamId: string;
afterEach(async () => { await env?.teardown(); env = undefined; });

test("Notify-only: a handler-event triggers a handler:escalation at the app", async () => {
  env = await setupTestEnv({ fixtureName: "basic" });
  // v3: handler:* are project verbs → the firstProject stream.
  streamId = await firstProjectStream(env.app, env.projectId, 10_000);

  // Arm Handler in notify-only mode — every event escalates without spending a judge call.
  env.app.sendOnStream(streamId, createMessage("handler:configure", {
    projectId: env.projectId, terminalId: "agent-main", armed: true, notifyOnly: true,
    brief: { taskSummary: "watch for input", willHandle: [], wakeFor: ["anything"], thenItems: [] },
  }));
  await env.app.waitForStreamAbType(streamId, "handler:status", 5_000);

  // Simulate an injected hook firing by POSTing /handler-event to the agent's local API.
  // The agent's API port is discoverable from its ~/.antgrid/api.port file (written at startup).
  const portFile = `${env.abDir}/api.port`;
  const port = (await Bun.file(portFile).text()).trim();
  // Synthetic terminalId is fine: notify-only escalates regardless of terminal validity.
  await fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "agent-main", event: "awaiting_input", agent: "claude" }),
  });

  const esc = await env.app.waitForStreamAbType(streamId, "handler:escalation", 8_000);
  expect((esc as any).projectId).toBe(env.projectId);
  expect((esc as any).terminalId).toBe("agent-main");
}, 40_000);

test("Brief lifecycle: arm -> auto-answer -> satisfied-ledger -> wrap-up", async () => {
  // The agent runs as a spawned process, so in-process runDecisionFn injection is
  // unreachable — swap the judge CLI for a scripted bun script via judge.ts's
  // eval-only env override (ANTGRID_EVAL_TEST + ANTGRID_TEST_JUDGE_SCRIPT). Each
  // judge call is a fresh process, so the script tracks its call index in a
  // sidecar state file rather than in-memory.
  const dir = mkdtempSync(join(tmpdir(), "antgrid-eval-judge-"));
  const scriptPath = join(dir, "fake-judge.ts");
  const statePath = join(dir, "state.txt");
  const outputsPath = join(dir, "outputs.json");

  const FAKE_JUDGE = `
const state = process.env.ANTGRID_TEST_JUDGE_STATE;
const outputs = JSON.parse(await Bun.file(process.env.ANTGRID_TEST_JUDGE_OUTPUTS).text());
const n = (await Bun.file(state).exists()) ? Number(await Bun.file(state).text()) : 0;
await Bun.write(state, String(n + 1));
console.log(JSON.stringify(outputs[Math.min(n, outputs.length - 1)]));
`;
  const OUTPUTS = [
    { decision: "handle", confidence: 0.9, reason: "routine prompt", reply: "continue" },
    { decision: "continue", confidence: 0.9, reason: "task done",
      satisfiedItems: [{ item: "follow-up one", evidence: "ran" }], doneWhenMet: true },
  ];
  writeFileSync(scriptPath, FAKE_JUDGE);
  writeFileSync(outputsPath, JSON.stringify(OUTPUTS));

  env = await setupTestEnv({
    fixtureName: "basic",
    env: {
      ANTGRID_TEST_JUDGE_SCRIPT: scriptPath,
      ANTGRID_TEST_JUDGE_STATE: statePath,
      ANTGRID_TEST_JUDGE_OUTPUTS: outputsPath,
    },
  });
  streamId = await firstProjectStream(env.app, env.projectId, 10_000);

  // Arm with a full brief: doneWhen + one then-item drives the wrap-up at the end.
  env.app.sendOnStream(streamId, createMessage("handler:configure", {
    projectId: env.projectId, terminalId: "agent-main", armed: true, notifyOnly: false,
    brief: {
      taskSummary: "test task", willHandle: ["test prompts"], wakeFor: ["danger"],
      doneWhen: "done marker printed", thenItems: ["follow-up one"],
    },
  }));
  const armedStatus = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:status" && m.sessions.length === 1, 5_000,
  );
  expect(armedStatus.sessions[0].terminalId).toBe("agent-main");

  const portFile = `${env.abDir}/api.port`;
  const port = (await Bun.file(portFile).text()).trim();
  // The endpoint is fire-and-forget (returns before handleEvent resolves), and
  // the scripted judge tracks its call index via a sidecar state file rather
  // than in-memory — so the two turn_end events must be serialized by awaiting
  // the first's resulting activity before firing the second, or both calls could
  // race the same state file and read call-index 0 twice.
  //
  // First turn_end -> scripted "handle" (auto-answer, no wrap-up yet since
  // doneWhenMet isn't set). The reply is injected into the synthetic terminalId,
  // which TerminalManager.write() no-ops on (unknown terminal) — harmless.
  await fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "agent-main", event: "turn_end", agent: "claude" }),
  });
  const handleActivity = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:activity" && m.decision === "handle", 15_000,
  );
  expect(handleActivity.terminalId).toBe("agent-main");

  // Second turn_end -> scripted "continue" with the follow-up satisfied and
  // doneWhenMet true, which triggers wrap-up (auto-disarm).
  await fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "agent-main", event: "turn_end", agent: "claude" }),
  });

  // Assert RELATIVE order (not adjacency — a "continue" activity lands between
  // the last two) of the remaining activity kinds that mark the lifecycle.
  const satisfiedActivity = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:activity" && m.decision === "item_satisfied", 15_000,
  );
  expect(satisfiedActivity.detail).toBe("ran");

  const wrappedActivity = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:activity" && m.decision === "wrapped_up", 15_000,
  );
  expect(wrappedActivity.terminalId).toBe("agent-main");

  const finalStatus = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:status" && m.sessions.length === 0, 5_000,
  );
  expect(finalStatus.sessions).toEqual([]);
}, 60_000);
