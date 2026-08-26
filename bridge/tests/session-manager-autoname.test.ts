import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

function makeTm() {
  const live = new Set<string>();
  return {
    has: (id: string) => live.has(id),
    kill: (id: string) => { live.delete(id); },
    forget: (id: string) => { live.delete(id); },
    treeKilled: () => Promise.resolve(),
    spawn: (cfg: any) => { live.add(cfg.terminalId); return cfg.terminalId; },
    __live: live,
  } as any;
}

const dirs: string[] = [];
function newStore() { const d = mkdtempSync(join(tmpdir(), "ab-sm-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

function mk(storeDir: string, agentSpec = { command: "claude", name: "claude" }) {
  return new SessionManager({
    projectId: "p1", storeDir, projectPath: storeDir,
    terminalManager: makeTm(),
    agentSpec,
    sendMessage: () => {},
  });
}

describe("applyAutoName / manuallyRenamed", () => {
  test("auto-names a default-named session and emits", () => {
    const sm = mk(newStore());
    const s = sm.create();                 // "Session 1", manuallyRenamed=false
    let emitted = 0; sm.onChange(() => emitted++);
    sm.applyAutoName(s.id, "Fix login bug");
    expect(sm.get(s.id)!.name).toBe("Fix login bug");
    expect(emitted).toBeGreaterThan(0);
  });

  test("manual rename stops auto-naming permanently", () => {
    const sm = mk(newStore());
    const s = sm.create();
    sm.rename(s.id, "My name");
    sm.applyAutoName(s.id, "Agent title");
    expect(sm.get(s.id)!.name).toBe("My name");
  });

  test("explicit name at create is treated as manual", () => {
    const sm = mk(newStore());
    const s = sm.create("Picked name");
    sm.applyAutoName(s.id, "Agent title");
    expect(sm.get(s.id)!.name).toBe("Picked name");
  });

  test("unknown id and unchanged name are no-ops (no emit)", () => {
    const sm = mk(newStore());
    const s = sm.create();
    let emitted = 0; sm.onChange(() => emitted++);
    sm.applyAutoName("nope", "x");
    sm.applyAutoName(s.id, "Session 1");   // unchanged
    expect(emitted).toBe(0);
  });

  // A default-spec (antgrid.yaml) session carries no per-session `tool`, which is
  // why agent-core's OSC-title policy resolves the agent through `agentKeyFor`
  // (entry.tool ?? config.agent.tool) rather than off the entry — reading the
  // entry alone would misread agy's exe-path OSC title as a usable name.
  test("a default-spec session carries no per-session tool", () => {
    const sm = mk(newStore(), { command: "agy", name: "antigravity" });
    const s = sm.create();                         // no spec.tool → default spec
    expect(sm.get(s.id)!.tool).toBeUndefined();
    expect(sm.create(undefined, { tool: "claude-code" }).tool).toBe("claude-code");
  });

  test("migration: legacy file without manuallyRenamed backfills from name pattern", () => {
    const store = newStore();
    const dir = join(store, "agents", "p1"); mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "sessions.json"), JSON.stringify({
      version: 1,
      sessions: [
        { id: "a", name: "Session 3", createdAt: 1, lastUsedAt: 1, archived: false },
        { id: "b", name: "Hand named", createdAt: 1, lastUsedAt: 1, archived: false },
      ],
    }));
    const sm = mk(store);
    sm.applyAutoName("a", "auto A");   // default name → not manual → follows
    sm.applyAutoName("b", "auto B");   // custom name → manual → ignored
    expect(sm.get("a")!.name).toBe("auto A");
    expect(sm.get("b")!.name).toBe("Hand named");
  });
});
