import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";

// Every fork here takes the NATIVE argv path (terminal mode + a reported
// agentSessionId), so none of them reads a transcript — `getScrollback` is
// present only so a regression that reaches for it fails loudly rather than on
// a missing method.
function makeTerm() {
  const spawned = new Set<string>();
  return {
    spawn: (cfg: { terminalId?: string }) => { spawned.add(cfg.terminalId!); return cfg.terminalId!; },
    kill: (id: string) => { spawned.delete(id); },
    forget: (id: string) => { spawned.delete(id); },
    treeKilled: () => Promise.resolve(),
    has: (id: string) => spawned.has(id),
    getScrollback: () => null,
  };
}

function makeManager(dir: string) {
  return new SessionManager({
    projectId: "p1", storeDir: dir, projectPath: dir,
    terminalManager: makeTerm() as any,
    agentSpec: { command: "claude", name: "claude-code" },
    sendMessage: () => {},
  });
}

describe("SessionManager.fork naming and provenance", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-fork-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("names a fork after its source and records where it came from", async () => {
    const sm = makeManager(dir);
    const source = sm.create("Auth refactor");
    sm.setAgentSession(source.id, "native-1");

    const first = await sm.fork(source.id, "current");
    expect(first.name).toBe("Auth refactor fork");
    expect(first.forkedFromSessionId).toBe(source.id);

    const second = await sm.fork(source.id, "current");
    expect(second.name).toBe("Auth refactor fork 2");

    // A fork of a fork is still a fork of the same work: the suffix is stripped
    // before it is re-applied, so the name never grows "fork fork".
    sm.setAgentSession(first.id, "native-2");
    const nested = await sm.fork(first.id, "current");
    expect(nested.name).toBe("Auth refactor fork 3");
    expect(nested.forkedFromSessionId).toBe(first.id);
  });

  it("leaves the derived name auto-nameable so the agent's own title still wins", async () => {
    const sm = makeManager(dir);
    const source = sm.create("Auth refactor");
    sm.setAgentSession(source.id, "native-1");

    const forked = await sm.fork(source.id, "current");
    expect(sm.isAutoNameable(forked.id)).toBe(true);
    sm.applyAutoName(forked.id, "Rotate the signing key");
    expect(sm.list().find((e) => e.id === forked.id)?.name).toBe("Rotate the signing key");
  });

  it("keeps provenance across a reload, so a renamed fork still knows its source", async () => {
    const sm = makeManager(dir);
    const source = sm.create("Auth refactor");
    sm.setAgentSession(source.id, "native-1");
    const forked = await sm.fork(source.id, "current");
    sm.rename(forked.id, "Something else entirely");
    sm.flushNow();

    const reloaded = makeManager(dir);
    const row = reloaded.list().find((e) => e.id === forked.id);
    expect(row?.name).toBe("Something else entirely");
    expect(row?.forkedFromSessionId).toBe(source.id);
  });
});
