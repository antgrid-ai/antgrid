import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import { agentRuntime } from "../src/agent-runtime";
import type { PreparedTerminalLaunch, TerminalLaunchRequest } from "antgrid-agents/contracts";

const managers: SessionManager[] = [];
const directories: string[] = [];
afterEach(() => {
  for (const manager of managers.splice(0)) manager.flushNow();
  for (const path of directories.splice(0)) rmSync(path, { recursive: true, force: true });
});

function fixture(options: { failFork?: boolean; failSpawn?: boolean; gate?: Promise<void>; returnedId?: string } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "antgrid-native-fork-"));
  directories.push(directory);
  const path = join(directory, "agents", "project", "sessions.json");
  const rows = (): any[] => JSON.parse(readFileSync(path, "utf8")).sessions;
  const spawns: any[] = [];
  const live = new Set<string>();
  let forks = 0;
  const launch = (nativeId: string): PreparedTerminalLaunch => ({
    command: "kimi", args: ["--session", nativeId], env: {}, invocationKind: "exec", resumed: true, promptDelivery: "none",
  });
  const runtime = {
    ...agentRuntime,
    prepareTerminal: async (request: TerminalLaunchRequest): Promise<PreparedTerminalLaunch> => {
      if (request.conversation.kind === "resume") return launch(request.conversation.sessionId);
      expect(request.conversation.kind).toBe("fork");
      return { ...launch("source"), resumed: false, createNativeFork: async () => {
        forks++;
        const fork = rows().find(row => row.forkSourceSessionId === "source");
        expect(fork.forkNativeAttempted).toBe(true);
        await options.gate;
        if (options.failFork) throw new Error("fork failed");
        return { nativeId: options.returnedId ?? "child", launch: launch(options.returnedId ?? "child") };
      } };
    },
  };
  const terminal = {
    has: (id: string) => live.has(id), kill: (id: string) => live.delete(id),
    forget: (id: string) => live.delete(id), treeKilled: async () => {},
    spawn: (config: any) => {
      expect(rows().find(row => row.id === config.terminalId)?.agentSessionId).toBe("child");
      if (options.failSpawn) throw new Error("spawn failed");
      spawns.push(config); live.add(config.terminalId); return config.terminalId;
    },
  };
  const makeManager = () => {
    const manager = new SessionManager({ projectId: "project", projectPath: directory, storeDir: directory,
      agentSpec: { name: "kimi", command: "kimi" }, terminalManager: terminal as any, agentRuntime: runtime, sendMessage() {} });
    managers.push(manager);
    return manager;
  };
  return { manager: makeManager(), makeManager, rows, spawns, forks: () => forks, options };
}

test("native fork attempt and returned identity are durable before provider mutation and PTY launch", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "kimi" });
  f.manager.setAgentSession(source.id, "source");
  const fork = await f.manager.fork(source.id, "current");
  await f.manager.start(fork.id);
  expect(f.spawns[0].args).toEqual(["--session", "child"]);
  expect(f.rows().find(row => row.id === source.id).agentSessionId).toBe("source");
  expect(f.rows().find(row => row.id === fork.id).forkSourceSessionId).toBeUndefined();
});

test("failed native fork cannot repeat after reload", async () => {
  const f = fixture({ failFork: true });
  const source = f.manager.create("Source", { tool: "kimi" });
  f.manager.setAgentSession(source.id, "source");
  const fork = await f.manager.fork(source.id, "current");
  await expect(Promise.resolve().then(() => f.manager.start(fork.id))).rejects.toThrow("fork failed");
  const reloaded = f.makeManager();
  await expect(Promise.resolve().then(() => reloaded.start(fork.id))).rejects.toThrow("outcome is unknown");
  expect(f.forks()).toBe(1);
  expect(f.spawns).toHaveLength(0);
});

test("PTY failure retries the persisted native fork through resume", async () => {
  const f = fixture({ failSpawn: true });
  const source = f.manager.create("Source", { tool: "kimi" });
  f.manager.setAgentSession(source.id, "source");
  const fork = await f.manager.fork(source.id, "current");
  await expect(Promise.resolve().then(() => f.manager.start(fork.id))).rejects.toThrow("spawn failed");
  f.options.failSpawn = false;
  await f.makeManager().start(fork.id);
  expect(f.forks()).toBe(1);
  expect(f.spawns[0].args).toEqual(["--session", "child"]);
});

test("source identity cannot be returned as a native fork", async () => {
  const f = fixture({ returnedId: "source" });
  const source = f.manager.create("Source", { tool: "kimi" });
  f.manager.setAgentSession(source.id, "source");
  const fork = await f.manager.fork(source.id, "current");
  await expect(Promise.resolve().then(() => f.manager.start(fork.id))).rejects.toThrow("independent resumable fork");
  expect(f.spawns).toHaveLength(0);
});

test("stopping during native fork prevents a late PTY launch and preserves the uncertain attempt", async () => {
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const f = fixture({ gate });
  const source = f.manager.create("Source", { tool: "kimi" });
  f.manager.setAgentSession(source.id, "source");
  const fork = await f.manager.fork(source.id, "current");
  const starting = Promise.resolve().then(() => f.manager.start(fork.id));
  const result = starting.catch(error => error);
  while (!f.forks()) await new Promise(resolve => setTimeout(resolve, 1));
  const stopping = f.manager.stop(fork.id);
  release();
  expect((await result).message).toContain("cancelled");
  await stopping;
  expect(f.spawns).toHaveLength(0);
  expect(f.rows().find(row => row.id === fork.id).forkNativeAttempted).toBe(true);
});

test("a Kimi fork into a new worktree takes the transcript handoff, and only a fork in place forks natively", async () => {
  const directory = mkdtempSync(join(tmpdir(), "antgrid-native-fork-"));
  directories.push(directory);
  const worktreeManager = {
    prepareForSession: async (args: { sessionId: string }) => ({
      id: "checkout-1", projectId: "project", kind: "managed-worktree", path: join(directory, "wt"),
      branch: "antgrid/fork", baseRef: "main", managed: true, sessionId: args.sessionId, createdAt: 1,
    }),
    rollbackPrepared: async () => {},
  };
  const terminal = {
    has: () => false, kill() {}, forget() {}, treeKilled: async () => {}, spawn: (config: any) => config.terminalId,
    getScrollback: () => ({ text: "fix the parser", seq: 1 }),
  };
  const head = spyOn(SessionManager.prototype as any, "committedHead").mockResolvedValue("a".repeat(40));
  try {
    const manager = new SessionManager({ projectId: "project", projectPath: directory, storeDir: directory,
      agentSpec: { name: "kimi", command: "kimi" }, terminalManager: terminal as any, sendMessage() {},
      worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: worktreeManager as any,
      resolveAgentSpec: async () => ({ name: "kimi", command: "kimi" }) });
    managers.push(manager);
    const source = manager.create("Source", { tool: "kimi" });
    manager.setAgentSession(source.id, "source");
    const rows = (): any[] => JSON.parse(readFileSync(join(directory, "agents", "project", "sessions.json"), "utf8")).sessions;

    const copy = await manager.fork(source.id, "copy");
    const copied = rows().find(row => row.id === copy.id);
    expect(copied.checkoutId).toBe("checkout-1");
    expect(copied.forkSourceSessionId).toBeUndefined();
    expect(copied.forkTranscript).toContain("fix the parser");

    const inPlace = await manager.fork(source.id, "current");
    expect(rows().find(row => row.id === inPlace.id).forkSourceSessionId).toBe("source");
  } finally {
    head.mockRestore();
  }
});
