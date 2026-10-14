// Who a scheduler call is FROM: the binding of a claimed slot and run id to a
// live session, the identity resolved from that session, and the persisted
// marker that makes a scheduler-launched session read-only for good.
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager, type ScheduledSessionSpec } from "../src/session-manager";
import { resolveSchedulerCaller, type SchedulerCallerDeps } from "../src/scheduler-caller";
import { SchedulerRefusal } from "../src/scheduler/agent";
import { agentSpec } from "antgrid-agents/builtins";
import type { SessionEntry } from "../src/protocol";

function row(over: Partial<SessionEntry> = {}): SessionEntry {
  return {
    id: "s1", name: "Session 1", createdAt: 1, lastUsedAt: 1, archived: false, running: true,
    mode: "terminal", approvalPolicy: "default", checkoutId: "main",
    ...over,
  } as SessionEntry;
}

function deps(entries: SessionEntry[], over: Partial<SchedulerCallerDeps> = {}): SchedulerCallerDeps {
  return {
    session: (id) => entries.find((e) => e.id === id),
    isLiveRun: (id, runId) => runId === `run-${id}`,
    launchedBySchedule: () => false,
    runAgent: () => "claude-code",
    registryAgent: (name) => agentSpec(name),
    ...over,
  };
}

function refusalOf(fn: () => unknown): SchedulerRefusal {
  try {
    fn();
  } catch (error) {
    if (error instanceof SchedulerRefusal) return error;
    throw error;
  }
  throw new Error("expected a SchedulerRefusal");
}

describe("resolveSchedulerCaller binding", () => {
  it("refuses a call that names no slot or no run id", () => {
    const d = deps([row()]);
    expect(refusalOf(() => resolveSchedulerCaller(d, undefined, "run-s1")).code).toBe("NOT_A_SESSION");
    expect(refusalOf(() => resolveSchedulerCaller(d, "s1", undefined)).code).toBe("NOT_A_SESSION");
    expect(refusalOf(() => resolveSchedulerCaller(d, "s1", "")).code).toBe("NOT_A_SESSION");
    expect(refusalOf(() => resolveSchedulerCaller(d, "", "run-s1")).code).toBe("NOT_A_SESSION");
  });

  it("refuses an unknown slot, a wrong run id and an archived session", () => {
    const d = deps([row(), row({ id: "gone", archived: true })]);
    expect(refusalOf(() => resolveSchedulerCaller(d, "nobody", "run-nobody")).code).toBe("NOT_A_SESSION");
    expect(refusalOf(() => resolveSchedulerCaller(d, "s1", "run-other")).code).toBe("NOT_A_SESSION");
    expect(refusalOf(() => resolveSchedulerCaller(d, "gone", "run-gone")).code).toBe("NOT_A_SESSION");
  });

  it("tells the agent how to recover, in the bridge's own words", () => {
    const refusal = refusalOf(() => resolveSchedulerCaller(deps([row()]), "s1", undefined));
    expect(refusal.message).toBe(
      "This session's Antgrid MCP server did not pass a valid run id. Restart the session; if this persists, re-run the Antgrid project setup.",
    );
  });
});

describe("resolveSchedulerCaller identity", () => {
  const call = (entry: SessionEntry, over: Partial<SchedulerCallerDeps> = {}) =>
    resolveSchedulerCaller(deps([entry], over), entry.id, `run-${entry.id}`);

  it("carries the session's own id, name and mode", () => {
    const caller = call(row({ name: "Refactor auth", tool: "claude-code", mode: "chat" }));
    expect(caller).toMatchObject({ sessionId: "s1", sessionName: "Refactor auth", mode: "chat" });
  });

  it("names the agent the bound run was launched as, not anything the entry or config says now", () => {
    const asked: [string, string][] = [];
    const caller = call(row({ tool: undefined, checkoutId: "wt-1" }), {
      runAgent: (id, runId) => { asked.push([id, runId]); return "codex"; },
    });
    expect(asked).toEqual([["s1", "run-s1"]]);
    expect(caller.agentId).toBe("codex");
  });

  it("has no agent for a custom command or a spec outside the registry", () => {
    expect(call(row({ command: "my-agent --flag" })).agentId).toBeUndefined();
    expect(call(row(), { runAgent: () => "bash" }).agentId).toBeUndefined();
    expect(call(row(), { runAgent: () => "agent" }).agentId).toBeUndefined();
    expect(call(row(), { runAgent: () => undefined }).agentId).toBeUndefined();
  });

  it("marks a session the scheduler launched", () => {
    expect(call(row(), { launchedBySchedule: () => true }).scheduled).toBe(true);
    expect(call(row()).scheduled).toBe(false);
  });

  describe("approval level", () => {
    it("is gated where the agent's default prompts, and for bypass-free claude and codex", () => {
      expect(call(row(), { runAgent: () => "claude-code" }).approvalLevel).toBe("gated");
      expect(call(row(), { runAgent: () => "codex" }).approvalLevel).toBe("gated");
    });

    it("is ungated for an agent whose default allows tools", () => {
      expect(call(row(), { runAgent: () => "opencode" }).approvalLevel).toBe("ungated");
    });

    it("is ungated under a bypass policy, whatever the agent", () => {
      expect(call(row({ approvalPolicy: "bypass" })).approvalLevel).toBe("ungated");
    });

    it("is gated with no evidence: custom command, shell tool, unregistered agent", () => {
      expect(call(row({ command: "my-agent" })).approvalLevel).toBe("gated");
      expect(call(row(), { runAgent: () => "bash" }).approvalLevel).toBe("gated");
      expect(call(row({ command: "opencode" }), { runAgent: () => "opencode" }).approvalLevel).toBe("gated");
      expect(call(row(), { runAgent: () => "opencode", registryAgent: () => undefined }).approvalLevel).toBe("gated");
      // A third-party adapter that never said, as opposed to one that said false.
      expect(call(row(), { runAgent: () => "opencode", registryAgent: () => ({}) }).approvalLevel).toBe("gated");
    });
  });
});

describe("SessionManager scheduler markers", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-sched-caller-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  function makeTerm() {
    const live = new Set<string>();
    return {
      spawn: (cfg: { terminalId?: string }) => { live.add(cfg.terminalId!); return cfg.terminalId!; },
      kill: (id: string) => { live.delete(id); },
      forget: (id: string) => { live.delete(id); },
      treeKilled: () => Promise.resolve(),
      has: (id: string) => live.has(id),
      getScrollback: () => null,
    };
  }

  function manager() {
    return new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
      onStartChat: () => {},
    });
  }

  const sessionsFile = () => join(dir, "agents", "p1", "sessions.json");

  function seed(rows: Record<string, unknown>[]) {
    mkdirSync(join(dir, "agents", "p1"), { recursive: true });
    writeFileSync(sessionsFile(), JSON.stringify({ version: 1, sessions: rows }));
  }

  const scheduledSpec: ScheduledSessionSpec = {
    scheduleId: "nightly", name: "Nightly", agentId: "claude-code", mode: "terminal",
    approvalPolicy: "default", workspace: "shared",
  };

  describe("isLiveRun", () => {
    it("is true only for the live run of a live session", () => {
      const sm = manager();
      const s = sm.create("work", { tool: "claude-code" });
      expect(sm.isLiveRun(s.id, "anything")).toBe(false);
      sm.start(s.id);
      const runId = sm.hookRunId(s.id)!;
      expect(runId).toBeString();
      expect(sm.isLiveRun(s.id, runId)).toBe(true);
      expect(sm.isLiveRun(s.id, "stale-run")).toBe(false);
      expect(sm.isLiveRun(s.id, "")).toBe(false);
      expect(sm.isLiveRun("no-such-session", runId)).toBe(false);
    });

    it("is false for a stopped session, whose run id is gone", async () => {
      const sm = manager();
      const s = sm.create("work", { tool: "claude-code" });
      sm.start(s.id);
      const runId = sm.hookRunId(s.id)!;
      await sm.stop(s.id);
      expect(sm.isLiveRun(s.id, runId)).toBe(false);
      expect(sm.isLiveRun(s.id, "")).toBe(false);
    });

    it("answers without touching the hook channel", () => {
      const sm = manager();
      const s = sm.create("work", { tool: "claude-code" });
      sm.start(s.id);
      const before = sm.handlerAvailability(s.id);
      const observation = sm.terminalObservation(s.id);
      // The calls `acceptsHookRun`'s wrapper makes for an absent run id.
      sm.isLiveRun(s.id, "");
      sm.isLiveRun(s.id, "wrong");
      expect(sm.handlerAvailability(s.id)).toEqual(before);
      expect(sm.terminalObservation(s.id)).toEqual(observation);
    });
  });

  describe("liveRunAgent", () => {
    it("is the tool a session overrode the project with", () => {
      const sm = manager();
      const s = sm.create("work", { tool: "opencode" });
      sm.start(s.id);
      expect(sm.liveRunAgent(s.id, sm.hookRunId(s.id)!)).toBe("opencode");
    });

    it("is the default chat agent for a chat entry without a tool", async () => {
      const sm = manager();
      const s = sm.create("chat", { mode: "chat" });
      await sm.start(s.id);
      expect(sm.liveRunAgent(s.id, sm.hookRunId(s.id)!)).toBe("codex");
    });

    it("stays the agent the run launched as when the configured spec changes under it", async () => {
      const sm = manager();
      const s = sm.create("work", {});
      sm.start(s.id);
      const runId = sm.hookRunId(s.id)!;
      expect(sm.liveRunAgent(s.id, runId)).toBe("claude-code");
      // What a reloaded antgrid.yaml naming another tool does to the manager.
      sm.setAgentSpec({ command: "opencode", name: "opencode" });
      expect(sm.liveRunAgent(s.id, runId)).toBe("claude-code");

      await sm.stop(s.id);
      expect(sm.liveRunAgent(s.id, runId)).toBeUndefined();
      sm.start(s.id);
      expect(sm.liveRunAgent(s.id, sm.hookRunId(s.id)!)).toBe("opencode");
    });

    it("answers nothing for a wrong run id or an unknown session", () => {
      const sm = manager();
      const s = sm.create("work", { tool: "claude-code" });
      sm.start(s.id);
      expect(sm.liveRunAgent(s.id, "stale")).toBeUndefined();
      expect(sm.liveRunAgent(s.id, "")).toBeUndefined();
      expect(sm.liveRunAgent("nobody", sm.hookRunId(s.id)!)).toBeUndefined();
    });

    // The caller a gated claude run is seen as, after its antgrid.yaml was
    // edited to an agent whose default is ungated: still claude, still gated.
    it("keeps a running gated session gated through the caller resolver", () => {
      const sm = manager();
      const s = sm.create("work", {});
      sm.start(s.id);
      const runId = sm.hookRunId(s.id)!;
      sm.setAgentSpec({ command: "opencode", name: "opencode" });
      const caller = resolveSchedulerCaller({
        session: (id) => sm.get(id),
        isLiveRun: (id, r) => sm.isLiveRun(id, r),
        launchedBySchedule: (id) => sm.launchedBySchedule(id),
        runAgent: (id, r) => sm.liveRunAgent(id, r),
        registryAgent: (name) => agentSpec(name),
      }, s.id, runId);
      expect(caller.agentId).toBe("claude-code");
      expect(caller.approvalLevel).toBe("gated");
    });
  });

  describe("launchedByScheduleId", () => {
    it("is set on a session the scheduler prepares, and on nothing else", async () => {
      const sm = manager();
      const plain = sm.create("by hand", { tool: "claude-code" });
      const prepared = await sm.prepareScheduledSession(scheduledSpec, async () => {});
      expect(sm.launchedBySchedule(prepared.sessionId)).toBe(true);
      expect(sm.launchedBySchedule(plain.id)).toBe(false);
      expect(sm.launchedBySchedule("no-such-session")).toBe(false);
    });

    it("is written before the first flush, so a restart still knows", async () => {
      const sm = manager();
      const prepared = await sm.prepareScheduledSession(scheduledSpec, async () => {});
      sm.flushNow();
      const onDisk = JSON.parse(readFileSync(sessionsFile(), "utf8")).sessions;
      expect(onDisk.find((e: any) => e.id === prepared.sessionId).launchedByScheduleId).toBe("nightly");
      expect(manager().launchedBySchedule(prepared.sessionId)).toBe(true);
    });

    it("reads a damaged marker as scheduled, never as absent", () => {
      seed([
        { id: "num", name: "n", archived: false, launchedByScheduleId: 42 },
        { id: "nul", name: "n", archived: false, launchedByScheduleId: null },
        { id: "empty", name: "n", archived: false, launchedByScheduleId: "" },
        { id: "obj", name: "n", archived: false, launchedByScheduleId: { id: "x" } },
        { id: "ok", name: "n", archived: false, launchedByScheduleId: "nightly" },
        { id: "none", name: "n", archived: false },
      ]);
      const sm = manager();
      for (const id of ["num", "nul", "empty", "obj", "ok"]) expect(sm.launchedBySchedule(id)).toBe(true);
      expect(sm.launchedBySchedule("none")).toBe(false);
    });

    it("is not inherited by a fork, which is a session the user made", async () => {
      seed([{ id: "src", name: "Nightly", archived: false, tool: "claude-code", launchedByScheduleId: "nightly" }]);
      const sm = manager();
      sm.setAgentSession("src", "native-1");
      const forked = await sm.fork("src", "current");
      expect(sm.launchedBySchedule("src")).toBe(true);
      expect(sm.launchedBySchedule(forked.id)).toBe(false);
    });
  });

  describe("a scheduled chat entry", () => {
    const chatSpec: ScheduledSessionSpec = { ...scheduledSpec, agentId: "claude-code", mode: "chat" };

    function configOf(sm: SessionManager, id: string): Record<string, string> | undefined {
      sm.flushNow();
      return JSON.parse(readFileSync(sessionsFile(), "utf8")).sessions.find((e: any) => e.id === id).config;
    }

    it("keeps the last-used model and effort but never the permission mode", async () => {
      const sm = manager();
      const earlier = sm.create("chat", { tool: "claude-code", mode: "chat" });
      sm.setSessionConfig(earlier.id, "model", "sonnet");
      sm.setSessionConfig(earlier.id, "effort", "high");
      sm.setSessionConfig(earlier.id, "mode", "acceptEdits");

      const prepared = await sm.prepareScheduledSession(chatSpec, async () => {});
      expect(configOf(sm, prepared.sessionId)).toEqual({ model: "sonnet", effort: "high" });
    });

    it("carries no config at all when mode was the only thing inherited", async () => {
      const sm = manager();
      const earlier = sm.create("chat", { tool: "claude-code", mode: "chat" });
      sm.setSessionConfig(earlier.id, "mode", "auto");
      const prepared = await sm.prepareScheduledSession(chatSpec, async () => {});
      expect(configOf(sm, prepared.sessionId)).toBeUndefined();
    });

    it("still lets a chat the user opens inherit the mode they last picked", () => {
      const sm = manager();
      const earlier = sm.create("chat", { tool: "claude-code", mode: "chat" });
      sm.setSessionConfig(earlier.id, "mode", "acceptEdits");
      const next = sm.create("next", { tool: "claude-code", mode: "chat" });
      expect(configOf(sm, next.id)).toEqual({ mode: "acceptEdits" });
    });
  });
});
