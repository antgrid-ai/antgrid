import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

const dirs: string[] = [];
function store() { const d = mkdtempSync(join(tmpdir(), "ab-sma-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

function captureTm() {
  const spawns: any[] = [];
  return { spawns, has: () => false, kill: () => {}, treeKilled: () => Promise.resolve(), spawn: (cfg: any) => { spawns.push(cfg); return cfg.terminalId; } } as any;
}

test("starting a codex tool session injects the notify -c override", () => {
  const tm = captureTm();
  const sm = new SessionManager({
    projectId: "p1", storeDir: store(), projectPath: "/tmp",
    terminalManager: tm, agentSpec: { command: "claude", name: "claude" }, sendMessage: () => {},
  });
  const s = sm.create(undefined, { tool: "codex" });
  sm.start(s.id);
  const spawned = tm.spawns[0];
  expect(spawned.args).toContain("-c");
  expect(spawned.args.some((a: string) => a.startsWith('notify=[') && a.includes('"hook"'))).toBe(true);
  expect(spawned.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
});

test("starting a claude tool session injects --plugin-dir", () => {
  const tm = captureTm();
  const sm = new SessionManager({
    projectId: "p1", storeDir: store(), projectPath: "/tmp",
    terminalManager: tm, agentSpec: { command: "claude", name: "claude" }, sendMessage: () => {},
  });
  const s = sm.create(undefined, { tool: "claude-code" });
  sm.start(s.id);
  expect(tm.spawns[0].args).toContain("--plugin-dir");
});

// The most fragile path the feature adds: a codex session WITH per-session args
// folds base + the augmenter's bridge-backed `-c notify=[...]` title token + injected
// hook `-c` flags (hooks.Stop/PermissionRequest/SessionStart + trusted_hash state)
// into one shell-quoted command line. Guard that both the title token and the hook
// injection survive quoting together, and that the user's args stay last.
test("codex session with per-session args folds the quoted notify token into the command line", () => {
  const tm = captureTm();
  const sm = new SessionManager({
    projectId: "p1", storeDir: store(), projectPath: "/tmp",
    terminalManager: tm, agentSpec: { command: "claude", name: "claude" }, sendMessage: () => {},
  });
  const s = sm.create(undefined, { tool: "codex", args: "exec demo" });
  sm.start(s.id);
  const spawned = tm.spawns[0];
  // args were folded into `command`, so the direct argv is empty.
  expect(spawned.args).toEqual([]);
  expect(spawned.command.startsWith("codex ")).toBe(true);
  expect(spawned.command).toContain("notify=");
  expect(spawned.command).toContain("hooks.Stop=");
  expect(spawned.command).toContain("trusted_hash=");
  expect(spawned.command.endsWith("exec demo")).toBe(true);
});
