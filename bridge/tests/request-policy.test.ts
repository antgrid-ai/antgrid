import { expect, test } from "bun:test";
import {
  BUS_CONTROL_METHODS,
  BUS_PARAMS,
  BUS_READ_METHODS,
  BUS_SESSION_ROW_KEYS,
  busRequestVerdict,
  busSessionRow,
  effectiveReachLevel,
  type AgentReachLevel,
} from "../src/session-bus/request-policy";
import type { SessionEntry } from "../src/protocol";

const LEVELS: AgentReachLevel[] = ["off", "messages", "control"];
const ROLES = ["agent", "orchestrator"] as const;

test("effectiveReachLevel: local off wins over a busControl grant", () => {
  expect(effectiveReachLevel(false, true)).toBe("off");
  expect(effectiveReachLevel(false, false)).toBe("off");
  expect(effectiveReachLevel(true, false)).toBe("messages");
  expect(effectiveReachLevel(true, true)).toBe("control");
});

test("every read method needs reach above off and no role", () => {
  for (const method of BUS_READ_METHODS) {
    for (const role of ROLES) {
      expect(busRequestVerdict({ method, role, level: "off" })).toEqual({ code: "NOT_ALLOWED_AGENT_REACH" });
      expect(busRequestVerdict({ method, role, level: "messages" })).toBe("allow");
      expect(busRequestVerdict({ method, role, level: "control" })).toBe("allow");
    }
  }
});

test("machine.capability-card is reach-gated as a whole", () => {
  expect(busRequestVerdict({ method: "machine.capability-card", role: "agent", level: "off" })).toEqual({
    code: "NOT_ALLOWED_AGENT_REACH",
  });
});

test("every control method needs control reach, then the orchestrator role", () => {
  for (const method of BUS_CONTROL_METHODS) {
    for (const role of ROLES) {
      expect(busRequestVerdict({ method, role, level: "off" })).toEqual({ code: "NOT_ALLOWED_AGENT_REACH" });
      expect(busRequestVerdict({ method, role, level: "messages" })).toEqual({ code: "NOT_ALLOWED_AGENT_REACH" });
    }
    expect(busRequestVerdict({ method, role: "agent", level: "control" })).toEqual({ code: "NOT_ORCHESTRATOR" });
    expect(busRequestVerdict({ method, role: "orchestrator", level: "control" })).toBe("allow");
  }
});

test("any other method is METHOD_NOT_ALLOWED at every role and level", () => {
  for (const method of ["scheduler.list", "scheduler.create", "state.snapshot", "git.checkout", "sessions.delete", "", "session.create "]) {
    for (const role of ROLES) {
      for (const level of LEVELS) {
        expect(busRequestVerdict({ method, role, level })).toEqual({ code: "METHOD_NOT_ALLOWED" });
      }
    }
  }
});

test("session.create takes no command, args or approvalPolicy", () => {
  const schema = BUS_PARAMS["session.create"];
  expect(schema.safeParse({ projectId: "p", tool: "claude", mode: "chat" }).success).toBe(true);
  for (const extra of [{ command: "sh" }, { args: "-c" }, { approvalPolicy: "bypass" }, { scheduleOwnerId: "x" }]) {
    expect(schema.safeParse({ projectId: "p", ...extra }).success).toBe(false);
  }
  expect(schema.safeParse({ projectId: "p", tool: "Bad Tool" }).success).toBe(false);
  expect(schema.safeParse({ projectId: "p", name: "x".repeat(121) }).success).toBe(false);
});

test("session.start bounds the prompt and rejects unknown keys", () => {
  const schema = BUS_PARAMS["session.start"];
  expect(schema.safeParse({ projectId: "p", sessionId: "s", initialPrompt: "x".repeat(32_768) }).success).toBe(true);
  expect(schema.safeParse({ projectId: "p", sessionId: "s", initialPrompt: "x".repeat(32_769) }).success).toBe(false);
  expect(schema.safeParse({ projectId: "p", sessionId: "s", extra: 1 }).success).toBe(false);
});

test("a bus session row carries exactly the allowlist and nothing else", () => {
  const entry = {
    id: "s1", name: "n", createdAt: 1, lastUsedAt: 2, archived: false, running: true, deleting: false,
    tool: "claude", agentKey: "claude", mode: "chat", approvalPolicy: "bypass", command: "sh", args: "-x",
    agentSessionId: "native", agentTranscriptPath: "C:/secret/transcript.jsonl",
    workStatus: { state: "working" }, checkoutKind: "main", checkoutBranch: "main", checkoutId: "main",
    setup: { state: "done", stepIndex: 0, stepCount: 1 },
  } as unknown as SessionEntry;
  const row = busSessionRow(entry);
  expect(Object.keys(row).sort()).toEqual([...BUS_SESSION_ROW_KEYS].sort());
  expect(row).not.toHaveProperty("agentTranscriptPath");
  expect(row).not.toHaveProperty("agentSessionId");
  expect(row).not.toHaveProperty("setup");
  expect(row).not.toHaveProperty("command");
});

test("an absent optional field is omitted, not sent as undefined", () => {
  const row = busSessionRow({ id: "s", name: "n", createdAt: 1, lastUsedAt: 1, archived: false, running: false, mode: "terminal" } as unknown as SessionEntry);
  expect(Object.keys(row).sort()).toEqual(["archived", "createdAt", "id", "lastUsedAt", "mode", "name", "running"]);
});
