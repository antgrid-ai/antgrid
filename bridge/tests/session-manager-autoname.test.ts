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

// The bug: every guard against re-naming a session lived in memory, so a
// stop/start renamed a session we had already titled — and not back to the same
// title, because the transcript read returns the LAST few messages, so the new
// name described wherever the conversation had drifted to.
describe("a generated title survives a restart", () => {
  const TP = "tx.jsonl";

  /** A claude-code session whose conversation is resumable: `start()` resumes it
   *  only while the transcript it names still exists. */
  function resumableSession(sm: SessionManager, store: string) {
    const s = sm.create(undefined, { tool: "claude-code" });
    const path = join(store, TP);
    writeFileSync(path, "{}");
    sm.setAgentSession(s.id, "sess-1", path);
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    return s;
  }

  test("only a name worth protecting is final", () => {
    const sm = mk(newStore());
    const s = sm.create();
    expect(sm.hasFinalAutoTitle(s.id)).toBe(false);
    sm.applyAutoName(s.id, "open this file for me", "first-message");
    expect(sm.hasFinalAutoTitle(s.id)).toBe(false);
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    expect(sm.hasFinalAutoTitle(s.id)).toBe(true);
  });

  test("the rank is written beside the name and reloads with it", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create();
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    sm.flushNow();

    const reloaded = mk(store);
    expect(reloaded.get(s.id)!.name).toBe("Fix S3 retry backoff");
    expect(reloaded.hasFinalAutoTitle(s.id)).toBe(true);
  });

  // The rename a restart used to perform BEFORE the model spawn: the native read
  // repeats the opening prompt on every turn, and after a reload nothing in
  // memory ranked it below the name it was about to replace.
  test("the opening prompt cannot displace it after a reload", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create();
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    sm.flushNow();

    const reloaded = mk(store);
    reloaded.applyAutoName(s.id, "hey can you look at the retry code", "first-message");
    reloaded.applyAutoName(s.id, "bash - claude", undefined); // OSC chrome
    expect(reloaded.get(s.id)!.name).toBe("Fix S3 retry backoff");
  });

  test("a rename typed at the agent does displace it, and then holds", () => {
    const sm = mk(newStore());
    const s = sm.create();
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    sm.applyAutoName(s.id, "Release blockers", "manual");
    expect(sm.get(s.id)!.name).toBe("Release blockers");
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    expect(sm.get(s.id)!.name).toBe("Release blockers");
  });

  test("a manual rename releases the rank along with the name", () => {
    const sm = mk(newStore());
    const s = sm.create();
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");
    sm.rename(s.id, "Mine");
    expect(sm.hasFinalAutoTitle(s.id)).toBe(false);
  });

  // Claude's --resume copies the transcript into a new file and appends under a
  // FRESH id, so the same thread comes back under a different name. Reading that
  // rotation as a new conversation is what spent a model call on every restart.
  test("a resumed launch keeps the title through the id it comes back under", () => {
    const store = newStore();
    const sm = mk(store);
    const s = resumableSession(sm, store);

    sm.start(s.id);
    sm.setAgentSession(s.id, "sess-2", join(store, TP));
    expect(sm.hasFinalAutoTitle(s.id)).toBe(true);
    expect(sm.get(s.id)!.name).toBe("Fix S3 retry backoff");
  });

  test("a launch that resumes nothing starts a conversation the name is not about", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create(undefined, { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-dead", "/no/such/file.jsonl");
    sm.applyAutoName(s.id, "Fix S3 retry backoff", "self");

    sm.start(s.id); // transcript gone → no resume argv → fresh conversation
    expect(sm.hasFinalAutoTitle(s.id)).toBe(false);
  });

  test("a new conversation under the running agent releases it", () => {
    const store = newStore();
    const sm = mk(store);
    const s = resumableSession(sm, store);

    sm.start(s.id);
    sm.setAgentSession(s.id, "sess-2", join(store, TP)); // the resume's own id
    sm.setAgentSession(s.id, "sess-3", join(store, TP)); // `/clear`
    expect(sm.hasFinalAutoTitle(s.id)).toBe(false);
  });

  // An agent whose resume keeps the id reports one that matches. The claim has
  // to be spent on that report all the same, or the NEXT rotation — a real
  // `/clear` — is mistaken for this launch's resume and keeps a stale name.
  test("a resume reporting the same id still spends the claim", () => {
    const store = newStore();
    const sm = mk(store);
    const s = resumableSession(sm, store);

    sm.start(s.id);
    sm.setAgentSession(s.id, "sess-1", join(store, TP));
    sm.setAgentSession(s.id, "sess-2", join(store, TP));
    expect(sm.hasFinalAutoTitle(s.id)).toBe(false);
  });

  // A row written before the rank existed cannot say which signal named it, and
  // guessing "generated" would freeze it against ever being named properly.
  test("a legacy row is not treated as already titled", () => {
    const store = newStore();
    const dir = join(store, "agents", "p1"); mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "sessions.json"), JSON.stringify({
      version: 1,
      sessions: [{ id: "a", name: "Session 3", createdAt: 1, lastUsedAt: 1, archived: false }],
    }));
    expect(mk(store).hasFinalAutoTitle("a")).toBe(false);
  });
});
