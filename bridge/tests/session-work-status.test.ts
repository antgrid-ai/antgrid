import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import type { WorkStatus } from "../src/protocol";

// SessionManager does not fold work status — the owning core's reduction
// (work-status.ts) is the only one, and this stamps its answer onto each
// session:updated entry. What the REDUCTION decides is covered by
// work-status.test.ts; these cover the seam, which is where a second source of
// truth would creep back in.

function makeTerm() {
  const live = new Set<string>();
  return {
    spawn: (cfg: { terminalId?: string }) => { live.add(cfg.terminalId!); return cfg.terminalId!; },
    kill: (_id: string) => {},
    has: (id: string) => live.has(id),
    exit: (id: string) => { live.delete(id); },
  };
}

describe("per-session work status on the wire", () => {
  let dir: string;
  let term: ReturnType<typeof makeTerm>;
  let statuses: Map<string, WorkStatus>;
  let sm: SessionManager;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-swork-"));
    term = makeTerm();
    statuses = new Map();
    sm = new SessionManager({
      projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
      sessionWorkStatusFor: (id) => statuses.get(id),
    });
  });
  afterEach(() => {
    sm.flushNow();
    rmSync(dir, { recursive: true, force: true });
  });

  it("stamps the reduction's answer onto the entry", () => {
    const s = sm.create("a", { tool: "codex" });
    statuses.set(s.id, "attention");
    expect(sm.get(s.id)?.workStatus).toBe("attention");
  });

  it("lands on the session the reduction named and no other", () => {
    const a = sm.create("a", { tool: "codex" });
    const b = sm.create("b", { tool: "codex" });
    statuses.set(a.id, "attention");
    expect(sm.get(a.id)?.workStatus).toBe("attention");
    expect(sm.get(b.id)?.workStatus).toBeUndefined();
  });

  it("carries no status for a session the reduction has no entry for", () => {
    // The reduction files a status only for RUNNING sessions, so this is the
    // stopped case — it reaches the app as null, "the bridge didn't say", and a
    // mode flip does not restart a stopped session anyway.
    const s = sm.create("a", { tool: "codex" });
    sm.start(s.id);
    expect(sm.get(s.id)?.workStatus).toBeUndefined();
  });

  it("advertises no status at all when nothing injected a provider", () => {
    // A bare core with no owning ProjectCore. Absent is the honest answer; a
    // default would be this file inventing a second source of truth.
    const bare = new SessionManager({
      projectId: "p2", storeDir: dir, projectPath: dir, terminalManager: term as any,
      agentSpec: { command: "codex", name: "codex" },
      sendMessage: () => {},
    });
    const s = bare.create("a", { tool: "codex" });
    expect(bare.get(s.id)?.workStatus).toBeUndefined();
    bare.flushNow();
  });

  it("re-emits the session list when the owner reports the reduction moved", async () => {
    // Work status changes far more often than the list does, so without this the
    // stamped value would sit stale until an unrelated session change.
    sm.create("a", { tool: "codex" });
    let emits = 0;
    sm.onChange(() => { emits++; });
    sm.refreshWorkStatus();
    // Deferred so the emit doesn't nest inside the publish that triggered it.
    expect(emits).toBe(0);
    await Promise.resolve();
    expect(emits).toBe(1);
  });
});
