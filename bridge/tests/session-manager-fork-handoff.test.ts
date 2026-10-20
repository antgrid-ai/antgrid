import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PreparedTerminalLaunch } from "antgrid-agents/contracts";
import { ByteBudget, writeText, type HandoffSnapshot, type HandoffSnapshotOpts } from "antgrid-agents/handoff";
import { agentRuntime } from "../src/agent-runtime";
import { MAX_FORK_TRANSCRIPT_BYTES, SessionManager } from "../src/session-manager";

const managers: SessionManager[] = [];
const directories: string[] = [];
afterEach(() => {
  for (const manager of managers.splice(0)) manager.flushNow();
  for (const path of directories.splice(0)) rmSync(path, { recursive: true, force: true });
});

interface Options {
  handoffFiles?: boolean;
  scrollback?: string | null;
  snapshot?: (opts: HandoffSnapshotOpts) => Promise<HandoffSnapshot | undefined>;
}

async function writingSnapshot(opts: HandoffSnapshotOpts): Promise<HandoffSnapshot> {
  const file = await writeText(opts.outDir, "fixture.jsonl", '{"a":1}\n', "transcript", new ByteBudget());
  return { agent: "kimi", method: "copy", primary: "fixture.jsonl", files: [file], references: [], redactions: [], warnings: [] };
}

function fixture(options: Options = {}) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-fork-handoff-")));
  directories.push(directory);
  const sessionsPath = join(directory, "agents", "project", "sessions.json");
  const rows = (): any[] => JSON.parse(readFileSync(sessionsPath, "utf8")).sessions;
  const snapshots: HandoffSnapshotOpts[] = [];
  const snapshot = options.snapshot ?? writingSnapshot;
  const runtime = {
    ...agentRuntime,
    get: (id: string) => {
      const spec = agentRuntime.get(id);
      if (!spec || id !== "kimi") return spec;
      return { ...spec, fork: { ...spec.fork, snapshot: async (opts: HandoffSnapshotOpts) => { snapshots.push(opts); return snapshot(opts); } } };
    },
    prepareTerminal: async (): Promise<PreparedTerminalLaunch> => ({
      command: "kimi", args: [], env: {}, invocationKind: "exec", resumed: false, promptDelivery: "none",
    }),
  };
  const spawns: any[] = [];
  const live = new Set<string>();
  const scrollback = options.scrollback === undefined ? "fix the parser" : options.scrollback;
  const terminal = {
    has: (id: string) => live.has(id), kill: (id: string) => live.delete(id),
    forget: (id: string) => live.delete(id), treeKilled: async () => {},
    spawn: (config: any) => { spawns.push(config); live.add(config.terminalId); return config.terminalId; },
    getScrollback: () => (scrollback === null ? null : { text: scrollback, seq: 1 }),
  };
  const makeManager = (extra: Record<string, unknown> = {}) => {
    const manager = new SessionManager({
      projectId: "project", projectPath: directory, storeDir: directory,
      agentSpec: { name: "kimi", command: "kimi" }, terminalManager: terminal as any,
      agentRuntime: runtime as any, sendMessage() {}, handoffFiles: options.handoffFiles ?? true,
      ...extra,
    });
    managers.push(manager);
    return manager;
  };
  const staging = (id: string) => join(directory, "agents", "project", "handoff", id);
  const placed = (id: string) => join(directory, ".antgrid", "handoff", id);
  return { directory, manager: makeManager(), makeManager, rows, spawns, snapshots, staging, placed, sessionsPath };
}

function source(f: ReturnType<typeof fixture>) {
  return f.manager.create("Source", { tool: "kimi" });
}

test("a transcript fork stages before any placement and records the staged marker", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  expect(existsSync(join(f.staging(fork.id), "manifest.json"))).toBe(true);
  expect(existsSync(f.placed(fork.id))).toBe(false);
  expect(f.rows().find((row) => row.id === fork.id).forkHandoff).toEqual({ state: "staged", sourceTool: "kimi" });
  expect(f.snapshots[0]!.sourceCwd).toBe(f.directory);
});

test("a staging failure leaves no row and no staging dir", async () => {
  const f = fixture({ snapshot: async () => { throw Object.assign(new Error("disk"), { code: "ENOSPC" }); } });
  const src = source(f);
  await expect(f.manager.fork(src.id, "current")).rejects.toThrow("Could not snapshot the conversation");
  expect(f.manager.list()).toHaveLength(1);
  expect(readdirSync(join(f.directory, "agents", "project", "handoff"))).toEqual([]);
});

test("an over-128 KB fork refuses before staging", async () => {
  const f = fixture({ scrollback: "x".repeat(MAX_FORK_TRANSCRIPT_BYTES + 10) });
  await expect(f.manager.fork(source(f).id, "current")).rejects.toThrow("too large to fork");
  expect(f.snapshots).toHaveLength(0);
  expect(existsSync(join(f.directory, "agents", "project", "handoff"))).toBe(false);
});

test("an empty store and empty scrollback refuses with the existing copy", async () => {
  const f = fixture({ scrollback: null, snapshot: async () => undefined });
  await expect(f.manager.fork(source(f).id, "current")).rejects.toThrow("no captured transcript");
  expect(f.manager.list()).toHaveLength(1);
});

test("launch places the handoff in the checkout and persists the placement", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  await f.manager.start(fork.id);
  expect(readFileSync(join(f.placed(fork.id), "fixture.jsonl"), "utf8")).toBe('{"a":1}\n');
  expect(existsSync(f.staging(fork.id))).toBe(false);
  expect(f.rows().find((row) => row.id === fork.id).forkHandoff).toEqual({ state: "materialized", sourceTool: "kimi", root: f.directory });
  expect(f.spawns).toHaveLength(1);
});

test("two concurrent starts place the handoff once and launch once", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  await Promise.all([
    Promise.resolve().then(() => f.manager.start(fork.id)),
    Promise.resolve().then(() => f.manager.start(fork.id)),
  ]);
  expect(f.spawns).toHaveLength(1);
  expect(existsSync(join(f.placed(fork.id), "manifest.json"))).toBe(true);
});

test("a delete during placement waits for it and leaves no handoff dir", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  const starting = Promise.resolve(f.manager.start(fork.id));
  f.manager.delete(fork.id);
  await starting;
  await f.manager.settleHandoffCleanup();
  expect(existsSync(f.placed(fork.id))).toBe(false);
  expect(existsSync(f.staging(fork.id))).toBe(false);
  expect(f.spawns).toHaveLength(0);
});

test("deleting a placed fork removes its handoff dir and leaves the checkout's other files", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  await f.manager.start(fork.id);
  mkdirSync(join(f.directory, ".antgrid", "keep"), { recursive: true });
  writeFileSync(join(f.directory, ".antgrid", "keep", "note.txt"), "mine");
  writeFileSync(join(f.directory, "work.txt"), "mine");
  f.manager.delete(fork.id);
  await f.manager.settleHandoffCleanup();
  expect(existsSync(f.placed(fork.id))).toBe(false);
  expect(readFileSync(join(f.directory, ".antgrid", "keep", "note.txt"), "utf8")).toBe("mine");
  expect(readFileSync(join(f.directory, "work.txt"), "utf8")).toBe("mine");
});

test("deleting a fork that never launched removes its staging dir", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  f.manager.delete(fork.id);
  await f.manager.settleHandoffCleanup();
  expect(existsSync(f.staging(fork.id))).toBe(false);
});

test("a restart between the fork and the launch still places the handoff", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  f.manager.flushNow();
  const reloaded = f.makeManager();
  await reloaded.start(fork.id);
  expect(existsSync(join(f.placed(fork.id), "manifest.json"))).toBe(true);
  expect(f.rows().find((row) => row.id === fork.id).forkHandoff.state).toBe("materialized");
});

test("a fork row with no handoff, transcript or source refuses to start", async () => {
  const f = fixture();
  const id = "11111111-2222-4333-8444-555555555555";
  mkdirSync(join(f.directory, "agents", "project"), { recursive: true });
  writeFileSync(f.sessionsPath, JSON.stringify({ version: 1, sessions: [
    { id, name: "Lost", archived: false, tool: "kimi", mode: "terminal", conversationStart: "fork" },
  ] }));
  const manager = f.makeManager();
  await expect(Promise.resolve().then(() => manager.start(id))).rejects.toThrow("lost its saved context");
  expect(f.spawns).toHaveLength(0);
});

test("a damaged forkHandoff sub-field survives the persisted round trip", async () => {
  const f = fixture();
  const id = "11111111-2222-4333-8444-555555555555";
  mkdirSync(join(f.directory, "agents", "project"), { recursive: true });
  writeFileSync(f.sessionsPath, JSON.stringify({ version: 1, sessions: [
    { id, name: "Damaged", archived: false, tool: "kimi", mode: "terminal", conversationStart: "fork", forkHandoff: { state: 7, sourceTool: null, root: "/somewhere" } },
    { id: "22222222-2222-4333-8444-555555555555", name: "Garbage", archived: false, tool: "kimi", mode: "terminal", forkHandoff: "nope" },
  ] }));
  const manager = f.makeManager();
  manager.rename(id, "Damaged too");
  manager.flushNow();
  const rows = f.rows();
  expect(rows).toHaveLength(2);
  expect(rows.find((row) => row.id === id).forkHandoff).toEqual({ state: "staged", sourceTool: "kimi", root: "/somewhere" });
});

test("a native fork takes no snapshot", async () => {
  const f = fixture();
  const src = source(f);
  f.manager.setAgentSession(src.id, "native-source");
  const fork = await f.manager.fork(src.id, "current");
  expect(f.snapshots).toHaveLength(0);
  expect(f.rows().find((row) => row.id === fork.id).forkHandoff).toBeUndefined();
});

test("with handoffFiles off nothing is staged and a launch places nothing", async () => {
  const f = fixture({ handoffFiles: false });
  const fork = await f.manager.fork(source(f).id, "current");
  expect(f.snapshots).toHaveLength(0);
  await f.manager.start(fork.id);
  expect(existsSync(join(f.directory, ".antgrid"))).toBe(false);
  expect(existsSync(join(f.directory, "agents", "project", "handoff"))).toBe(false);
});

test("a fork that fails after staging removes its staging dir and adds no row", async () => {
  const f = fixture();
  const src = source(f);
  mkdirSync(join(f.directory, "agents", "project"), { recursive: true });
  // A directory where sessions.json belongs makes the flush that commits the row fail.
  mkdirSync(f.sessionsPath);
  await expect(f.manager.fork(src.id, "current")).rejects.toThrow();
  expect(f.manager.list()).toHaveLength(1);
  expect(readdirSync(join(f.directory, "agents", "project", "handoff"))).toEqual([]);
});

test("a managed delete waits for the handoff placement before removing the worktree", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  f.manager.flushNow();
  const worktree = join(f.directory, "wt");
  mkdirSync(worktree);
  const file = JSON.parse(readFileSync(f.sessionsPath, "utf8"));
  const row = file.sessions.find((r: any) => r.id === fork.id);
  row.checkoutId = "co1";
  row.checkoutKind = "managed-worktree";
  writeFileSync(f.sessionsPath, JSON.stringify(file));
  const record = {
    id: "co1", projectId: "project", kind: "managed-worktree", path: worktree,
    branch: "antgrid/x", baseRef: "main", managed: true, sessionId: fork.id, createdAt: 1,
  };
  let placedAtRemove = false;
  const manager = f.makeManager({
    worktreeSessionsSupported: true,
    isGitRepository: async () => true,
    resolveCheckout: async () => record,
    resolveAgentSpec: async () => ({ name: "kimi", command: "kimi" }),
    worktreeManager: {
      recordFor: async () => record,
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {
        placedAtRemove = existsSync(join(worktree, ".antgrid", "handoff", fork.id, "manifest.json"));
        await Bun.sleep(150);
      },
    },
  });
  const starting = Promise.resolve(manager.start(fork.id)).catch(() => {});
  for (let i = 0; i < 200 && !existsSync(join(worktree, ".antgrid", "handoff")); i++) await Bun.sleep(5);
  const deleting = manager.delete(fork.id);
  await Promise.all([starting, deleting]);
  await manager.settleHandoffCleanup();
  expect(placedAtRemove).toBe(true);
  expect(f.spawns).toHaveLength(0);
  expect(existsSync(join(worktree, ".antgrid", "handoff", fork.id))).toBe(false);
});

test("a sessions.json that cannot be read in full is never swept against", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  f.manager.flushNow();
  writeFileSync(f.sessionsPath, "{ not json");
  const reloaded = f.makeManager();
  await reloaded.settleHandoffCleanup();
  await Bun.sleep(100);
  expect(existsSync(join(f.staging(fork.id), "manifest.json"))).toBe(true);
});
