import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync, statSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, normalize } from "node:path";
import { SessionManager, isDefaultSessionName } from "../src/session-manager";
import { buildSpawnEnv } from "../src/terminal-session";

function tempDir() {
  return mkdtempSync(join(tmpdir(), "antgrid-sess-"));
}

// Fake terminal manager: records spawn/kill calls. `env` goes through the real
// buildSpawnEnv, exactly as TerminalManager.spawn does — the caller env alone is
// not what a PTY receives, and a fake that skipped it would let a regression in
// the always-stamped ANTGRID_TERMINAL_ID pass unnoticed.
function makeFakeTerm() {
  const spawned = new Set<string>();
  const spawns: Array<{ terminalId?: string; command?: string; args?: string[]; cwd?: string; env?: Record<string, string> }> = [];
  return {
    spawned,
    spawns,
    spawn: (cfg: { terminalId?: string; command?: string; args?: string[]; cwd?: string; env?: Record<string, string> }) => {
      spawned.add(cfg.terminalId!);
      spawns.push({ ...cfg, env: buildSpawnEnv(cfg.terminalId!, null, cfg.env ?? {}) });
      return cfg.terminalId!;
    },
    kill: (id: string) => { spawned.delete(id); },
    forget: (id: string) => { spawned.delete(id); },
    treeKilled: () => Promise.resolve(),
    has: (id: string) => spawned.has(id),
  };
}

// Terminal manager whose kill() leaves `has()` true until the exit is noted —
// the real one removes the session in its exit handler, not in kill().
function makeLingeringTerm() {
  const live = new Set<string>();
  return {
    spawn: (cfg: { terminalId?: string }) => { live.add(cfg.terminalId!); return cfg.terminalId!; },
    kill: (_id: string) => {},
    forget: (_id: string) => {},
    treeKilled: () => Promise.resolve(),
    has: (id: string) => live.has(id),
    exit: (id: string) => { live.delete(id); },
  };
}

function seedCopilotSessions(home: string, ids: string[]) {
  const db = new Database(join(home, "session-store.db"));
  db.run("CREATE TABLE sessions (id TEXT PRIMARY KEY)");
  const insert = db.query("INSERT INTO sessions (id) VALUES (?)");
  for (const id of ids) insert.run(id);
  db.close();
}

function expectMaterializedCopilotPlugin(pluginDir: string | undefined, storeDir: string) {
  expect(pluginDir).toBeString();
  expect(normalize(pluginDir!)).toStartWith(normalize(storeDir));
  expect(pluginDir!.replace(/\\/g, "/")).toEndWith("/plugin/copilot");
  expect(existsSync(join(pluginDir!, "plugin.json"))).toBe(true);
  const manifest = JSON.parse(readFileSync(join(pluginDir!, "plugin.json"), "utf8"));
  expect(manifest.hooks.sessionStart[0].command).toContain("hook");
  expect(manifest.hooks.sessionStart[0].command).toContain("github-copilot");
  expect(JSON.stringify(manifest)).not.toMatch(/\bnode(?:\.exe)?\b/i);
}

describe("SessionManager", () => {
  let dir: string;
  beforeEach(() => { dir = tempDir(); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("returns empty list when no file exists", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(sm.list()).toEqual([]);
  });

  it("create produces an entry with auto-name Session 1", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    expect(s.name).toBe("Session 1");
    expect(s.archived).toBe(false);
    expect(sm.list().length).toBe(1);
  });

  it("create auto-naming includes archived in the count", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const a = sm.create();         // Session 1
    sm.archive(a.id);
    const b = sm.create();         // Session 2 (NOT Session 1 — archived counted)
    expect(b.name).toBe("Session 2");
  });

  it("rename updates the entry and persists", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.rename(s.id, "feature/auth");
    expect(sm.list()[0].name).toBe("feature/auth");

    await new Promise((r) => setTimeout(r, 300)); // wait for debounced flush
    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(reloaded.list()[0].name).toBe("feature/auth");
  });

  it("archive hides from default list but unarchive restores", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.archive(s.id);
    expect(sm.list()).toEqual([]);
    expect(sm.list(true).length).toBe(1);
    sm.unarchive(s.id);
    expect(sm.list().length).toBe(1);
  });

  it("delete removes the entry entirely", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.delete(s.id);
    expect(sm.list(true)).toEqual([]);
  });

  it("delete reports presence: true for a real id, false for a missing one", () => {
    // The control-plane delete surfaces this bool as `deleted`; it MUST match
    // the stopped-core path (deletePersisted) which returns false for a missing
    // id — otherwise warm vs stopped projects report contradictory results.
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    expect(sm.delete(s.id)).toBe(true);
    expect(sm.delete(s.id)).toBe(false); // already gone
    expect(sm.delete("never-existed")).toBe(false);
  });

  it("focus does NOT bump lastUsedAt (viewing is not activity)", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    const before = s.lastUsedAt;
    await new Promise((r) => setTimeout(r, 5));
    sm.focus(s.id);
    expect(sm.list()[0].lastUsedAt).toBe(before);
  });

  it("touch bumps lastUsedAt and re-sorts; no-ops for unknown ids", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const a = sm.create();
    await new Promise((r) => setTimeout(r, 5));
    const b = sm.create();
    expect(sm.list().map((s) => s.id)).toEqual([b.id, a.id]);

    await new Promise((r) => setTimeout(r, 5));
    sm.touch(a.id); // activity on the older session floats it to the top
    expect(sm.list().map((s) => s.id)).toEqual([a.id, b.id]);

    // Unknown terminal id (a service PTY, not a session) is a safe no-op.
    expect(() => sm.touch("not-a-session")).not.toThrow();
  });

  it("list is sorted by lastUsedAt desc", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const a = sm.create();
    await new Promise((r) => setTimeout(r, 5));
    const b = sm.create();
    expect(sm.list().map((s) => s.id)).toEqual([b.id, a.id]);
  });

  it("treats corrupt sessions.json as empty (no crash)", () => {
    mkdirSync(join(dir, "agents", "p1"), { recursive: true });
    writeFileSync(join(dir, "agents", "p1", "sessions.json"), "not json {");
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(sm.list()).toEqual([]);
  });

  it("onChange fires on create/rename/archive/delete", () => {
    const events: number[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    sm.onChange(() => events.push(events.length));
    const s = sm.create();      // 1
    sm.rename(s.id, "X");       // 2
    sm.archive(s.id);           // 3
    sm.delete(s.id);            // 4
    expect(events.length).toBe(4);
  });

  it("flushNow persists immediately without waiting for debounce", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.flushNow();
    // No timeout/await: a fresh manager should see the entry already on disk.
    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(reloaded.list().length).toBe(1);
    expect(reloaded.list()[0].id).toBe(s.id);
  });

  it("flushNow persists a pending touch bump (activity defers its flush)", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.flushNow(); // settle the create's lastUsedAt to disk
    await new Promise((r) => setTimeout(r, 5));
    sm.touch(s.id); // arms the coalesced activity window — no immediate flush
    const bumped = sm.list()[0].lastUsedAt;
    sm.flushNow(); // teardown must persist the in-flight bump, not drop it
    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(reloaded.list()[0].lastUsedAt).toBe(bumped);
  });

  it("load() coerces non-numeric timestamps to fallback values", () => {
    mkdirSync(join(dir, "agents", "p1"), { recursive: true });
    const handcrafted = {
      version: 1,
      sessions: [
        {
          id: "abc",
          name: "broken",
          createdAt: "yesterday",
          lastUsedAt: "yesterday",
          archived: false,
        },
      ],
    };
    writeFileSync(join(dir, "agents", "p1", "sessions.json"), JSON.stringify(handcrafted));
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const list = sm.list();
    expect(list.length).toBe(1);
    expect(Number.isFinite(list[0].createdAt)).toBe(true);
    expect(Number.isFinite(list[0].lastUsedAt)).toBe(true);
    expect(Number.isNaN(list[0].createdAt)).toBe(false);
    expect(Number.isNaN(list[0].lastUsedAt)).toBe(false);
    // Sort should not blow up either.
    expect(() => sm.list()).not.toThrow();
  });

  it("file mode is 0600 on POSIX", () => {
    if (process.platform === "win32") return;
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    sm.create();
    sm.flushNow();
    const path = join(dir, "agents", "p1", "sessions.json");
    expect(statSync(path).mode & 0o777).toBe(0o600);
  });

  it("rapid mutations coalesce into one disk write", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const path = join(dir, "agents", "p1", "sessions.json");
    // Five rapid mutations within the debounce window.
    sm.create();
    sm.create();
    sm.create();
    sm.create();
    sm.create();
    // Before the debounce fires, no file should exist yet.
    expect(existsSync(path)).toBe(false);
    // Wait past the debounce window.
    await new Promise((r) => setTimeout(r, 300));
    expect(existsSync(path)).toBe(true);
    const mtime1 = statSync(path).mtimeMs;
    // No further mutations -> mtime should stay constant after another wait.
    await new Promise((r) => setTimeout(r, 300));
    const mtime2 = statSync(path).mtimeMs;
    expect(mtime2).toBe(mtime1);
    // And all 5 sessions are in the single coalesced write.
    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(reloaded.list().length).toBe(5);
  });

  it("create stores and persists a per-session tool/args spec", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("auth", { tool: "codex", args: "--full-auto" });
    expect(s.tool).toBe("codex");
    expect(s.args).toBe("--full-auto");

    await new Promise((r) => setTimeout(r, 300)); // debounced flush
    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const reloadedEntry = reloaded.list()[0];
    expect(reloadedEntry.tool).toBe("codex");
    expect(reloadedEntry.args).toBe("--full-auto");
    expect(reloadedEntry.command).toBeUndefined();
  });

  it("setAgentSession persists and reloads optional native agent metadata", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("copilot", { tool: "github-copilot" });
    sm.setAgentSession(s.id, "cop-1", "/tmp/copilot-transcript.json");
    sm.flushNow();

    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const raw = JSON.parse(readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8"));
    const entry = raw.sessions.find((row: any) => row.id === s.id);
    expect(entry.agentSessionId).toBe("cop-1");
    expect(entry.agentTranscriptPath).toBe("/tmp/copilot-transcript.json");
  });

  it("create() rejects empty or whitespace-only names but still auto-names with no arg", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(() => sm.create("")).toThrow("name cannot be empty");
    expect(() => sm.create("   ")).toThrow("name cannot be empty");
    // Neither failed call should have leaked an entry.
    expect(sm.list().length).toBe(0);
    const s = sm.create();
    expect(s.name).toBe("Session 1");
    const trimmed = sm.create("  real name  ");
    expect(trimmed.name).toBe("real name");
  });
});

describe("SessionManager start/stop", () => {
  let dir: string;
  beforeEach(() => { dir = tempDir(); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("start spawns the PTY at default 80x24 via terminalManager", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.start(s.id);
    expect(term.spawned.has(s.id)).toBe(true);
    expect(term.spawns.length).toBe(1);
    expect(term.spawns[0].command).toBe("claude");
    expect(sm.list().find((x) => x.id === s.id)?.running).toBe(true);
    sm.flushNow();
  });

  it("stop kills the PTY", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "agent" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.start(s.id);
    expect(term.spawned.has(s.id)).toBe(true);
    sm.stop(s.id);
    expect(term.spawned.has(s.id)).toBe(false);
    sm.flushNow();
  });

  it("start on archived throws", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "agent" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.archive(s.id);
    expect(() => sm.start(s.id)).toThrow();
    sm.flushNow();
  });

  it("start is idempotent on already-running session", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "agent" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.start(s.id);
    expect(() => sm.start(s.id)).not.toThrow();
    expect(term.spawned.size).toBe(1);
    expect(term.spawns.length).toBe(1);
    sm.flushNow();
  });

  it("stop is a no-op on a non-running session", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "agent" },
      sendMessage: () => {},
    });
    const s = sm.create();
    // Never started — stop should silently succeed.
    expect(() => sm.stop(s.id)).not.toThrow();
    expect(term.spawned.has(s.id)).toBe(false);
    sm.flushNow();
  });

  it("start falls back to projectPath when spec.workingDir is unset", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: "/proj/path", terminalManager: term as any,
      // No workingDir on the spec — fallback should fire.
      agentSpec: { command: "claude", name: "agent" },
      sendMessage: () => {},
    });
    const s = sm.create();
    sm.start(s.id);
    expect(term.spawns.length).toBe(1);
    expect(term.spawns[0].cwd).toBe("/proj/path");
    sm.flushNow();
  });

  it("start throws when the spec has an empty command (no agent configured)", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      // Placeholder spec — mirrors `agentSpecFromConfig()` when needsFirstRun.
      agentSpec: { command: "", name: "agent" },
      sendMessage: () => {},
    });
    const s = sm.create();
    expect(() => sm.start(s.id)).toThrow(/agent.tool or agent.command/);
    // start() rejected before the spawn call.
    expect(term.spawned.has(s.id)).toBe(false);
    expect(term.spawns.length).toBe(0);
    sm.flushNow();
  });

  it("start resolves a registry tool to its bin", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    expect(term.spawns[0].command).toBe("codex");
  });

  it("github-copilot resume appends --resume when the native session exists", () => {
    const copilotHome = tempDir();
    seedCopilotSessions(copilotHome, ["cop-1"]);
    try {
      const term = makeFakeTerm();
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        copilotHome,
      });
      const s = sm.create("copilot", { tool: "github-copilot" });
      sm.setAgentSession(s.id, "cop-1");

      sm.start(s.id);

      expect(term.spawns[0].command).toBe("copilot");
      expect(term.spawns[0].args).toContain("--plugin-dir");
      const pluginDir = term.spawns[0].args?.[term.spawns[0].args.indexOf("--plugin-dir") + 1];
      expectMaterializedCopilotPlugin(pluginDir, dir);
      expect(term.spawns[0].args).toContain("--resume=cop-1");
      expect(term.spawns[0].env?.ANTGRID_TERMINAL_ID).toBe(s.id);
    } finally {
      rmSync(copilotHome, { recursive: true, force: true });
    }
  });

  it("per-session github-copilot injects the bundled plugin dir", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("copilot", { tool: "github-copilot" });

    sm.start(s.id);

    expect(term.spawns[0].command).toBe("copilot");
    expect(term.spawns[0].args).toContain("--plugin-dir");
    const pluginDir = term.spawns[0].args?.[term.spawns[0].args.indexOf("--plugin-dir") + 1];
    expectMaterializedCopilotPlugin(pluginDir, dir);
    expect(term.spawns[0].env?.ANTGRID_TERMINAL_ID).toBe(s.id);
  });

  it("github-copilot launches without plugin-dir when bundled plugin materialization fails", () => {
    mkdirSync(join(dir, "plugin"), { recursive: true });
    writeFileSync(join(dir, "plugin", "copilot"), "not a directory");
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("copilot", { tool: "github-copilot" });

    sm.start(s.id);

    expect(term.spawns[0].command).toBe("copilot");
    expect(term.spawns[0].args ?? []).not.toContain("--plugin-dir");
    expect(term.spawns[0].env?.ANTGRID_TERMINAL_ID).toBe(s.id);
  });

  it("github-copilot launches without plugin-dir when the generated manifest path is a directory", () => {
    const pluginDir = join(dir, "plugin", "copilot");
    mkdirSync(join(pluginDir, "plugin.json"), { recursive: true });
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("copilot", { tool: "github-copilot" });

    sm.start(s.id);

    expect(term.spawns[0].command).toBe("copilot");
    expect(term.spawns[0].args ?? []).not.toContain("--plugin-dir");
    expect(term.spawns[0].env?.ANTGRID_TERMINAL_ID).toBe(s.id);
  });

  it("default github-copilot injects the bundled plugin dir", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "copilot", name: "github-copilot" },
      sendMessage: () => {},
    });
    const s = sm.create("copilot");

    sm.start(s.id);

    expect(term.spawns[0].command).toBe("copilot");
    expect(term.spawns[0].args).toContain("--plugin-dir");
    const pluginDir = term.spawns[0].args?.[term.spawns[0].args.indexOf("--plugin-dir") + 1];
    expectMaterializedCopilotPlugin(pluginDir, dir);
    expect(term.spawns[0].env?.ANTGRID_TERMINAL_ID).toBe(s.id);
  });

  it("github-copilot folds injected args before raw args", () => {
    const copilotHome = tempDir();
    seedCopilotSessions(copilotHome, ["cop-1"]);
    try {
      const term = makeFakeTerm();
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        copilotHome,
      });
      const s = sm.create("copilot", { tool: "github-copilot", args: "-- --raw-user-arg" });
      sm.setAgentSession(s.id, "cop-1");

      sm.start(s.id);

      const command = term.spawns[0].command!;
      expect(term.spawns[0].args).toEqual([]);
      expect(command.indexOf("--plugin-dir")).toBeGreaterThan(-1);
      expect(command.indexOf("--resume=cop-1")).toBeGreaterThan(-1);
      expect(command.indexOf("-- --raw-user-arg")).toBeGreaterThan(-1);
      expect(command.indexOf("--plugin-dir")).toBeLessThan(command.indexOf("-- --raw-user-arg"));
      expect(command.indexOf("--resume=cop-1")).toBeLessThan(command.indexOf("-- --raw-user-arg"));
    } finally {
      rmSync(copilotHome, { recursive: true, force: true });
    }
  });

  it("default github-copilot resume appends --resume when the native session exists", () => {
    const copilotHome = tempDir();
    seedCopilotSessions(copilotHome, ["cop-1"]);
    try {
      const term = makeFakeTerm();
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "copilot", name: "github-copilot" },
        sendMessage: () => {},
        copilotHome,
      });
      const s = sm.create("copilot");
      sm.setAgentSession(s.id, "cop-1");

      sm.start(s.id);

      expect(term.spawns[0].command).toBe("copilot");
      expect(term.spawns[0].args).toContain("--resume=cop-1");
      expect(term.spawns[0].env?.ANTGRID_TERMINAL_ID).toBe(s.id);
    } finally {
      rmSync(copilotHome, { recursive: true, force: true });
    }
  });

  it("github-copilot clears a stale native session id and starts fresh", () => {
    const copilotHome = tempDir();
    seedCopilotSessions(copilotHome, ["cop-live"]);
    try {
      const term = makeFakeTerm();
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        copilotHome,
      });
      const s = sm.create("copilot", { tool: "github-copilot" });
      sm.setAgentSession(s.id, "cop-dead", "/tmp/stale.json");

      sm.start(s.id);

      const spawn = term.spawns[0];
      expect(spawn.command).not.toContain("--resume=cop-dead");
      expect(spawn.args ?? []).not.toContain("--resume=cop-dead");
      expect(sm.get(s.id)?.agentSessionId).toBeUndefined();
      expect(sm.get(s.id)?.agentTranscriptPath).toBeUndefined();
    } finally {
      rmSync(copilotHome, { recursive: true, force: true });
    }
  });

  it("already-running github-copilot start does not clear stored native session metadata", () => {
    const copilotHome = tempDir();
    seedCopilotSessions(copilotHome, ["cop-live"]);
    try {
      const term = makeFakeTerm();
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        copilotHome,
      });
      const s = sm.create("copilot", { tool: "github-copilot" });
      sm.setAgentSession(s.id, "cop-dead", "/tmp/stale.json");
      sm.flushNow();
      term.spawned.add(s.id);

      sm.start(s.id);

      expect(term.spawns.length).toBe(0);
      const raw = JSON.parse(readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8"));
      const entry = raw.sessions.find((row: any) => row.id === s.id);
      expect(entry.agentSessionId).toBe("cop-dead");
      expect(entry.agentTranscriptPath).toBe("/tmp/stale.json");
    } finally {
      rmSync(copilotHome, { recursive: true, force: true });
    }
  });

  it("start appends args as a single command line", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("a", { tool: "claude-code", args: "--model opus" });
    sm.start(s.id);
    // The augmenter's --plugin-dir folds into baseArgs ahead of the per-session
    // args, so the folded command line is:
    //   claude --plugin-dir "<path>" --model opus
    expect(term.spawns[0].command).toMatch(/^claude --plugin-dir .+ --model opus$/);
    expect(term.spawns[0].args).toEqual([]);
  });

  it("start appends args to a custom command", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("a", { command: "my-agent", args: "--verbose" });
    sm.start(s.id);
    expect(term.spawns[0].command).toBe("my-agent --verbose");
  });

  it("start uses a custom command verbatim", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("a", { command: "my-agent --serve" });
    sm.start(s.id);
    expect(term.spawns[0].command).toBe("my-agent --serve");
  });

  it("start falls back to the antgrid.yaml default spec when no per-session spec", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("a");
    sm.start(s.id);
    expect(term.spawns[0].command).toBe("claude");
  });

  it("fallback preserves the antgrid.yaml default flags (agentSpec.args) as argv", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code", args: ["--model", "opus"] },
      sendMessage: () => {},
    });
    const s = sm.create("a"); // no per-session spec
    sm.start(s.id);
    // No per-session args: direct exec with the default flags, no shell folding.
    expect(term.spawns[0].command).toBe("claude");
    expect(term.spawns[0].args).toEqual(["--model", "opus"]);
  });

  it("folds default flags and per-session args into one command line", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code", args: ["--model", "opus"] },
      sendMessage: () => {},
    });
    const s = sm.create("a", { args: "--verbose" }); // fallback command + per-session args
    sm.start(s.id);
    expect(term.spawns[0].command).toBe("claude --model opus --verbose");
    expect(term.spawns[0].args).toEqual([]);
  });

  it("quotes a spaced executable when folding args so the shell doesn't split it", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "/opt/my agent/bin", name: "x" },
      sendMessage: () => {},
    });
    const s = sm.create("a", { args: "--verbose" }); // fallback exec + per-session args
    sm.start(s.id);
    const cmd = term.spawns[0].command!;
    // The executable is wrapped in quotes (cmd.exe "..." or POSIX '...'), not left
    // bare where the shell would treat "/opt/my" as the program.
    expect(cmd).toMatch(/^['"].*my agent.*['"] --verbose$/);
    expect(cmd).not.toBe("/opt/my agent/bin --verbose");
  });

  it("leaves a custom command line unquoted (user owns its shell quoting)", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("a", { command: "my-agent --serve", args: "--verbose" });
    sm.start(s.id);
    expect(term.spawns[0].command).toBe("my-agent --serve --verbose");
  });

  it("create rejects an unknown tool at the source instead of persisting it", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(() => sm.create("a", { tool: "not-a-real-agent" })).toThrow(/unknown agent/);
    // Nothing persisted: a bad tool never becomes an un-startable zombie entry.
    expect(sm.list().length).toBe(0);
  });

  it("defaults mode to 'terminal' when create omits it", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("s1", { tool: "codex" });
    expect(s.mode).toBe("terminal");
  });

  it("persists and round-trips an explicit chat mode", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const created = sm.create("chatty", { tool: "codex", mode: "chat" });
    expect(created.mode).toBe("chat");
    // A fresh manager over the same store dir must read mode back from disk.
    sm.flushNow();
    const reloaded = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    expect(reloaded.get(created.id)?.mode).toBe("chat");
  });

  it("start() routes a chat session to onStartChat, not a PTY", () => {
    const term = makeFakeTerm();
    const calls: any[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: (o) => calls.push(o),
    });
    const s = sm.create("c", { tool: "codex", mode: "chat" });
    sm.start(s.id);
    expect(calls).toEqual([{ sessionId: s.id, tool: "codex", resumeId: undefined }]);
    expect(term.spawns.length).toBe(0); // no PTY spawned
    expect(sm.get(s.id)?.running).toBe(true); // chat running reflected without a PTY
    sm.flushNow();
  });

  it("start() passes a persisted agentSessionId as resumeId for chat", () => {
    // Empty codexHome → resume pre-flight is optimistic → resumes.
    const codexHome = tempDir();
    try {
      const calls: any[] = [];
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        onStartChat: (o) => calls.push(o),
        codexHome,
      });
      const s = sm.create("c", { tool: "codex", mode: "chat" });
      sm.setAgentSession(s.id, "thread-xyz");
      sm.start(s.id);
      expect(calls[0].resumeId).toBe("thread-xyz");
      sm.flushNow();
    } finally {
      rmSync(codexHome, { recursive: true, force: true });
    }
  });

  it("start() drops and clears a chat resume id whose conversation is gone", () => {
    // A dead id is unrecoverable for chat: the driver would resume it on every
    // start, the backend answers "no conversation found", and the session never
    // comes alive again. Claude's pre-flight is the posted transcript path, so a
    // path that does not exist is the positive "it's gone" this asserts on.
    const calls: any[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: (o) => calls.push(o),
    });
    const s = sm.create("c", { tool: "claude-code", mode: "chat" });
    sm.setAgentSession(s.id, "gone-1", join(dir, "no-such-transcript.jsonl"));
    sm.start(s.id);
    expect(calls[0].resumeId).toBeUndefined();
    // Cleared in place, so the next start doesn't re-run the same dead resume.
    expect(sm.get(s.id)?.agentSessionId).toBeUndefined();
    sm.flushNow();
  });

  it("stop() routes a chat session to onStopChat and clears running", () => {
    const stops: string[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStopChat: (id) => { stops.push(id); },
    });
    const s = sm.create("c", { tool: "codex", mode: "chat" });
    sm.start(s.id);
    expect(sm.get(s.id)?.running).toBe(true);
    sm.stop(s.id);
    expect(stops).toEqual([s.id]);
    expect(sm.get(s.id)?.running).toBe(false);
    sm.flushNow();
  });

  it("stop() does not wait on an async onStopChat", () => {
    let released!: () => void;
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStopChat: () => new Promise<void>((resolve) => { released = resolve; }),
    });
    const s = sm.create("c", { tool: "codex", mode: "chat" });
    sm.start(s.id);
    sm.stop(s.id);
    expect(sm.get(s.id)?.running).toBe(false);
    released();
    sm.flushNow();
  });

  it("awaitTerminalExit resolves true once the PTY's exit is noted", async () => {
    const term = makeLingeringTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("t");
    sm.start(s.id);
    sm.stop(s.id);
    const waited = sm.awaitTerminalExit(s.id, 5000);
    expect(term.has(s.id)).toBe(true); // kill() alone doesn't end the PTY
    term.exit(s.id);
    sm.noteExited(s.id);
    expect(await waited).toBe(true);
    sm.flushNow();
  });

  it("awaitTerminalExit resolves false on timeout and leaves no waiter behind", async () => {
    const term = makeLingeringTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("t");
    sm.start(s.id);
    sm.stop(s.id);
    expect(await sm.awaitTerminalExit(s.id, 10)).toBe(false);
    expect((sm as any).terminalExitWaiters.size).toBe(0);
    sm.flushNow();
  });

  it("awaitTerminalExit resolves immediately for a session with no live PTY", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeLingeringTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("t");
    // A long timeout that must never be armed: an exit that already happened has
    // no later noteExited to wait for.
    expect(await sm.awaitTerminalExit(s.id, 60_000)).toBe(true);
    sm.flushNow();
  });

  it("noteExited resolves every waiter once and clears the map", async () => {
    const term = makeLingeringTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("t");
    sm.start(s.id);
    sm.stop(s.id);
    const first = sm.awaitTerminalExit(s.id, 5000);
    const second = sm.awaitTerminalExit(s.id, 5000);
    term.exit(s.id);
    sm.noteExited(s.id);
    expect(await Promise.all([first, second])).toEqual([true, true]);
    expect((sm as any).terminalExitWaiters.size).toBe(0);
    sm.noteExited(s.id); // a second exit report must not re-fire a settled waiter
    sm.flushNow();
  });

  it("setMode flips a stopped session without starting anything", async () => {
    const term = makeFakeTerm();
    const starts: any[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: (o) => starts.push(o),
    });
    const s = sm.create("t", { tool: "codex" });
    await sm.setMode(s.id, "chat");
    expect(sm.get(s.id)?.mode).toBe("chat");
    expect(starts).toEqual([]);
    expect(term.spawns.length).toBe(0);
    sm.flushNow();
  });

  it("setMode starts the chat driver only after the PTY's exit has landed", async () => {
    const term = makeLingeringTerm();
    const order: string[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: () => order.push("chat-start"),
    });
    const s = sm.create("t", { tool: "codex" });
    sm.start(s.id);
    const flip = sm.setMode(s.id, "chat");
    await new Promise((r) => setTimeout(r, 0));
    // The exit-driven teardown (handler disarm, namer forget) has not run yet;
    // starting the driver here would land it on the session that just started.
    expect(order).toEqual([]);
    expect(sm.get(s.id)?.mode).toBe("terminal");
    order.push("pty-exit");
    term.exit(s.id);
    sm.noteExited(s.id);
    await flip;
    expect(order).toEqual(["pty-exit", "chat-start"]);
    expect(sm.get(s.id)?.mode).toBe("chat");
    expect(term.has(s.id)).toBe(false); // no orphaned PTY
    sm.flushNow();
  });

  it("setMode spawns the PTY only after the chat driver's teardown settles", async () => {
    const term = makeFakeTerm();
    let release!: () => void;
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: () => {},
      onStopChat: () => new Promise<void>((resolve) => { release = resolve; }),
    });
    const s = sm.create("c", { tool: "codex", mode: "chat" });
    sm.start(s.id);
    const flip = sm.setMode(s.id, "terminal");
    await new Promise((r) => setTimeout(r, 0));
    // Spawning here would race codex's ~/.codex sqlite lock, which the old
    // driver only releases when its dispose settles.
    expect(term.spawns.length).toBe(0);
    expect(sm.get(s.id)?.mode).toBe("chat");
    release();
    await flip;
    expect(sm.get(s.id)?.mode).toBe("terminal");
    expect(term.spawns.length).toBe(1);
    sm.flushNow();
  });

  it("setMode leaves mode unchanged when the teardown never lands", async () => {
    const term = makeLingeringTerm();
    const starts: any[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: (o) => starts.push(o),
      teardownTimeoutMs: 10,
    });
    const s = sm.create("t", { tool: "codex" });
    sm.start(s.id);
    await expect(sm.setMode(s.id, "chat")).rejects.toThrow(/timed out tearing down/);
    expect(sm.get(s.id)?.mode).toBe("terminal");
    expect(starts).toEqual([]);
    sm.flushNow();
  });

  it("setMode carries the agent conversation across the flip", async () => {
    // Empty codexHome → resume pre-flight is optimistic → resumes.
    const codexHome = tempDir();
    try {
      const starts: any[] = [];
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        onStartChat: (o) => starts.push(o),
        codexHome,
      });
      const s = sm.create("t", { tool: "codex" });
      sm.setAgentSession(s.id, "thread-xyz");
      await sm.setMode(s.id, "chat");
      sm.start(s.id);
      expect(starts[0].resumeId).toBe("thread-xyz");
      expect(sm.get(s.id)?.agentSessionId).toBe("thread-xyz");
      sm.flushNow();
    } finally {
      rmSync(codexHome, { recursive: true, force: true });
    }
  });

  it("setMode refuses chat for a tool with no driver, and refuses archived sessions", async () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const noDriver = sm.create("t", { tool: "cursor-agent" });
    await expect(sm.setMode(noDriver.id, "chat")).rejects.toThrow(/no chat driver/);
    expect(sm.get(noDriver.id)?.mode).toBe("terminal");

    const archived = sm.create("a", { tool: "codex" });
    sm.archive(archived.id);
    await expect(sm.setMode(archived.id, "chat")).rejects.toThrow(/archived/);

    await expect(sm.setMode("nope", "chat")).rejects.toThrow(/not found/);
    sm.flushNow();
  });

  it("setMode to the current mode is a no-op", async () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStopChat: () => { throw new Error("must not tear down"); },
    });
    const s = sm.create("t", { tool: "codex" });
    sm.start(s.id);
    await sm.setMode(s.id, "terminal");
    expect(sm.get(s.id)?.running).toBe(true);
    expect(term.spawns.length).toBe(1);
    sm.flushNow();
  });

  it("agentSessionResumable is true before any agent conversation is captured", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("t", { tool: "codex" });
    expect(sm.get(s.id)?.agentSessionResumable).toBe(true);
    sm.flushNow();
  });

  it("agentSessionResumable is false once the agent's transcript is gone", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create("t", { tool: "claude-code" });
    const transcript = join(dir, "transcript.jsonl");
    writeFileSync(transcript, "{}\n");
    sm.setAgentSession(s.id, "sess-1", transcript);
    expect(sm.get(s.id)?.agentSessionResumable).toBe(true);

    rmSync(transcript);
    sm.setAgentSession(s.id, "sess-2", join(dir, "missing.jsonl"));
    expect(sm.get(s.id)?.agentSessionResumable).toBe(false);
    sm.flushNow();
  });

  it("agentSessionResumable is false for a session that never resumes", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const custom = sm.create("c", { command: "my-agent --serve" });
    expect(sm.get(custom.id)?.agentSessionResumable).toBe(false);
    sm.flushNow();
  });

  it("agentSessionResumable is cached until setAgentSession writes a new id", () => {
    const copilotHome = tempDir();
    seedCopilotSessions(copilotHome, ["cop-1"]);
    try {
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        copilotHome,
      });
      const s = sm.create("t", { tool: "github-copilot" });
      sm.setAgentSession(s.id, "cop-1");
      expect(sm.get(s.id)?.agentSessionResumable).toBe(true);

      const db = new Database(join(copilotHome, "session-store.db"));
      db.run("DELETE FROM sessions");
      db.close();
      // Same id → the memoized answer stands; toWire must not re-query the store
      // on every emit.
      expect(sm.get(s.id)?.agentSessionResumable).toBe(true);

      sm.setAgentSession(s.id, "cop-2");
      expect(sm.get(s.id)?.agentSessionResumable).toBe(false);
      sm.flushNow();
    } finally {
      rmSync(copilotHome, { recursive: true, force: true });
    }
  });

  it("chat start defaults tool to codex when the entry has none", () => {
    const calls: any[] = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
      onStartChat: (o) => calls.push(o),
    });
    const s = sm.create("c", { mode: "chat" });
    sm.start(s.id);
    expect(calls[0].tool).toBe("codex");
    sm.flushNow();
  });

  it("setSessionConfig persists a chat selection and survives reload", () => {
    const opts = {
      projectId: "p1", storeDir: dir, projectPath: dir,
      terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
    };
    const sm = new SessionManager(opts);
    const s = sm.create("chat-1", { tool: "codex", mode: "chat" });

    sm.setSessionConfig(s.id, "model", "gpt-5.2");
    sm.setSessionConfig(s.id, "effort", "high");
    sm.setSessionConfig(s.id, "model", "gpt-5.2-codex"); // overwrite-latest per key

    sm.flushNow(); // writes are debounced 200ms — force the write before reading disk
    // config is persisted-only (never on the wire), so assert via the on-disk
    // shape rather than the wire SessionEntry.
    const onDisk = JSON.parse(
      readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8"),
    );
    const entry = onDisk.sessions.find((e: any) => e.id === s.id);
    expect(entry.config).toEqual({ model: "gpt-5.2-codex", effort: "high" });

    // A fresh manager over the same dir reloads it, and it is NOT leaked onto
    // the wire list.
    const reloaded = new SessionManager(opts);
    expect((reloaded.list()[0] as any).config).toBeUndefined();
  });

  it("setSessionConfig no-ops for unknown id and unchanged value", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir,
      terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
    });
    const s = sm.create("chat-1", { tool: "codex", mode: "chat" });
    sm.setSessionConfig("does-not-exist", "model", "x"); // must not throw
    sm.setSessionConfig(s.id, "model", "gpt-5.2");
    sm.flushNow(); // debounced write — force it before the synchronous disk read
    const before = JSON.parse(
      readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8"),
    ).sessions.find((e: any) => e.id === s.id).config;
    expect(before).toEqual({ model: "gpt-5.2" });
  });

  it("new chat session inherits the last-used config for its tool", () => {
    const opts = {
      projectId: "p1", storeDir: dir, projectPath: dir,
      terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
    };
    const sm = new SessionManager(opts);
    const a = sm.create("codex-a", { tool: "codex", mode: "chat" });
    sm.setSessionConfig(a.id, "model", "gpt-5.2");
    sm.setSessionConfig(a.id, "effort", "high");

    // New codex chat session → inherits a's config.
    const b = sm.create("codex-b", { tool: "codex", mode: "chat" });
    // Writes are debounced 200ms; flush before every synchronous disk read so
    // each assertion sees the latest state (flushNow no-ops when not dirty).
    const onDisk = () => {
      sm.flushNow();
      return JSON.parse(
        readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8"),
      ).sessions;
    };
    const bEntry = onDisk().find((e: any) => e.id === b.id);
    expect(bEntry.config).toEqual({ model: "gpt-5.2", effort: "high" });

    // Different tool → no inheritance.
    const c = sm.create("claude-c", { tool: "claude-code", mode: "chat" });
    expect(onDisk().find((e: any) => e.id === c.id).config).toBeUndefined();

    // A terminal-mode session never seeds config.
    const t = sm.create("term", { tool: "codex", mode: "terminal" });
    expect(onDisk().find((e: any) => e.id === t.id).config).toBeUndefined();
  });

  it("inherited config is a copy, not a shared reference", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir,
      terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
    });
    const a = sm.create("a", { tool: "codex", mode: "chat" });
    sm.setSessionConfig(a.id, "model", "gpt-5.2");
    const b = sm.create("b", { tool: "codex", mode: "chat" });
    // Mutating b's selection must not bleed into a.
    sm.setSessionConfig(b.id, "model", "gpt-5.2-codex");
    sm.flushNow(); // debounced write — force it before the synchronous disk read
    const sessions = JSON.parse(
      readFileSync(join(dir, "agents", "p1", "sessions.json"), "utf8"),
    ).sessions;
    expect(sessions.find((e: any) => e.id === a.id).config).toEqual({ model: "gpt-5.2" });
    expect(sessions.find((e: any) => e.id === b.id).config).toEqual({ model: "gpt-5.2-codex" });
  });
});

describe("SessionManager initial prompt", () => {
  let dir: string;
  beforeEach(() => { dir = tempDir(); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("terminal + no per-session args: prompt is a discrete spawn-argv element, appended last", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { tool: "claude-code" });
    sm.start(s.id, 'fix the "auth" bug');
    const spawn = term.spawns[0];
    expect(spawn.args![spawn.args!.length - 1]).toBe('fix the "auth" bug');
  });

  it("terminal + per-session args: user args keep shell semantics; prompt stays intact", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { tool: "claude-code", args: "--verbose" });
    sm.start(s.id, "fix the auth bug");
    const spawn = term.spawns[0];
    // The user's raw args always fold into the shell command line (shell
    // semantics preserved). The prompt is a single opaque argument:
    if (process.platform === "win32") {
      // cmd.exe can't carry it in the /c line without risking mangling, so it
      // rides as a DISCRETE argv element that terminal-session appends after
      // the folded line — never folded into `command`.
      expect(spawn.command!).toContain("--verbose");
      expect(spawn.command!).not.toContain("fix the auth bug");
      expect(spawn.args![spawn.args!.length - 1]).toBe("fix the auth bug");
    } else {
      // POSIX `sh -c <line>` ignores trailing argv, so the prompt folds into the
      // line, shell-quoted as one unit (single-quoting preserves any newlines).
      expect(spawn.args).toEqual([]);
      expect(spawn.command!).toContain("--verbose");
      expect(spawn.command!.trimEnd()).toMatch(/(['"]).*fix the auth bug.*\1$/);
    }
  });

  it("terminal + per-session args: a MULTI-LINE prompt reaches the child intact", () => {
    // Shift+Enter in the composer inserts a literal newline. On win32 a raw
    // newline folded into a `cmd.exe /c` line terminates the command mid-launch,
    // truncating/garbling it — so the prompt must not be folded there.
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const prompt = "line one\nline two\nline three";
    const s = sm.create(undefined, { tool: "claude-code", args: "--verbose" });
    sm.start(s.id, prompt);
    const spawn = term.spawns[0];
    if (process.platform === "win32") {
      // Discrete argv element, verbatim — cmd.exe never sees the newline in its
      // command line.
      expect(spawn.command!).not.toContain("line one");
      expect(spawn.args![spawn.args!.length - 1]).toBe(prompt);
    } else {
      // Folded but single-quoted, so `sh -c` preserves the newline verbatim.
      expect(spawn.args).toEqual([]);
      expect(spawn.command!).toContain(prompt);
    }
  });

  it("positional agent: prompt is guarded by a `--` separator right before it", () => {
    // A prompt beginning with a dash ("--fix …") must reach the agent as the
    // positional prompt, not be misparsed as a CLI flag. `--` ends option
    // parsing. No per-session args → the prompt rides in discrete spawn argv on
    // every platform, so the tail order is platform-independent.
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { tool: "claude-code" });
    sm.start(s.id, "--fix the enum");
    const args = term.spawns[0].args!;
    expect(args[args.length - 2]).toBe("--");
    expect(args[args.length - 1]).toBe("--fix the enum");
  });

  it("codex resume: prompt sits after the `resume <uuid>` subcommand, behind `--`", () => {
    // Codex's resume is a subcommand (`codex … resume <uuid> [prompt]`); the
    // `--` must land AFTER the uuid so clap reads the prompt as the trailing
    // positional. Empty codexHome → resume pre-flight is optimistic → resumes.
    const codexHome = tempDir();
    try {
      const term = makeFakeTerm();
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "claude", name: "claude-code" },
        sendMessage: () => {},
        codexHome,
      });
      const s = sm.create(undefined, { tool: "codex" });
      sm.setAgentSession(s.id, "11111111-1111-1111-1111-111111111111");
      sm.start(s.id, "--fix the enum");
      const args = term.spawns[0].args!;
      const resumeAt = args.indexOf("resume");
      expect(resumeAt).toBeGreaterThanOrEqual(0);
      expect(args[resumeAt + 1]).toBe("11111111-1111-1111-1111-111111111111");
      // resume <uuid> … -- <prompt>, with the prompt last.
      expect(args[args.length - 2]).toBe("--");
      expect(args[args.length - 1]).toBe("--fix the enum");
      expect(args.lastIndexOf("--")).toBeGreaterThan(resumeAt + 1);
    } finally {
      rmSync(codexHome, { recursive: true, force: true });
    }
  });

  it("cursor-agent: prompt is guarded by `--` (commander, verified)", () => {
    const term = makeFakeTerm();
    // cursorDir MUST be isolated: without it the spawn writes the developer's
    // real ~/.cursor/hooks.json with a Bun.main test-file hook command.
    const cursorDir = mkdtempSync(join(tmpdir(), "cursor-home-"));
    try {
      const sm = new SessionManager({
        projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
        agentSpec: { command: "cursor-agent", name: "cursor-agent" },
        sendMessage: () => {},
        cursorDir,
      });
      const s = sm.create(undefined, { tool: "cursor-agent" });
      sm.start(s.id, "--fix the enum");
      const args = term.spawns[0].args!;
      expect(args).toContain("--trust");
      expect(args[args.length - 2]).toBe("--");
      expect(args[args.length - 1]).toBe("--fix the enum");
      expect(existsSync(join(cursorDir, "hooks.json"))).toBe(true);
    } finally {
      rmSync(cursorDir, { recursive: true, force: true });
    }
  });

  it("opencode gets --prompt <text>", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { tool: "opencode" });
    sm.start(s.id, "do the thing");
    const args = term.spawns[0].args!;
    const i = args.indexOf("--prompt");
    expect(i).toBeGreaterThanOrEqual(0);
    expect(args[i + 1]).toBe("do the thing");
  });

  it("custom command: prompt is ignored entirely", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { command: "my-agent --serve" });
    sm.start(s.id, "should not appear");
    const spawn = term.spawns[0];
    expect(spawn.command).toBe("my-agent --serve");
    expect(spawn.args ?? []).toEqual([]);
  });

  it("restart WITHOUT a prompt never re-fires the previous one (not persisted)", () => {
    const term = makeFakeTerm();
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "claude", name: "claude-code" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { tool: "claude-code" });
    sm.start(s.id, "first launch prompt");
    sm.stop(s.id);
    sm.start(s.id);
    const second = term.spawns[1];
    expect(JSON.stringify(second)).not.toContain("first launch prompt");
  });

  it("chat mode passes initialPrompt through onStartChat", () => {
    const seen: Array<{ sessionId: string; initialPrompt?: string }> = [];
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
      onStartChat: (opts) => { seen.push(opts); },
    });
    const s = sm.create(undefined, { tool: "codex", mode: "chat" });
    sm.start(s.id, "hello agent");
    expect(seen[0].initialPrompt).toBe("hello agent");
  });

  it("isDefaultSessionName recognizes only unedited 'Session N' names", () => {
    expect(isDefaultSessionName("Session 1")).toBe(true);
    expect(isDefaultSessionName("Session 42")).toBe(true);
    expect(isDefaultSessionName("Antigravity")).toBe(false);
    expect(isDefaultSessionName("Casual Greeting And Introduction")).toBe(false);
    expect(isDefaultSessionName("Session")).toBe(false);
    expect(isDefaultSessionName("Session 1 extra")).toBe(false);
    expect(isDefaultSessionName("")).toBe(false);
  });

  it("findSlotByAgentSession maps an agent conversation id back to its slot", () => {
    const sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: makeFakeTerm() as any,
      agentSpec: { command: "agy", name: "antigravity" },
      sendMessage: () => {},
    });
    const s = sm.create(undefined, { tool: "antigravity" });
    sm.setAgentSession(s.id, "conv-123");
    expect(sm.findSlotByAgentSession("conv-123")).toBe(s.id);
    expect(sm.findSlotByAgentSession("no-such-conv")).toBeUndefined();
  });
});
