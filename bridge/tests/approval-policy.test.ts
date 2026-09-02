import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveApprovalPolicy } from "../src/agent-approval-policy";
import { AGENTS } from "../src/agents/registry";
import { SessionManager } from "../src/session-manager";

const stores: string[] = [];

function store() {
  const value = mkdtempSync(join(tmpdir(), "antgrid-approval-policy-"));
  stores.push(value);
  return value;
}

function terminalManager() {
  const spawns: any[] = [];
  const live = new Set<string>();
  return {
    spawns,
    spawn(config: any) { spawns.push(config); live.add(config.terminalId); return config.terminalId; },
    has: (id: string) => live.has(id),
    kill: (id: string) => live.delete(id),
    forget: (id: string) => live.delete(id),
    treeKilled: () => Promise.resolve(),
  };
}

function manager(root: string, tm = terminalManager()) {
  return {
    tm,
    sessions: new SessionManager({
      projectId: "p", storeDir: root, projectPath: root,
      terminalManager: tm as any,
      agentSpec: { command: "codex", name: "codex", args: ["--model", "gpt-5"] },
      sendMessage: () => {},
    }),
  };
}

afterEach(() => {
  for (const path of stores.splice(0)) rmSync(path, { recursive: true, force: true });
});

describe("approval policy registry", () => {
  test("every agent explicitly declares policy support", () => {
    for (const spec of Object.values(AGENTS)) expect(spec).toHaveProperty("approvalPolicies");
  });

  test("resolver copies argv and rejects unsupported modes", () => {
    const first = resolveApprovalPolicy("codex", "terminal", "bypass");
    expect(first).toEqual(["--dangerously-bypass-approvals-and-sandbox"]);
    first.push("mutated");
    expect(resolveApprovalPolicy("codex", "terminal", "bypass")).toEqual([
      "--dangerously-bypass-approvals-and-sandbox",
    ]);
    expect(() => resolveApprovalPolicy("cursor-agent", "chat", "bypass")).toThrow();
    expect(() => resolveApprovalPolicy("opencode", "terminal", "bypass")).toThrow();
  });
});

describe("terminal approval policy", () => {
  test("places bypass argv after registry defaults and before raw user args", () => {
    const root = store();
    const { sessions, tm } = manager(root);
    const entry = sessions.create("unsafe", {
      tool: "codex", args: "--profile fast", approvalPolicy: "bypass",
    });
    sessions.start(entry.id);
    const command: string = tm.spawns[0].command;
    expect(command.indexOf("--dangerously-bypass-approvals-and-sandbox"))
      .toBeLessThan(command.indexOf("--profile fast"));
  });

  test("default antgrid.yaml agents receive the policy and persist it across reload", () => {
    const root = store();
    const first = manager(root);
    const entry = first.sessions.create("unsafe", { approvalPolicy: "bypass" });
    first.sessions.start(entry.id);
    expect(first.tm.spawns[0].args).toEqual([
      "--model", "gpt-5", "--dangerously-bypass-approvals-and-sandbox",
    ]);
    first.sessions.flushNow();

    const second = manager(root);
    expect(second.sessions.get(entry.id)?.approvalPolicy).toBe("bypass");
    const disk = JSON.parse(readFileSync(join(root, "agents", "p", "sessions.json"), "utf8"));
    expect(disk.sessions[0].approvalPolicy).toBe("bypass");
  });

  test("old rows backfill default and forged unsupported requests fail closed", () => {
    const root = store();
    const { sessions } = manager(root);
    expect(sessions.create().approvalPolicy).toBe("default");
    expect(() => sessions.create("custom", { command: "my-agent", approvalPolicy: "bypass" }))
      .toThrow("Custom-command sessions");
    expect(() => sessions.create("open", { tool: "opencode", approvalPolicy: "bypass" }))
      .toThrow("does not support bypass");
  });
});
