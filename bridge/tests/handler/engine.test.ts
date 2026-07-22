// bridge/tests/handler/engine.test.ts
import { test, expect } from "bun:test";
import { HandlerEngine } from "../../src/handler/engine";
import type { HandlerDecision } from "../../src/handler/decision";
import type { AbMessage } from "../../src/protocol";

function makeEngine(over: Partial<any> = {}) {
  const sent: AbMessage[] = [];
  const writes: { id: string; data: string }[] = [];
  const engine = new HandlerEngine({
    projectId: "p1", projectPath: "/home/me/proj", tool: () => "claude-code", abDir: "/tmp/ab",
    write: (id, data) => writes.push({ id, data }),
    sendAb: (m) => sent.push(m),
    getRecentOutput: () => "agent asked something",
    loadConfigFn: () => ({ version: 1, enabled: true, template: "closer" }),
    appendActivityFn: () => {},
    now: () => 1000,
    runJudgeFn: async () => over.decision as HandlerDecision,
    ...over,
  });
  return { engine, sent, writes };
}

test("a confident handle injects the reply + Enter into the PTY", async () => {
  const { engine, writes } = makeEngine({
    decision: { decision: "handle", confidence: 0.95, reason: "clear", reply: "use bun test" },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toEqual([{ id: "t1", data: "use bun test\r" }]);
});

test("an escalate decision emits handler:escalation and never writes", async () => {
  const { engine, sent, writes } = makeEngine({
    decision: { decision: "escalate", confidence: 0.2, reason: "arch call",
      notify: { title: "?", body: "bun vs vitest", draftReply: "use bun", urgency: "normal" } },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toHaveLength(0);
  const esc = sent.find((m) => m.type === "handler:escalation") as any;
  expect(esc).toBeDefined();
  expect(esc.draftReply).toBe("use bun");
});

test("destructive floor forces escalation even on a confident handle", async () => {
  const { engine, sent, writes } = makeEngine({
    decision: { decision: "handle", confidence: 0.99, reason: "go", reply: "git push --force origin main" },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toHaveLength(0);
  expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
});

test("watchdog escalates without ever calling the judge", async () => {
  let judged = false;
  const { engine, sent } = makeEngine({
    loadConfigFn: () => ({ version: 1, enabled: true, template: "watchdog" }),
    runJudgeFn: async () => { judged = true; return null; },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(judged).toBe(false);
  expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
});

test("disabled handler ignores events", async () => {
  const { engine, sent, writes } = makeEngine({
    loadConfigFn: () => ({ version: 1, enabled: false, template: "closer" }),
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toHaveLength(0);
  expect(sent).toHaveLength(0);
});

test("judge failure (null) falls back to escalation, not silence", async () => {
  const { engine, sent } = makeEngine({ runJudgeFn: async () => null });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
});

test("handle decision with reply exceeding 4096 chars escalates without writing", async () => {
  const { engine, sent, writes } = makeEngine({
    decision: { decision: "handle", confidence: 0.95, reason: "long", reply: "x".repeat(4097) },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toHaveLength(0);
  const esc = sent.find((m) => m.type === "handler:escalation") as any;
  expect(esc).toBeDefined();
  expect(esc.reasoning).toMatch(/too long/);
});

test("handle decision with embedded newline in reply escalates without writing", async () => {
  const { engine, sent, writes } = makeEngine({
    decision: { decision: "handle", confidence: 0.95, reason: "sneaky", reply: "echo hi\nrm -rf /" },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toHaveLength(0);
  expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
});

test("handle decision with embedded carriage-return in reply escalates without writing", async () => {
  const { engine, sent, writes } = makeEngine({
    decision: { decision: "handle", confidence: 0.9, reason: "cr", reply: "first\rsecond" },
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  expect(writes).toHaveLength(0);
  expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
});

test("onUserReply while engine is OFF does not emit handler:status and does not read config", () => {
  const configReads: number[] = [];
  const sent: AbMessage[] = [];
  const engine = new HandlerEngine({
    projectId: "p1", projectPath: "/home/me/proj", tool: () => "claude-code", abDir: "/tmp/ab",
    write: () => {}, sendAb: (m: AbMessage) => sent.push(m), getRecentOutput: () => "",
    loadConfigFn: () => { configReads.push(1); return { version: 1, enabled: false, template: "closer" }; },
    appendActivityFn: () => {},
    now: () => 1000,
  });
  // Engine starts in "off" state (never configured); onUserReply should be a no-op.
  engine.onUserReply("t1");
  expect(configReads).toHaveLength(0);
  expect(sent.filter((m) => m.type === "handler:status")).toHaveLength(0);
});

test("onUserReply while engine is watching decrements pending and emits status on change", () => {
  const sent: AbMessage[] = [];
  const engine = new HandlerEngine({
    projectId: "p1", projectPath: "/home/me/proj", tool: () => "claude-code", abDir: "/tmp/ab",
    write: () => {}, sendAb: (m: AbMessage) => sent.push(m), getRecentOutput: () => "",
    saveConfigFn: () => {},
    appendActivityFn: () => {},
    now: () => 1000,
  });
  engine.configure({ enabled: true, template: "closer" });
  sent.length = 0; // clear configure's own status emit
  // Now in "watching" state, no pending escalations — calling onUserReply produces no change.
  engine.onUserReply("t1");
  expect(sent.filter((m) => m.type === "handler:status")).toHaveLength(0);
});

test("a reply on one terminal does not clear another terminal's pending escalation", async () => {
  const { engine, sent } = makeEngine({
    loadConfigFn: () => ({ version: 1, enabled: true, template: "watchdog" }),
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  await engine.handleEvent({ terminalId: "t2", event: "awaiting_input" });
  sent.length = 0;
  engine.onUserReply("t1");
  const status = sent.find((m) => m.type === "handler:status") as any;
  expect(status).toBeDefined();
  expect(status.state).toBe("needs_you");
  expect(status.pendingEscalations).toBe(1);
});

test("onTerminalExit reclaims a terminal's pending escalation", async () => {
  const { engine, sent } = makeEngine({
    loadConfigFn: () => ({ version: 1, enabled: true, template: "watchdog" }),
  });
  await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
  sent.length = 0;
  engine.onTerminalExit("t1");
  const status = sent.find((m) => m.type === "handler:status") as any;
  expect(status).toBeDefined();
  expect(status.state).toBe("watching");
  expect(status.pendingEscalations).toBe(0);
});

test("configure persists the config and reflects it in handler:status", () => {
  const saved: any[] = [];
  const sent: AbMessage[] = [];
  const engine = new HandlerEngine({
    projectId: "p1", projectPath: "/home/me/proj", tool: () => "claude-code", abDir: "/tmp/ab",
    write: () => {}, sendAb: (m: AbMessage) => sent.push(m), getRecentOutput: () => "",
    saveConfigFn: (c: any) => saved.push(c),
  } as any);
  engine.configure({ enabled: true, template: "closer", model: "haiku" });
  expect(saved).toEqual([{ version: 1, enabled: true, template: "closer", model: "haiku" }]);
  const status = sent.find((m) => m.type === "handler:status") as any;
  expect(status.enabled).toBe(true);
  expect(status.template).toBe("closer");
});
