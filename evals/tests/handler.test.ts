// evals/tests/handler.test.ts
import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage, type HandlerInstructionItem } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";

// Each test owns its env: both scenarios need agent-process env vars (their own
// scripted judge) that a shared beforeAll env can't carry.
let env: TestEnv | undefined;
let streamId: string;
afterEach(async () => { await env?.teardown(); env = undefined; });

test("A judged pause reaches the app as a handler:escalation", async () => {
  // The agent runs as a spawned process, so in-process runDecisionFn injection is
  // unreachable — swap the judge CLI for a scripted bun script via judge.ts's
  // eval-only env override (ANTGRID_EVAL_TEST + ANTGRID_TEST_JUDGE_SCRIPT). It
  // escalates whatever it is shown, so the assertion below is about the wiring
  // (hook -> engine -> relay -> app) and not about which verdict a real judge picks.
  const dir = mkdtempSync(join(tmpdir(), "antgrid-eval-judge-"));
  const scriptPath = join(dir, "escalating-judge.ts");
  const ESCALATING_JUDGE = `
console.log(JSON.stringify({
  decision: "escalate", confidence: 0.9, reason: "needs the user",
  notify: { title: "Handler", body: "Agent is waiting on you", draftReply: "", urgency: "high" },
}));
`;
  writeFileSync(scriptPath, ESCALATING_JUDGE);

  env = await setupTestEnv({
    fixtureName: "basic",
    env: { ANTGRID_TEST_JUDGE_SCRIPT: scriptPath },
  });
  // v3: handler:* are project verbs → the firstProject stream.
  streamId = await firstProjectStream(env.app, env.projectId, 10_000);

  // No backlog: arming carries no required payload, and a pause is judged on its
  // own, so nothing has to be queued for an escalation to be raised.
  env.app.sendOnStream(streamId, createMessage("handler:configure", {
    projectId: env.projectId, terminalId: "agent-main", armed: true, goal: "watch for input",
  }));
  await env.app.waitForStreamAbType(streamId, "handler:status", 5_000);

  // Simulate an injected hook firing by POSTing /handler-event to the agent's local API.
  // The agent's API port is discoverable from its ~/.antgrid/api.port file (written at startup).
  const portFile = `${env.abDir}/api.port`;
  const port = (await Bun.file(portFile).text()).trim();
  // Synthetic terminalId is fine: an escalation only puts a frame on the wire, so
  // nothing on this path writes to the terminal.
  await fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "agent-main", event: "awaiting_input", agent: "claude" }),
  });

  // A judge spawn sits between the POST and this frame, so the wait matches the
  // budget the lifecycle test gives its own judged steps.
  const esc = await env.app.waitForStreamAbType(streamId, "handler:escalation", 15_000);
  expect((esc as any).projectId).toBe(env.projectId);
  expect((esc as any).terminalId).toBe("agent-main");
}, 60_000);

test("Backlog lifecycle: arm -> auto-answer -> item done -> wrap-up", async () => {
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
  // The scripted judge answers with ids, so the eval and the arm below have to
  // agree on one — a transition naming anything else is rejected by design.
  const ITEM_ID = "item-followup";
  const BACKLOG: HandlerInstructionItem[] = [
    { id: ITEM_ID, text: "follow-up one", status: "queued", createdAt: Date.now() },
  ];
  const OUTPUTS = [
    { decision: "handle", confidence: 0.9, reason: "routine prompt", reply: "continue" },
    { decision: "continue", confidence: 0.9, reason: "task done",
      transitions: [{ id: ITEM_ID, status: "done", evidence: "ran" }] },
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

  // One queued item is the whole wrap-up condition: the session auto-disarms once
  // every item is terminal, so a single `done` drives the end of the lifecycle.
  env.app.sendOnStream(streamId, createMessage("handler:configure", {
    projectId: env.projectId, terminalId: "agent-main", armed: true,
    goal: "test task", backlog: BACKLOG,
  }));
  const armedStatus = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:status" && m.sessions.length === 1, 5_000,
  );
  expect(armedStatus.sessions[0].terminalId).toBe("agent-main");
  expect(armedStatus.sessions[0].goal).toBe("test task");
  expect(armedStatus.sessions[0].backlog).toEqual(BACKLOG);

  const portFile = `${env.abDir}/api.port`;
  const port = (await Bun.file(portFile).text()).trim();
  // The endpoint is fire-and-forget (returns before handleEvent resolves), and
  // the scripted judge tracks its call index via a sidecar state file rather
  // than in-memory — so the two turn_end events must be serialized by awaiting
  // the first's resulting activity before firing the second, or both calls could
  // race the same state file and read call-index 0 twice.
  //
  // First turn_end -> scripted "handle" (auto-answer, no wrap-up yet: the one
  // backlog item is still queued). The reply is injected into the synthetic terminalId,
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

  // Second turn_end -> scripted "continue" transitioning the only backlog item to
  // done, which leaves the backlog fully terminal and triggers wrap-up (auto-disarm).
  await fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: "agent-main", event: "turn_end", agent: "claude" }),
  });

  // Assert RELATIVE order (not adjacency — a "continue" activity lands between
  // the last two) of the remaining activity kinds that mark the lifecycle.
  const doneActivity = await env.app.waitFor(
    (m: any) => m._streamId === streamId
      && m.type === "handler:activity" && m.decision === "item_done", 15_000,
  );
  // No `outcome` on the transition, so the record falls back to the evidence.
  expect(doneActivity.detail).toBe("ran");

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
