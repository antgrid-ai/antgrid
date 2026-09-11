import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import { Database } from "bun:sqlite";

function makeTm() {
  const live = new Set<string>();
  const spawns: any[] = [];
  return {
    has: (id: string) => live.has(id),
    kill: (id: string) => { live.delete(id); },
    forget: (id: string) => { live.delete(id); },
    treeKilled: () => Promise.resolve(),
    spawn: (cfg: any) => { live.add(cfg.terminalId); spawns.push(cfg); return cfg.terminalId; },
    __spawns: spawns,
  } as any;
}

const dirs: string[] = [];
function newStore() { const d = mkdtempSync(join(tmpdir(), "ab-sm-resume-")); dirs.push(d); return d; }
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

// `extra` lets later tests inject opts (e.g. an isolated `codexHome` so the
// availability hints can't read the dev machine's real ~/.codex).
function mk(storeDir: string, tm = makeTm(), extra: Record<string, unknown> = {}) {
  return new SessionManager({
    projectId: "p1", storeDir, projectPath: storeDir,
    terminalManager: tm,
    agentSpec: { command: "claude", name: "claude" },
    sendMessage: () => {},
    ...extra,
  });
}

describe("setAgentSession persistence", () => {
  test("overwrite-latest stores id + transcript and survives reload", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-aaa", "/t/a.jsonl");
    sm.setAgentSession(s.id, "sess-bbb", "/t/b.jsonl"); // latest wins
    sm.flushNow();

    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    const row = raw.sessions.find((r: any) => r.id === s.id);
    expect(row.agentSessionId).toBe("sess-bbb");
    expect(row.agentTranscriptPath).toBe("/t/b.jsonl");
  });

  test("setAgentSession is a no-op for unknown ids", () => {
    const sm = mk(newStore());
    expect(() => sm.setAgentSession("nope", "x")).not.toThrow();
  });

  // The regression this guard exists for: codex's TUI runs ephemeral helper
  // threads (its reopen "catch-up" blurb) that never reach the thread store, and
  // one reporting at turn end used to overwrite the user's real thread with an
  // id `codex resume` exits 1 on. Observed on codex 0.153.4.
  test("a codex thread its own store disowns cannot displace the real one", () => {
    const store = newStore();
    const db = new Database(join(store, "state_5.sqlite"));
    db.run("CREATE TABLE threads (id TEXT PRIMARY KEY)");
    db.query("INSERT INTO threads (id) VALUES (?)").run("real-thread");
    db.close();
    const sm = mk(store, makeTm(), { codexHome: store });
    const s = sm.create("Codex", { tool: "codex" });
    sm.setAgentSession(s.id, "real-thread");
    sm.setAgentSession(s.id, "ephemeral-helper-thread");
    expect((sm.get(s.id) as any).agentSessionId).toBe("real-thread");
  });

  // The other half of the narrowing: a FIRST report displaces nothing, and
  // codex's after-agent post is the only chance it ever gives us to learn a
  // thread. Refusing one whose row has not reached the store yet would leave
  // the session with no identity at all — every later report carries the same
  // id, so the refusal would repeat forever.
  test("a first codex report is taken even where the store answers without it", () => {
    const store = newStore();
    const db = new Database(join(store, "state_5.sqlite"));
    db.run("CREATE TABLE threads (id TEXT PRIMARY KEY)");
    db.query("INSERT INTO threads (id) VALUES (?)").run("someone-elses-thread");
    db.close();
    const sm = mk(store, makeTm(), { codexHome: store });
    const s = sm.create("Codex", { tool: "codex" });
    expect(sm.setAgentSession(s.id, "brand-new-thread")).toBe(true);
    expect((sm.get(s.id) as any).agentSessionId).toBe("brand-new-thread");
  });

  // The refusal is what agent-core gates its title release on, so it has to be
  // legible to the caller — a void return let a disowned id go on renaming the
  // slot it was just refused for.
  test("the return value distinguishes a refusal from an unknown slot", () => {
    const store = newStore();
    const db = new Database(join(store, "state_5.sqlite"));
    db.run("CREATE TABLE threads (id TEXT PRIMARY KEY)");
    db.query("INSERT INTO threads (id) VALUES (?)").run("real-thread");
    db.close();
    const sm = mk(store, makeTm(), { codexHome: store });
    const s = sm.create("Codex", { tool: "codex" });
    expect(sm.setAgentSession(s.id, "real-thread")).toBe(true);
    expect(sm.setAgentSession(s.id, "real-thread")).toBe(true); // unchanged is still held
    expect(sm.setAgentSession(s.id, "ephemeral-helper-thread")).toBe(false);
    expect(sm.setAgentSession("no-such-slot", "real-thread")).toBe(false);
  });

  // Only a POSITIVE denial refuses. An unreadable store cannot distinguish a
  // helper thread from the user's own, and refusing on it would leave a brand
  // new session with no identity at all.
  test("an unreadable codex store still accepts what the agent reports", () => {
    const store = newStore();
    const sm = mk(store, makeTm(), { codexHome: join(store, "no-such-codex") });
    const s = sm.create("Codex", { tool: "codex" });
    sm.setAgentSession(s.id, "thread-1");
    expect((sm.get(s.id) as any).agentSessionId).toBe("thread-1");
  });

  // Was asserted absent when the id was bridge-internal (resume args only).
  // The app now gates chat-transcript hydration on it, so the wire entry must
  // carry it — withholding it renders an empty transcript for a session started
  // on another device. agentTranscriptPath stays internal: a local FS path no
  // client consumes.
  test("agentSessionId is exposed on the wire entry; the transcript path is not", () => {
    const sm = mk(newStore());
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-aaa", "/t/a.jsonl");
    expect((sm.get(s.id) as any).agentSessionId).toBe("sess-aaa");
    expect((sm.list(true)[0] as any).agentSessionId).toBe("sess-aaa");
    expect((sm.get(s.id) as any).agentTranscriptPath).toBeUndefined();
  });
});

describe("start() resume wiring", () => {
  // Seeds `threads` so the store can answer, and returns a handle that can drop
  // a row again — the difference between "codex disowns this thread" and "codex
  // could not be asked" decides every assertion in this block.
  function codexThreads(store: string, ids: string[]) {
    const db = new Database(join(store, "state_5.sqlite"));
    db.run("CREATE TABLE threads (id TEXT PRIMARY KEY)");
    for (const id of ids) db.query("INSERT INTO threads (id) VALUES (?)").run(id);
    db.close();
    return {
      drop(id: string) {
        const d = new Database(join(store, "state_5.sqlite"));
        d.query("DELETE FROM threads WHERE id = ?").run(id);
        d.close();
      },
    };
  }

  test.each(["terminal", "chat"] as const)("Codex %s resumes a thread the store still holds", (mode) => {
    const store = newStore();
    codexThreads(store, ["saved-thread"]);
    const tm = makeTm();
    const calls: Array<{ resumeId?: string }> = [];
    const opts = { codexHome: store, onStartChat: (o: { resumeId?: string }) => calls.push(o) };
    const sm = mk(store, tm, opts);
    const session = sm.create("Codex", { tool: "codex", mode });
    sm.setAgentSession(session.id, "saved-thread");
    sm.flushNow();
    const restored = mk(store, tm, opts);
    restored.start(session.id);
    if (mode === "terminal") {
      expect(tm.__spawns.at(-1).args.slice(-2)).toEqual(["resume", "saved-thread"]);
      expect(tm.__spawns.at(-1).suppressOscNotifications).toBe(false);
    } else {
      expect(calls[0].resumeId).toBe("saved-thread");
    }
    restored.flushNow();
    expect(mk(store).get(session.id)?.agentSessionId).toBe("saved-thread");
  });

  // `codex resume <id-it-disowns>` exits 1 within seconds and the app is left on
  // a session that never loads, so the launch drops the argument — but the id
  // stays on disk, because a store that loses a thread today may hold it again
  // tomorrow and clearing it in place is what used to cost a real conversation.
  test.each(["terminal", "chat"] as const)("Codex %s stops resuming a disowned thread without forgetting it", (mode) => {
    const store = newStore();
    const threads = codexThreads(store, ["saved-thread"]);
    const tm = makeTm();
    const calls: Array<{ resumeId?: string }> = [];
    const opts = { codexHome: store, onStartChat: (o: { resumeId?: string }) => calls.push(o) };
    const sm = mk(store, tm, opts);
    const session = sm.create("Codex", { tool: "codex", mode });
    sm.setAgentSession(session.id, "saved-thread");
    sm.flushNow();

    threads.drop("saved-thread");
    const restored = mk(store, tm, opts);
    restored.start(session.id);
    if (mode === "terminal") {
      expect(tm.__spawns.at(-1).args).not.toContain("resume");
      expect(tm.__spawns.at(-1).args).not.toContain("saved-thread");
    } else {
      expect(calls[0].resumeId).toBeUndefined();
    }
    restored.flushNow();
    expect(mk(store).get(session.id)?.agentSessionId).toBe("saved-thread");
  });

  test("claude resume appends --resume to the spawn args", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm);
    const s = sm.create("Slot", { tool: "claude-code" });
    // Stored id + a transcript that exists → resumable.
    const tp = join(store, "tx.jsonl"); writeFileSync(tp, "{}");
    sm.setAgentSession(s.id, "sess-xyz", tp);
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    expect(spawn.args).toContain("--resume");
    expect(spawn.args).toContain("sess-xyz");
  });

  test("codex resume appends the subcommand AFTER the global -c flags", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm, { codexHome: join(store, "no-such-codex") });
    const s = sm.create("Slot", { tool: "codex" });
    sm.setAgentSession(s.id, "uuid-1"); // no transcript path → codex preflight via codexHome
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    const args: string[] = spawn.args;
    expect(args).toContain("resume");
    expect(args.at(-2)).toBe("resume");
    expect(args.at(-1)).toBe("uuid-1");
    // global -c flags precede the subcommand
    expect(args.indexOf("-c")).toBeLessThan(args.indexOf("resume"));
  });

  test("a missing transcript preserves the saved identity and attempts native resume", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-dead", "/no/such/file.jsonl");
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    expect(spawn.args).toContain("--resume");
    expect(spawn.args).toContain("sess-dead");
    sm.flushNow();
    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    expect(raw.sessions.find((r: any) => r.id === s.id).agentSessionId).toBe("sess-dead");
  });

  test("resume args fold into the command line when per-session args are set", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm);
    const s = sm.create("Slot", { tool: "claude-code", args: "--model opus" });
    const tp = join(store, "tx.jsonl"); writeFileSync(tp, "{}");
    sm.setAgentSession(s.id, "sess-fold", tp);
    sm.start(s.id);
    const spawn = tm.__spawns.at(-1);
    // folded path: everything in `command`, spawnArgs empty
    expect(spawn.command).toContain("--resume sess-fold");
    expect(spawn.command).toContain("--model opus");
    expect(spawn.args).toEqual([]);
  });

  test("codex resume subcommand lands AFTER per-session args in the folded path", () => {
    const store = newStore();
    const tm = makeTm();
    const sm = mk(store, tm, { codexHome: join(store, "no-such-codex") });
    const s = sm.create("Slot", { tool: "codex", args: "--model gpt-5" });
    sm.setAgentSession(s.id, "uuid-1"); // no path → preflight via codexHome (null → optimistic)
    sm.start(s.id);
    const cmd: string = tm.__spawns.at(-1).command;
    // codex requires `… <global flags> <user flags> resume <uuid>`: the
    // subcommand must be last, never followed by the user's flags.
    expect(cmd.indexOf("--model gpt-5")).toBeLessThan(cmd.indexOf("resume uuid-1"));
    expect(cmd.trimEnd().endsWith("resume uuid-1")).toBe(true);
    expect(tm.__spawns.at(-1).args).toEqual([]);
  });
});

describe("setAgentSession transcript-path retention", () => {
  test("a later path-less report keeps the captured path for the same session", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-1", "/t/real.jsonl");
    sm.setAgentSession(s.id, "sess-1"); // SessionStart-style, no path
    sm.flushNow();
    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    const row = raw.sessions.find((r: any) => r.id === s.id);
    expect(row.agentSessionId).toBe("sess-1");
    expect(row.agentTranscriptPath).toBe("/t/real.jsonl"); // retained, not wiped
  });

  test("a new session id resets the path", () => {
    const store = newStore();
    const sm = mk(store);
    const s = sm.create("Slot", { tool: "claude-code" });
    sm.setAgentSession(s.id, "sess-1", "/t/real.jsonl");
    sm.setAgentSession(s.id, "sess-2"); // switched conversations, no path yet
    sm.flushNow();
    const raw = JSON.parse(readFileSync(join(store, "agents", "p1", "sessions.json"), "utf8"));
    const row = raw.sessions.find((r: any) => r.id === s.id);
    expect(row.agentSessionId).toBe("sess-2");
    expect(row.agentTranscriptPath).toBeUndefined();
  });
});
