import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PreparedTerminalLaunch, TerminalLaunchRequest } from "antgrid-agents/contracts";
import { ByteBudget, writeText, type HandoffSnapshot, type HandoffSnapshotOpts } from "antgrid-agents/handoff";
import { agentRuntime } from "../src/agent-runtime";
import { SessionManager } from "../src/session-manager";

const managers: SessionManager[] = [];
const directories: string[] = [];
afterEach(() => {
  for (const manager of managers.splice(0)) manager.flushNow();
  for (const path of directories.splice(0)) rmSync(path, { recursive: true, force: true });
});

interface Options {
  scrollback?: string | null;
  promptDelivery?: PreparedTerminalLaunch["promptDelivery"];
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
    // Every agent gets the fixture snapshot, so no test can reach a real store.
    get: (id: string) => {
      const spec = agentRuntime.get(id);
      if (!spec) return spec;
      return { ...spec, fork: { ...spec.fork, snapshot: async (opts: HandoffSnapshotOpts) => { snapshots.push(opts); return snapshot(opts); } } };
    },
    prepareTerminal: async (request: TerminalLaunchRequest): Promise<PreparedTerminalLaunch> => {
      requests.push(request);
      return { command: "kimi", args: [], env: {}, invocationKind: "exec", resumed: false, promptDelivery: options.promptDelivery ?? "none" };
    },
  };
  const requests: TerminalLaunchRequest[] = [];
  const chatStarts: { sessionId: string; initialPrompt?: string }[] = [];
  const spawns: any[] = [];
  const submits: string[] = [];
  const live = new Set<string>();
  const scrollback = options.scrollback === undefined ? "fix the parser" : options.scrollback;
  const terminal = {
    has: (id: string) => live.has(id), kill: (id: string) => live.delete(id),
    forget: (id: string) => live.delete(id), treeKilled: async () => {},
    submit: (_id: string, text: string) => { submits.push(text); },
    spawn: (config: any) => { spawns.push(config); live.add(config.terminalId); return config.terminalId; },
    getScrollback: () => (scrollback === null ? null : { text: scrollback, seq: 1 }),
  };
  const makeManager = (extra: Record<string, unknown> = {}) => {
    const manager = new SessionManager({
      projectId: "project", projectPath: directory, storeDir: directory,
      agentSpec: { name: "kimi", command: "kimi" }, terminalManager: terminal as any,
      agentRuntime: runtime as any, sendMessage() {},
      onStartChat: (start: { sessionId: string; initialPrompt?: string }) => { chatStarts.push(start); },
      ...extra,
    });
    managers.push(manager);
    return manager;
  };
  const staging = (id: string) => join(directory, "agents", "project", "handoff", id);
  const placed = (id: string) => join(directory, ".antgrid", "handoff", id);
  return { directory, manager: makeManager(), makeManager, rows, spawns, submits, snapshots, requests, chatStarts, staging, placed, sessionsPath };
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

test("a 5 MB transcript forks and the excerpt stays bounded and keeps the newest turn", async () => {
  const turns = 20_000;
  const f = fixture({
    scrollback: "word ".repeat(1_000_000),
    snapshot: async (opts) => {
      const lines: string[] = [];
      for (let turn = 0; turn < turns; turn++) {
        lines.push(JSON.stringify({ type: "turn.prompt", prompt: `question ${turn}` }));
        lines.push(JSON.stringify({
          type: "context.append_loop_event",
          event: { type: "content.part", part: { type: "text", text: `answer ${turn} ${"x".repeat(150)}` } },
        }));
      }
      const file = await writeText(opts.outDir, "fixture.jsonl", `${lines.join("\n")}\n`, "transcript", new ByteBudget());
      return { agent: "kimi", method: "copy", primary: "fixture.jsonl", files: [file], references: [], redactions: [], warnings: [] };
    },
  });
  const fork = await f.manager.fork(source(f).id, "current");
  expect(statSync(join(f.staging(fork.id), "fixture.jsonl")).size).toBeGreaterThan(5_000_000);
  const excerpt = join(f.staging(fork.id), "excerpt.md");
  expect(statSync(excerpt).size).toBeLessThanOrEqual(16_000);
  expect(readFileSync(excerpt, "utf8")).toContain(`question ${turns - 1}`);
});

test("a source with no argv prompt gets the one-line prompt typed in", async () => {
  const f = fixture({ promptDelivery: "buffered" });
  const fork = await f.manager.fork(source(f).id, "current");
  await f.manager.start(fork.id);
  expect(f.submits).toHaveLength(1);
  expect(f.submits[0]).not.toContain("\n");
  expect(f.submits[0]!.length).toBeLessThanOrEqual(1_500);
  expect(f.submits[0]).toContain(join(f.placed(fork.id), "excerpt.md"));
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

test("a fork never carries the transcript in the row or the prompt", async () => {
  const f = fixture({ scrollback: "SECRET-TRANSCRIPT-WORDS" });
  const fork = await f.manager.fork(source(f).id, "current");
  expect(f.rows().find((row) => row.id === fork.id).forkTranscript).toBeUndefined();
  await f.manager.start(fork.id);
  expect(f.requests[0]!.initialPrompt).not.toContain("SECRET-TRANSCRIPT-WORDS");
});

test("a terminal launch gets the one-line prompt with the fork-handoff kind", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  await f.manager.start(fork.id, "also run the tests");
  const request = f.requests[0]!;
  expect(request.promptKind).toBe("fork-handoff");
  expect(request.initialPrompt).not.toContain("\n");
  expect(request.initialPrompt!.length).toBeLessThanOrEqual(1_500);
  expect(request.initialPrompt).toContain(join(f.placed(fork.id), "excerpt.md"));
  expect(request.initialPrompt).toContain(join(f.placed(fork.id), "fixture.jsonl"));
  expect(request.initialPrompt).toContain("Additional instruction: also run the tests");
  expect(request.initialPrompt).toContain("handed off from Kimi");
});

test("a start with no fork keeps the initial prompt kind and text", async () => {
  const f = fixture();
  const session = source(f);
  await f.manager.start(session.id, "plain prompt");
  expect(f.requests[0]!.promptKind).toBe("initial");
  expect(f.requests[0]!.initialPrompt).toBe("plain prompt");
});

test("a chat fork gets the one-line prompt as its initial prompt", async () => {
  const f = fixture();
  const chat = f.manager.create("Chat source", { tool: "codex", mode: "chat" });
  const fork = await f.manager.fork(chat.id, "current");
  await f.manager.start(fork.id);
  expect(f.chatStarts).toHaveLength(1);
  const prompt = f.chatStarts[0]!.initialPrompt!;
  expect(prompt).toContain(join(f.placed(fork.id), "excerpt.md"));
  expect(prompt).toContain("handed off from Codex");
  expect(prompt).not.toContain("\n");
});

test("a legacy forkTranscript row launches from its saved text, not a fresh snapshot", async () => {
  const f = fixture({ scrollback: "TODAYS-SCROLLBACK" });
  const id = "11111111-2222-4333-8444-555555555555";
  mkdirSync(join(f.directory, "agents", "project"), { recursive: true });
  writeFileSync(f.sessionsPath, JSON.stringify({ version: 1, sessions: [
    { id, name: "Old fork", archived: false, tool: "kimi", mode: "terminal", conversationStart: "fork", forkTranscript: "[Kimi conversation]\nlegacy words" },
  ] }));
  const manager = f.makeManager();
  await manager.start(id);
  expect(f.snapshots).toHaveLength(0);
  const saved = readFileSync(join(f.placed(id), "fork-transcript.txt"), "utf8");
  expect(saved).toContain("legacy words");
  expect(saved).not.toContain("TODAYS-SCROLLBACK");
  expect(readFileSync(join(f.placed(id), "excerpt.md"), "utf8")).toContain("legacy words");
  const request = f.requests[0]!;
  expect(request.promptKind).toBe("fork-handoff");
  expect(request.initialPrompt).toContain(join(f.placed(id), "fork-transcript.txt"));
  expect(request.initialPrompt).not.toContain("legacy words");
  manager.flushNow();
  const row = f.rows().find((r) => r.id === id);
  expect(row.forkHandoff).toEqual({ state: "materialized", sourceTool: "kimi", root: f.directory });
  expect(row.forkTranscript).toBeUndefined();
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
  let placement: Promise<void> | undefined;
  const manager = f.makeManager({
    worktreeSessionsSupported: true,
    isGitRepository: async () => true,
    resolveCheckout: async () => record,
    resolveAgentSpec: async () => ({ name: "kimi", command: "kimi" }),
    worktreeManager: {
      recordFor: async () => record,
      // The preflight outlasts the placement, as it does when Git is slow, so
      // the placement ends before the delete has marked the session.
      inspect: async () => {
        await placement?.catch(() => {});
        await Bun.sleep(20);
        return { exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false };
      },
      remove: async () => {
        placedAtRemove = existsSync(join(worktree, ".antgrid", "handoff", fork.id, "manifest.json"));
        await Bun.sleep(150);
      },
    },
  });
  // The delete is asked for the instant the placement begins.
  const placements = (manager as any).materializing as Map<string, Promise<void>>;
  const register = placements.set.bind(placements);
  let deleting: Promise<boolean> | undefined;
  placements.set = (key, value) => {
    register(key, value);
    placement = value;
    deleting ??= manager.delete(fork.id) as Promise<boolean>;
    return placements;
  };
  await Promise.resolve(manager.start(fork.id)).catch(() => {});
  expect(deleting).toBeDefined();
  expect(await deleting!).toBe(true);
  await manager.settleHandoffCleanup();
  expect(placedAtRemove).toBe(true);
  expect(f.spawns).toHaveLength(0);
  expect(existsSync(join(worktree, ".antgrid", "handoff", fork.id))).toBe(false);
});

test("a fork stopped while its handoff files are being placed does not launch, and a later start does", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  const starting = Promise.resolve(f.manager.start(fork.id));
  f.manager.stop(fork.id);
  await expect(starting).rejects.toThrow("cancelled");
  expect(f.spawns).toHaveLength(0);
  expect(f.rows().find((row) => row.id === fork.id).forkHandoff.state).toBe("materialized");
  await f.manager.start(fork.id);
  expect(f.spawns).toHaveLength(1);
  expect(f.requests.at(-1)!.promptKind).toBe("fork-handoff");
});

test("a chat fork stopped while its handoff files are being placed does not start its driver", async () => {
  const f = fixture();
  const chat = f.manager.create("Chat source", { tool: "codex", mode: "chat" });
  const fork = await f.manager.fork(chat.id, "current");
  const starting = Promise.resolve(f.manager.start(fork.id));
  f.manager.stop(fork.id);
  await expect(starting).rejects.toThrow("cancelled");
  expect(f.chatStarts).toHaveLength(0);
});

test("closing the manager during a placement waits for it, records where it went, and launches nothing", async () => {
  const f = fixture();
  const fork = await f.manager.fork(source(f).id, "current");
  const starting = Promise.resolve(f.manager.start(fork.id)).catch((error: Error) => error);
  await f.manager.close();
  expect(f.rows().find((row) => row.id === fork.id).forkHandoff).toEqual({ state: "materialized", sourceTool: "kimi", root: f.directory });
  expect(await starting).toBeInstanceOf(Error);
  expect(f.spawns).toHaveLength(0);
  await SessionManager.removePersistedHandoffs(f.directory, "project");
  expect(existsSync(f.placed(fork.id))).toBe(false);
});

test("two forks of one source staged together get distinct names", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const f = fixture({ snapshot: async (opts) => { await gate; return writingSnapshot(opts); } });
  const src = source(f);
  const forks = Promise.all([f.manager.fork(src.id, "current"), f.manager.fork(src.id, "current")]);
  await Bun.sleep(20);
  release();
  expect((await forks).map((fork) => fork.name).sort()).toEqual(["Source fork", "Source fork 2"]);
});

describe("a chain of handoffs", () => {
  const prompt = (text: string) => ({ type: "turn.prompt", prompt: text });
  const said = (text: string) => ({ type: "context.append_loop_event", event: { type: "content.part", part: { type: "text", text } } });
  const ORIGINAL = { text: "Port the parser to Rust", at: "fixture.jsonl:1", sourceAgentLabel: "Kimi", inherited: true };

  /** Each fork snapshots whatever transcript the test last set, in Kimi's format. */
  function chain() {
    const transcript: { lines: unknown[] } = { lines: [] };
    const f = fixture({
      snapshot: async (opts) => {
        const body = transcript.lines.map((line) => JSON.stringify(line)).join("\n");
        const file = await writeText(opts.outDir, "fixture.jsonl", `${body}\n`, "transcript", new ByteBudget());
        return { agent: "kimi", method: "copy", primary: "fixture.jsonl", files: [file], references: [], redactions: [], warnings: [] };
      },
    });
    /** Launches a fork and returns the session's transcript as its agent would
     *  have written it: Antgrid's real handoff prompt, then the user's turns. */
    const launch = async (id: string, ...turns: unknown[]) => {
      const before = f.requests.length;
      await f.manager.start(id);
      return [prompt(f.requests[before]!.initialPrompt!), said("Read the excerpt."), ...turns];
    };
    const forkFrom = async (sourceId: string, lines: unknown[]) => {
      transcript.lines = lines;
      return f.manager.fork(sourceId, "current");
    };
    const staged = (id: string) => ({
      excerpt: readFileSync(join(f.staging(id), "excerpt.md"), "utf8"),
      manifest: JSON.parse(readFileSync(join(f.staging(id), "manifest.json"), "utf8")),
    });
    return { f, launch, forkFrom, staged };
  }

  const section = (excerpt: string, heading: string) => {
    const start = excerpt.indexOf(`## ${heading}`);
    if (start < 0) return "";
    const next = excerpt.indexOf("\n## ", start + 3);
    return excerpt.slice(start, next < 0 ? undefined : next);
  };

  test("the third session's excerpt and manifest carry the first session's task", async () => {
    const { f, launch, forkFrom, staged } = chain();
    const a = source(f);
    const b = await forkFrom(a.id, [prompt("Port the parser to Rust"), said("Starting with the lexer.")]);
    expect(staged(b.id).manifest.originalTask).toEqual({ ...ORIGINAL, inherited: undefined });
    const c = await forkFrom(b.id, await launch(b.id, prompt("Now fix the flaky test"), said("Fixed.")));
    const { excerpt, manifest } = staged(c.id);
    const task = section(excerpt, "Original task");
    expect(task).toContain("Port the parser to Rust");
    expect(task).toContain("Carried over from the earlier Kimi session that started this task");
    expect(excerpt).not.toContain("First instruction after an earlier handoff");
    expect(section(excerpt, "First instruction after the handoff")).toContain("Now fix the flaky test");
    expect(manifest.originalTask).toEqual(ORIGINAL);
  });

  test("the task survives the middle session's deletion once the next fork has staged", async () => {
    const { f, launch, forkFrom, staged } = chain();
    const a = source(f);
    const b = await forkFrom(a.id, [prompt("Port the parser to Rust"), said("Starting with the lexer.")]);
    const c = await forkFrom(b.id, await launch(b.id, prompt("Now fix the flaky test")));
    f.manager.delete(b.id);
    await f.manager.settleHandoffCleanup();
    expect(existsSync(f.placed(b.id))).toBe(false);
    const d = await forkFrom(c.id, await launch(c.id, prompt("Now ship it")));
    const { excerpt, manifest } = staged(d.id);
    expect(section(excerpt, "Original task")).toContain("Port the parser to Rust");
    expect(section(excerpt, "First instruction after the handoff")).toContain("Now ship it");
    expect(manifest.originalTask).toEqual(ORIGINAL);
  });

  test("the task recorded before a native fork still reaches the next handoff", async () => {
    const { f, launch, forkFrom, staged } = chain();
    const a = source(f);
    const b = await forkFrom(a.id, [prompt("Port the parser to Rust"), said("Starting with the lexer.")]);
    const continued = await launch(b.id);
    f.manager.setAgentSession(b.id, "b-native");
    const c = await f.manager.fork(b.id, "current");
    expect(f.rows().find((row) => row.id === c.id).forkHandoff).toBeUndefined();
    // A native fork carries b's conversation, Antgrid's prompt included.
    const d = await forkFrom(c.id, [...continued, prompt("Now fix the flaky test"), said("Fixed.")]);
    const { excerpt, manifest } = staged(d.id);
    expect(section(excerpt, "Original task")).toContain("Port the parser to Rust");
    expect(section(excerpt, "First instruction after the handoff")).toContain("Now fix the flaky test");
    expect(manifest.originalTask).toEqual(ORIGINAL);
  });

  test("a source whose own handoff is gone forks with today's heading and no recorded task", async () => {
    const { f, launch, forkFrom, staged } = chain();
    const a = source(f);
    const b = await forkFrom(a.id, [prompt("Port the parser to Rust")]);
    const lines = await launch(b.id, prompt("Now fix the flaky test"));
    rmSync(f.placed(b.id), { recursive: true, force: true });
    const c = await forkFrom(b.id, lines);
    const { excerpt, manifest } = staged(c.id);
    expect(excerpt).not.toContain("## Original task");
    expect(section(excerpt, "First instruction after an earlier handoff")).toContain("Now fix the flaky test");
    expect(manifest.originalTask).toBeUndefined();
  });

  test("a source handoff reached through a linked .antgrid is not read", async () => {
    const { f, launch, forkFrom, staged } = chain();
    const a = source(f);
    const b = await forkFrom(a.id, [prompt("Port the parser to Rust")]);
    const lines = await launch(b.id, prompt("Now fix the flaky test"));
    const outside = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-fork-outside-")));
    directories.push(outside);
    renameSync(join(f.directory, ".antgrid"), join(outside, "moved"));
    symlinkSync(join(outside, "moved"), join(f.directory, ".antgrid"), "junction");
    expect(existsSync(join(f.placed(b.id), "manifest.json"))).toBe(true);
    const c = await forkFrom(b.id, lines);
    expect(staged(c.id).excerpt).not.toContain("## Original task");
    expect(staged(c.id).manifest.originalTask).toBeUndefined();
  });
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
