import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PreparedTerminalLaunch, TerminalLaunchRequest } from "antgrid-agents/contracts";
import { ByteBudget, EXCERPT_SMALL_MAX_BYTES, writeText, type HandoffEventsFn, type HandoffSnapshot, type HandoffSnapshotOpts } from "antgrid-agents/handoff";
import { agentRuntime } from "../src/agent-runtime";
import { SessionManager } from "../src/session-manager";

const managers: SessionManager[] = [];
const directories: string[] = [];
afterEach(() => {
  for (const manager of managers.splice(0)) manager.flushNow();
  for (const path of directories.splice(0)) rmSync(path, { recursive: true, force: true });
});

function fixture(events?: HandoffEventsFn) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-cross-fork-")));
  directories.push(directory);
  const sessionsPath = join(directory, "agents", "project", "sessions.json");
  const rows = (): any[] => JSON.parse(readFileSync(sessionsPath, "utf8")).sessions;
  const snapshotTools: string[] = [];
  const requests: TerminalLaunchRequest[] = [];
  const submitted: Array<{ id: string; text: string }> = [];
  const spawns: any[] = [];
  const runtime = {
    ...agentRuntime,
    // Every agent gets the fixture snapshot, so no test can reach a real store.
    get: (id: string) => {
      const spec = agentRuntime.get(id);
      if (!spec) return spec;
      const snapshot = async (opts: HandoffSnapshotOpts): Promise<HandoffSnapshot> => {
        snapshotTools.push(id);
        const file = await writeText(opts.outDir, "fixture.jsonl", '{"a":1}\n', "transcript", new ByteBudget());
        return { agent: id, method: "copy", primary: "fixture.jsonl", files: [file], references: [], redactions: [], warnings: [] };
      };
      return { ...spec, fork: { ...spec.fork, snapshot, ...(events ? { events } : {}) } };
    },
    prepareTerminal: async (request: TerminalLaunchRequest): Promise<PreparedTerminalLaunch> => {
      requests.push(request);
      const kimi = request.tool === "kimi";
      return { command: request.tool ?? "x", args: [], env: {}, invocationKind: "exec", resumed: false, promptDelivery: kimi ? "buffered" : "none" };
    },
  };
  const live = new Set<string>();
  const terminal = {
    has: (id: string) => live.has(id), kill: (id: string) => live.delete(id),
    forget: (id: string) => live.delete(id), treeKilled: async () => {}, submit: (id: string, text: string) => { submitted.push({ id, text }); },
    spawn: (config: any) => { spawns.push(config); live.add(config.terminalId); return config.terminalId; },
    getScrollback: () => ({ text: "fix the parser", seq: 1 }),
  };
  const manager = new SessionManager({
    projectId: "project", projectPath: directory, storeDir: directory,
    agentSpec: { name: "codex", command: "codex" }, terminalManager: terminal as any,
    agentRuntime: runtime as any, sendMessage() {}, onStartChat() {},
  });
  managers.push(manager);
  const staging = (id: string) => join(directory, "agents", "project", "handoff", id);
  return { directory, manager, rows, snapshotTools, requests, submitted, spawns, staging, sessionsPath };
}

test("codex to claude-code takes the file handoff even though both support native fork", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "codex" });
  f.manager.setAgentSession(source.id, "native-source");
  const fork = await f.manager.fork(source.id, "current", "claude-code");
  const row = f.rows().find((r) => r.id === fork.id);
  expect(row.tool).toBe("claude-code");
  expect(row.forkSourceSessionId).toBeUndefined();
  expect(row.forkHandoff).toEqual({ state: "staged", sourceTool: "codex" });
  expect(f.snapshotTools).toEqual(["codex"]);
  expect(existsSync(join(f.staging(fork.id), "manifest.json"))).toBe(true);
});

// Enough conversation that only the tier's byte cap decides the excerpt's size.
const longConversation: HandoffEventsFn = async (_dir, _manifest, sink) => {
  for (let turn = 0; turn < 120; turn++) {
    sink({ kind: "user", text: `question ${turn} ${"q".repeat(300)}`, genuine: true, at: `t:${turn}` });
    sink({ kind: "assistant", text: `answer ${turn} ${"a".repeat(300)}`, at: `t:${turn}` });
  }
};
const excerptBytes = (f: ReturnType<typeof fixture>, id: string) => Buffer.byteLength(readFileSync(join(f.staging(id), "excerpt.md"), "utf8"));

test("the excerpt is sized for the target agent, not the source", async () => {
  const f = fixture(longConversation);
  const codex = f.manager.create("Source", { tool: "codex" });
  const toClaude = await f.manager.fork(codex.id, "current", "claude-code");
  expect(excerptBytes(f, toClaude.id)).toBeGreaterThan(EXCERPT_SMALL_MAX_BYTES);
  const claude = f.manager.create("Source", { tool: "claude-code" });
  const toKimi = await f.manager.fork(claude.id, "current", "kimi");
  expect(excerptBytes(f, toKimi.id)).toBeLessThanOrEqual(EXCERPT_SMALL_MAX_BYTES);
});

test("same agent with targetTool equal to source still forks natively", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "codex" });
  f.manager.setAgentSession(source.id, "native-source");
  const fork = await f.manager.fork(source.id, "current", "codex");
  const row = f.rows().find((r) => r.id === fork.id);
  expect(row.forkSourceSessionId).toBe("native-source");
  expect(row.forkHandoff).toBeUndefined();
  expect(f.snapshotTools).toEqual([]);
});

test("unknown targetTool is refused before any staging", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "codex" });
  await expect(f.manager.fork(source.id, "current", "nope")).rejects.toThrow("Antgrid does not know the agent nope.");
  expect(f.snapshotTools).toEqual([]);
  expect(existsSync(join(f.directory, "agents", "project", "handoff"))).toBe(false);
  expect(f.manager.list()).toHaveLength(1);
});

test("chat source to a non-chat target launches in terminal", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "claude-code", mode: "chat" });
  const toKimi = await f.manager.fork(source.id, "current", "kimi");
  expect(f.rows().find((r) => r.id === toKimi.id).mode).toBe("terminal");
  const toCodex = await f.manager.fork(source.id, "current", "codex");
  expect(f.rows().find((r) => r.id === toCodex.id).mode).toBe("chat");
});

test("an approval policy the target lacks falls back to the target default", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "codex", approvalPolicy: "bypass" });
  const toOpencode = await f.manager.fork(source.id, "current", "opencode");
  expect(f.rows().find((r) => r.id === toOpencode.id).approvalPolicy).toBe("default");
  const toKimi = await f.manager.fork(source.id, "current", "kimi");
  expect(f.rows().find((r) => r.id === toKimi.id).approvalPolicy).toBe("bypass");
});

test("a bypass that also drops the sandbox is not inherited from one that keeps it", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "claude-code", approvalPolicy: "bypass" });
  const toCodex = await f.manager.fork(source.id, "current", "codex");
  expect(f.rows().find((r) => r.id === toCodex.id).approvalPolicy).toBe("default");
  const toGemini = await f.manager.fork(source.id, "current", "kimi");
  expect(f.rows().find((r) => r.id === toGemini.id).approvalPolicy).toBe("bypass");
});

test("target kimi launches fresh with the typed prompt", async () => {
  const f = fixture();
  const source = f.manager.create("Source", { tool: "codex" });
  f.manager.setAgentSession(source.id, "native-source");
  const fork = await f.manager.fork(source.id, "current", "kimi");
  await f.manager.start(fork.id);
  const request = f.requests.at(-1)!;
  expect(request.conversation.kind).toBe("fresh");
  expect(request.promptKind).toBe("fork-handoff");
  expect(request.initialPrompt).toContain("excerpt.md");
  expect(f.submitted).toEqual([{ id: fork.id, text: request.initialPrompt! }]);
});

test("handoffSupported mirrors forkSupported, carries agentKey, and is false for custom commands and the cold peek", async () => {
  const f = fixture();
  const own = f.manager.create("Own", { tool: "claude-code" });
  const inherited = f.manager.create("Inherited");
  const custom = f.manager.create("Custom", { command: "my-agent" });
  const wire = (id: string) => f.manager.list().find((e) => e.id === id)!;
  expect(wire(own.id)).toMatchObject({ forkSupported: true, handoffSupported: true, agentKey: "claude-code" });
  expect(wire(inherited.id)).toMatchObject({ handoffSupported: true, agentKey: "codex" });
  expect(wire(custom.id).forkSupported).toBe(false);
  expect(wire(custom.id).handoffSupported).toBe(false);
  expect(wire(custom.id).agentKey).toBeUndefined();
  f.manager.flushNow();
  const cold = await SessionManager.readPersisted(f.directory, "project", true);
  expect(cold.length).toBeGreaterThan(0);
  for (const row of cold) {
    expect(row.handoffSupported).toBe(false);
    expect(row.agentKey).toBeUndefined();
  }
});
