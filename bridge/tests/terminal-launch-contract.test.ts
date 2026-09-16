import { afterEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import { AGENTS } from "../../packages/antgrid-agents/src/agents/registry";
import { prepareTerminalLaunch, type PreparedTerminalLaunch } from "../../packages/antgrid-agents/src/agents/terminal-launch";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import { agentHostServices, agentRuntime } from "../src/agent-host";
import type { AgentSpec } from "antgrid-agents/contracts";
import { createAgentRunScope } from "antgrid-agents/contracts";

const dirs: string[] = [];
let prepare: AgentSpec["prepareTerminal"];
afterEach(() => {
  prepare = undefined;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-launch-contract-"));
  dirs.push(dir);
  const running = new Set<string>();
  const launches: any[] = [];
  const file = join(dir, "agents", "p", "sessions.json");
  let onSpawn = (_cfg: any) => {};
  const tm = {
    spawn: (cfg: any) => { onSpawn(cfg); launches.push(cfg); running.add(cfg.terminalId); },
    has: (id: string) => running.has(id),
    kill: (id: string) => { running.delete(id); },
    treeKilled: () => Promise.resolve(),
    getScrollback: () => null,
  };
  const createManager = () => new SessionManager({
    agentRuntime: createAgentRuntime({ host: agentHostServices, registry: createAgentRegistry([["claude-code", {
      apiVersion: 1, hookName: "claude", create: () => ({ ...AGENTS["claude-code"], prepareTerminal: (request) => prepare ? prepare(request) : agentRuntime.prepareTerminal(request) }),
    }]]) }),
    projectId: "p", storeDir: dir, projectPath: dir, terminalManager: tm as any,
    agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
  });
  const sm = createManager();
  return { dir, file, sm, createManager, launches, onSpawn: (callback: typeof onSpawn) => { onSpawn = callback; } };
}

describe("terminal adapter launch contract", () => {
  it("preserves replacement hooks and preparation when spawn reports the old run exit", async () => {
    const f = fixture();
    const disposed: number[] = [];
    let generation = 0;
    let signal!: AbortSignal;
    const observation = { notifications: true, titles: true, handler: true, turnStart: false, turnEnd: true, hookAlive: true };
    prepare = (request) => {
      const current = ++generation;
      signal = request.signal;
      return { command: "owned-runtime", invocationKind: "exec", args: [], env: {}, resumed: false,
        promptDelivery: "none", observation, dispose: () => { disposed.push(current); } };
    };
    const entry = f.sm.create("restart", { tool: "claude-code" });
    await f.sm.start(entry.id);
    const oldRun = f.sm.hookRunId(entry.id)!;
    await f.sm.stop(entry.id);
    f.onSpawn(() => f.sm.noteExited(entry.id, oldRun));
    await f.sm.start(entry.id);
    const newRun = f.launches[1].env.ANTGRID_RUN_ID;
    expect(f.sm.acceptsHookRun(entry.id, newRun)).toBe(true);
    expect(f.sm.acceptsHookRun(entry.id, oldRun)).toBe(false);
    expect(signal.aborted).toBe(false);
    expect(disposed).toEqual([1]);
    expect(f.sm.terminalObservation(entry.id)).toEqual(observation);
    f.sm.confirmHookRun(entry.id, newRun);
    expect(f.sm.handlerAvailability(entry.id).state).toBe("available");
    f.sm.noteExited(entry.id, newRun);
    await Promise.resolve();
    expect(disposed).toEqual([1, 2]);
    expect(f.sm.acceptsHookRun(entry.id, newRun)).toBe(false);
    f.sm.flushNow();
  });

  it("reports unsupported prompt delivery and disposes preparation without dispatch", async () => {
    const f = fixture();
    let disposed = 0;
    prepare = () => ({
      command: "unused", invocationKind: "exec", args: [], env: {}, resumed: false,
      promptDelivery: "unsupported", dispose: async () => { disposed++; },
    });
    const entry = f.sm.create(undefined, { tool: "claude-code" });
    await expect(Promise.resolve().then(() => f.sm.start(entry.id, "retain this prompt"))).rejects.toThrow("cannot accept an opening prompt");
    expect(disposed).toBe(1);
    expect(f.launches).toHaveLength(0);
  });

  it("rejects an unknown adapter instead of falling back to the configured executable", () => {
    expect(() => prepareTerminalLaunch({
      tool: "missing-adapter", configured: { name: "claude-code", command: "claude" },
      conversation: { kind: "fresh" }, approvalPolicy: "default", storeDir: "unused", cwd: "unused",
      signal: new AbortController().signal,
      scope: createAgentRunScope({ runId: "test", isCurrent: () => true, emit: () => {} }),
    })).toThrow("unknown agent");
  });

  it("archive followed by unarchive cannot revive a cancelled preparation", async () => {
    const f = fixture();
    let release!: (launch: PreparedTerminalLaunch) => void;
    prepare = () => new Promise((resolve) => { release = resolve; });
    const entry = f.sm.create("archive", { tool: "claude-code" });
    const started = (f.sm.start(entry.id) as Promise<void>).catch((error) => error);
    f.sm.archive(entry.id);
    f.sm.unarchive(entry.id);
    release({ command: "never", invocationKind: "exec", args: [], env: {}, resumed: false, promptDelivery: "none" });
    expect((await started).message).toContain("cancelled");
    expect(f.launches).toHaveLength(0);
    f.sm.flushNow();
  });

  it("mode switching waits for an in-flight terminal preparation before assigning its new run", async () => {
    const f = fixture();
    let release!: (launch: PreparedTerminalLaunch) => void;
    prepare = () => new Promise((resolve) => { release = resolve; });
    const entry = f.sm.create("mode", { tool: "claude-code" });
    const started = (f.sm.start(entry.id) as Promise<void>).catch((error) => error);
    const oldRun = f.sm.hookRunId(entry.id);
    const changed = f.sm.setMode(entry.id, "chat");
    release({ command: "never", invocationKind: "exec", args: [], env: {}, resumed: false, promptDelivery: "none" });
    await changed;
    expect((await started).message).toContain("cancelled");
    expect(f.launches).toHaveLength(0);
    expect(f.sm.hookRunId(entry.id)).toBeDefined();
    expect(f.sm.hookRunId(entry.id)).not.toBe(oldRun);
    f.sm.flushNow();
  });

  it("reports installation separately from confirmed monitoring and ignores stale confirmations", async () => {
    const f = fixture();
    const observation = { notifications: true, titles: true, handler: true, turnStart: false, turnEnd: true, hookAlive: true };
    prepare = () => ({ command: "owned-runtime", invocationKind: "exec", args: [], env: {}, resumed: false, promptDelivery: "none", observation });
    const entry = f.sm.create("availability", { tool: "claude-code" });
    await f.sm.start(entry.id);
    const run = f.sm.hookRunId(entry.id)!;
    expect(f.sm.handlerAvailability(entry.id).state).toBe("unknown");
    f.sm.confirmHookRun(entry.id, "stale");
    expect(f.sm.handlerAvailability(entry.id).state).toBe("unknown");
    f.sm.confirmHookRun(entry.id, run);
    expect(f.sm.handlerAvailability(entry.id).state).toBe("available");
    f.sm.invalidateHookObservation(entry.id);
    expect(f.sm.handlerAvailability(entry.id).state).toBe("unavailable");
    await f.sm.stop(entry.id);
    f.sm.confirmHookRun(entry.id, run);
    expect(f.sm.handlerAvailability(entry.id).state).toBe("unavailable");
    f.sm.flushNow();
  });
  it("waits for adapter resource disposal before preparing a restart", async () => {
    const f = fixture();
    let release!: () => void;
    let prepared = 0;
    prepare = () => {
      prepared++;
      return {
        command: "owned-runtime", invocationKind: "exec", args: [], env: {}, resumed: false, promptDelivery: "none",
        dispose: prepared === 1 ? () => new Promise<void>((resolve) => { release = resolve; }) : undefined,
      };
    };
    const entry = f.sm.create("restart", { tool: "claude-code" });
    await f.sm.start(entry.id);
    const previousRun = f.sm.hookRunId(entry.id)!;
    expect(f.sm.acceptsHookRun(entry.id, previousRun)).toBe(true);
    const stopped = f.sm.stop(entry.id);
    expect(f.sm.acceptsHookRun(entry.id, previousRun)).toBe(false);
    const restarted = f.sm.start(entry.id);
    await Promise.resolve();
    expect(prepared).toBe(1);
    release();
    await stopped;
    await restarted;
    expect(prepared).toBe(2);
    expect(f.launches).toHaveLength(2);
    expect(f.sm.hookRunId(entry.id)).not.toBe(previousRun);
    expect(f.sm.acceptsHookRun(entry.id, previousRun)).toBe(false);
    f.sm.flushNow();
  });

  it("awaits an entirely different invocation and keeps cwd host-owned", async () => {
    const f = fixture();
    let release!: (launch: PreparedTerminalLaunch) => void;
    prepare = (request) => {
      expect(Object.isFrozen(request)).toBe(true);
      expect(request.cwd).toBe(f.dir);
      return new Promise((resolve) => { release = resolve; });
    };
    const entry = f.sm.create("alternate", { tool: "claude-code" });
    const started = f.sm.start(entry.id);
    const duplicate = f.sm.start(entry.id);
    expect(f.launches).toHaveLength(0);
    release({ command: "runtime-host", invocationKind: "exec", args: ["serve", "--pipe"], env: { MODE: "rpc" }, resumed: false, promptDelivery: "included" });
    await Promise.all([started, duplicate]);
    expect(f.launches).toHaveLength(1);
    expect(f.launches[0]).toMatchObject({ command: "runtime-host", invocationKind: "exec", args: ["serve", "--pipe"], cwd: f.dir, env: { MODE: "rpc" } });
    f.sm.flushNow();
  });

  it("stop during preparation aborts the request and disposes a late result", async () => {
    const f = fixture();
    let release!: (launch: PreparedTerminalLaunch) => void;
    let signal!: AbortSignal;
    let disposed = 0;
    prepare = (request) => {
      signal = request.signal;
      return new Promise((resolve) => { release = resolve; });
    };
    const entry = f.sm.create("cancel", { tool: "claude-code" });
    const started = f.sm.start(entry.id) as Promise<void>;
    const rejected = started.catch((error) => error);
    f.sm.stop(entry.id);
    expect(signal.aborted).toBe(true);
    release({ command: "never", invocationKind: "exec", args: [], env: {}, resumed: false, promptDelivery: "none", dispose: () => { disposed++; } });
    expect((await rejected).message).toContain("cancelled");
    expect(f.launches).toHaveLength(0);
    expect(disposed).toBe(1);
    f.sm.flushNow();
  });
});

describe("native fork durable intent", () => {
  it("does not dispatch when its attempted marker cannot be persisted", async () => {
    const f = fixture();
    const source = f.sm.create("source", { tool: "claude-code" });
    f.sm.setAgentSession(source.id, "source");
    const fork = await f.sm.fork(source.id, "current");
    rmSync(f.file);
    mkdirSync(f.file);
    expect(() => f.sm.start(fork.id)).toThrow();
    expect(f.launches).toHaveLength(0);
    rmSync(f.file, { recursive: true });
    await f.sm.start(fork.id);
    expect(f.launches).toHaveLength(1);
    f.sm.flushNow();
  });

  it("retains an uncertain attempted fork after dispatch throws and the bridge reloads", async () => {
    const f = fixture();
    const source = f.sm.create("source", { tool: "claude-code" });
    f.sm.setAgentSession(source.id, "source");
    const fork = await f.sm.fork(source.id, "current");
    f.onSpawn(() => { throw new Error("dispatch failed"); });
    expect(() => f.sm.start(fork.id)).toThrow("dispatch failed");
    f.sm.flushNow();
    const reloaded = f.createManager();
    expect(() => reloaded.start(fork.id)).toThrow("outcome is unknown");
    expect(f.launches).toHaveLength(0);
    reloaded.flushNow();
  });

  it("captures source identity and commits attempted before dispatch, then resumes only the new identity", async () => {
    const f = fixture();
    const source = f.sm.create("source", { tool: "claude-code" });
    f.sm.setAgentSession(source.id, "source-before");
    const fork = await f.sm.fork(source.id, "current");
    f.sm.setAgentSession(source.id, "source-after");
    f.onSpawn(() => {
      const row = JSON.parse(readFileSync(f.file, "utf8")).sessions.find((s: any) => s.id === fork.id);
      expect(row.forkSourceSessionId).toBe("source-before");
      expect(row.forkNativeAttempted).toBe(true);
      expect(row.forkNativeArgs).toBeUndefined();
    });
    await f.sm.start(fork.id);
    expect(f.launches[0].args).toContain("source-before");
    expect(f.sm.setAgentSession(fork.id, "source-before")).toBe(false);
    f.sm.stop(fork.id);
    expect(() => f.sm.start(fork.id)).toThrow("outcome is unknown");
    f.sm.setAgentSession(fork.id, "fork-result");
    f.onSpawn(() => {});
    await f.sm.start(fork.id);
    expect(f.launches[1].args).toContain("fork-result");
    expect(f.launches[1].args).not.toContain("--fork-session");
    f.sm.flushNow();
  });

  it("migrates exact old argv but refuses unknown old syntax", async () => {
    const f = fixture();
    const source = f.sm.create("source", { tool: "claude-code" });
    f.sm.setAgentSession(source.id, "source");
    const fork = await f.sm.fork(source.id, "current");
    f.sm.flushNow();
    const data = JSON.parse(readFileSync(f.file, "utf8"));
    const row = data.sessions.find((s: any) => s.id === fork.id);
    delete row.forkSourceSessionId;
    row.forkNativeArgs = ["--resume", "captured-old", "--fork-session"];
    writeFileSync(f.file, JSON.stringify(data));
    const migrated = f.createManager();
    await migrated.start(fork.id);
    expect(f.launches[0].args).toContain("captured-old");
    migrated.stop(fork.id);
    migrated.flushNow();
    row.forkNativeArgs = ["--resume", "captured-old", "--fork-session", "--extra"];
    writeFileSync(f.file, JSON.stringify(data));
    const rejected = f.createManager();
    expect(() => rejected.start(fork.id)).toThrow("cannot be migrated safely");
    rejected.flushNow();
  });
});
