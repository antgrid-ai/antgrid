import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import { HandlerEngine } from "../src/handler/engine";
import type { AbMessage } from "../src/protocol";

// A mode flip is stop → flip → start on ONE session id, and both teardown
// signals land asynchronously: the PTY's exit callback and the driver's dispose
// promise. Every assertion here is about WHEN the old runtime's teardown lands
// relative to the new runtime's construction; an outcome-only check passes on a
// lucky interleaving. The wiring below mirrors agent-core's exactly (its
// TerminalManager.onTerminalExited callback and its onStopChat), because the
// hazard lives in that wiring and not in SessionManager alone.

const GOAL = "Migrating auth";
const BACKLOG = [{ id: "i1", text: "run the tests", status: "queued" as const, createdAt: 1 }];

const tick = () => new Promise((r) => setTimeout(r, 0));

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => { resolve = r; });
  return { promise, resolve };
}

interface CoreOpts {
  /** The driver-dispose promise onStopChat hands back. Absent → nothing to await. */
  chatTeardown?: () => Promise<void> | void;
  teardownTimeoutMs?: number;
}

function makeCore(dir: string, opts: CoreOpts = {}) {
  const order: string[] = [];
  const sent: AbMessage[] = [];
  const spawns: Array<{ terminalId?: string }> = [];
  const live = new Set<string>();

  // kill() is fire-and-forget in the real TerminalManager — the session stays in
  // `has()` until the exit handler runs, which is the whole reason setMode has
  // to wait for something other than kill()'s return.
  const term = {
    spawn: (cfg: { terminalId?: string }) => {
      live.add(cfg.terminalId!);
      spawns.push(cfg);
      order.push("pty-spawn");
      return cfg.terminalId!;
    },
    kill: (_id: string) => { order.push("pty-kill"); },
    has: (id: string) => live.has(id),
  };

  const engine = new HandlerEngine({
    projectId: "proj",
    projectPath: dir,
    tool: () => "codex",
    abDir: dir,
    adapter: {
      injectReply: () => {},
      recentOutput: () => "",
      outputKind: () => "pty",
      transcriptPath: () => undefined,
      supportsSlashCommands: () => true,
    },
    sendAb: (m: AbMessage) => sent.push(m),
    loadConfigFn: () => ({ version: 2, defaultNotifyOnly: false }),
    appendActivityFn: () => {},
    loadSessionFn: () => null,
    saveSessionFn: (r: { armed: boolean }) => {
      if (!r.armed) order.push("handler-disarm");
    },
    now: () => 1000,
  } as never);

  const sessions = new SessionManager({
    projectId: "p1", storeDir: dir, projectPath: dir, terminalManager: term as any,
    agentSpec: { command: "codex", name: "codex" },
    sendMessage: () => {},
    teardownTimeoutMs: opts.teardownTimeoutMs,
    onStartChat: () => { order.push("chat-start"); },
    onStopChat: (id) => {
      // agent-core's order: reclaim the handler first, then hand back the
      // driver's dispose promise.
      engine.onTerminalExit(id, { keepArmed: sessions.isFlipping(id) });
      order.push("handler-exit");
      order.push("chat-stop");
      return opts.chatTeardown?.();
    },
  });

  /** The real `TerminalManager.onTerminalExited` callback agent-core installs. */
  const exitPty = (id: string) => {
    live.delete(id);
    order.push("pty-exit");
    sessions.noteExited(id);
    engine.onTerminalExit(id, { keepArmed: sessions.isFlipping(id) });
    // Marks the exit-driven handler teardown as COMPLETE. Not the disarm: a
    // flip suppresses that, and keying the ordering assertions on a side effect
    // one direction skips would stop them checking anything there.
    order.push("handler-exit");
  };

  const isArmed = (id: string): boolean => {
    engine.emitStatus();
    const status = sent.at(-1) as unknown as { sessions: Array<{ terminalId: string }> };
    return status.sessions.some((s) => s.terminalId === id);
  };

  return { sessions, engine, term, order, spawns, exitPty, isArmed };
}

describe("session mode flip — teardown ordering", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-flip-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  // Resolved 2026-07-31: a flip preserves the arming. The exit-driven disarm is
  // SUPPRESSED for the duration of the flip rather than undone afterwards —
  // disarm() persists the record unarmed and arm() rehydrates only from an
  // armed one, so a disarm/re-arm round trip would quietly reset the backlog,
  // armedAt and any open escalations.
  it("keeps an armed session armed across a terminal→chat flip", async () => {
    const c = makeCore(dir);
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.start(s.id);
    c.engine.arm({ terminalId: s.id, goal: GOAL, backlog: BACKLOG, notifyOnly: false });
    expect(c.isArmed(s.id)).toBe(true);

    const flip = c.sessions.setMode(s.id, "chat");
    await tick();
    c.exitPty(s.id);
    await flip;

    // The supervisor belongs to the session, not to the runtime the session
    // happens to be rendered on; a view change must not turn it off.
    expect(c.isArmed(s.id)).toBe(true);
    c.sessions.flushNow();
  });

  // `order` is compared with toEqual, so the suppressed disarm is asserted here
  // too: a regression that re-disarms on a flip appends "handler-disarm" and
  // fails these, not just the armed test above.
  it("runs the PTY's exit-driven teardown before the chat driver is constructed", async () => {
    const c = makeCore(dir);
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.start(s.id);
    c.engine.arm({ terminalId: s.id, goal: GOAL, backlog: BACKLOG, notifyOnly: false });

    const flip = c.sessions.setMode(s.id, "chat");
    await tick();
    // Nothing may be built on the new runtime while the old one's exit-driven
    // teardown (disarm, namer forget, port-detector drop) is still pending.
    expect(c.order).toEqual(["pty-spawn", "pty-kill"]);
    expect(c.sessions.get(s.id)?.mode).toBe("terminal");

    c.exitPty(s.id);
    await flip;

    expect(c.order).toEqual([
      "pty-spawn", "pty-kill", "pty-exit", "handler-exit", "chat-start",
    ]);
    expect(c.sessions.get(s.id)?.mode).toBe("chat");
    c.sessions.flushNow();
  });

  // The boundary of the exemption above. Without this, `keepArmed` defaulting
  // the wrong way — or a caller passing it unconditionally — would mean a dead
  // agent stays supervised forever, and nothing else in the suite would notice.
  it("still disarms when a PTY exits outside a flip", () => {
    const c = makeCore(dir);
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.start(s.id);
    c.engine.arm({ terminalId: s.id, goal: GOAL, backlog: BACKLOG, notifyOnly: false });
    expect(c.isArmed(s.id)).toBe(true);

    c.exitPty(s.id); // the agent died on its own, no setMode in flight

    expect(c.isArmed(s.id)).toBe(false);
    expect(c.order).toContain("handler-disarm");
    c.sessions.flushNow();
  });

  it("leaves no live PTY behind after a terminal→chat flip", async () => {
    const c = makeCore(dir);
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.start(s.id);

    const flip = c.sessions.setMode(s.id, "chat");
    await tick();
    c.exitPty(s.id);
    await flip;

    expect(c.term.has(s.id)).toBe(false);
    expect(c.spawns.length).toBe(1); // the pre-flip spawn only
    expect(c.sessions.get(s.id)?.running).toBe(true); // running, as chat
    c.sessions.flushNow();
  });

  it("does not spawn the PTY until the chat driver's teardown promise settles", async () => {
    const gate = deferred();
    const c = makeCore(dir, { chatTeardown: () => gate.promise });
    const s = c.sessions.create("c", { tool: "codex", mode: "chat" });
    c.sessions.start(s.id);
    c.engine.arm({ terminalId: s.id, goal: GOAL, backlog: BACKLOG, notifyOnly: false });

    const flip = c.sessions.setMode(s.id, "terminal");
    await tick();
    // Spawning here races codex's ~/.codex sqlite lock: the old driver only
    // releases it when its dispose settles, and the PTY path never consults
    // StructuredAgentManager's `stopping` map.
    expect(c.spawns.length).toBe(0);
    expect(c.order).toEqual(["chat-start", "handler-exit", "chat-stop"]);
    expect(c.sessions.get(s.id)?.mode).toBe("chat");

    c.order.push("chat-teardown-settled");
    gate.resolve();
    await flip;

    expect(c.order).toEqual([
      "chat-start", "handler-exit", "chat-stop", "chat-teardown-settled", "pty-spawn",
    ]);
    expect(c.sessions.get(s.id)?.mode).toBe("terminal");
    c.sessions.flushNow();
  });

  it("aborts the flip with mode unchanged when the PTY never exits", async () => {
    const c = makeCore(dir, { teardownTimeoutMs: 10 });
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.start(s.id);

    await expect(c.sessions.setMode(s.id, "chat")).rejects.toThrow(/timed out tearing down/);

    // Half-flipped is the state that must be impossible: the entry is still
    // terminal (post-session:stop, retryable), not chat-with-a-live-PTY.
    expect(c.sessions.get(s.id)?.mode).toBe("terminal");
    expect(c.order).toEqual(["pty-spawn", "pty-kill"]);
    c.sessions.flushNow();
  });

  it("aborts the flip with mode unchanged when the chat teardown never settles", async () => {
    const c = makeCore(dir, { chatTeardown: () => deferred().promise, teardownTimeoutMs: 10 });
    const s = c.sessions.create("c", { tool: "codex", mode: "chat" });
    c.sessions.start(s.id);

    await expect(c.sessions.setMode(s.id, "terminal")).rejects.toThrow(/timed out tearing down/);

    expect(c.sessions.get(s.id)?.mode).toBe("chat");
    expect(c.spawns.length).toBe(0);
    c.sessions.flushNow();
  });

  it("carries agentSessionId unchanged through a flip in both directions", async () => {
    const c = makeCore(dir);
    // claude-code with a real transcript: the id has to survive the resume
    // pre-flight that every terminal start() runs, or this asserts nothing.
    const transcript = join(dir, "transcript.jsonl");
    writeFileSync(transcript, "{}\n");
    const s = c.sessions.create("t", { tool: "claude-code" });
    c.sessions.setAgentSession(s.id, "thread-xyz", transcript);
    c.sessions.start(s.id);

    const toChat = c.sessions.setMode(s.id, "chat");
    await tick();
    c.exitPty(s.id);
    await toChat;
    expect(c.sessions.get(s.id)?.agentSessionId).toBe("thread-xyz");

    await c.sessions.setMode(s.id, "terminal");
    expect(c.sessions.get(s.id)?.agentSessionId).toBe("thread-xyz");
    c.sessions.flushNow();
  });

  it("flips a stopped session without tearing anything down or starting anything", async () => {
    const c = makeCore(dir, { chatTeardown: () => { throw new Error("must not tear down"); } });
    const s = c.sessions.create("t", { tool: "codex" });

    await c.sessions.setMode(s.id, "chat");

    expect(c.sessions.get(s.id)?.mode).toBe("chat");
    expect(c.sessions.get(s.id)?.running).toBe(false);
    expect(c.order).toEqual([]);
    c.sessions.flushNow();
  });

  it("treats a flip to the current mode as a no-op, keeping the runtime alive", async () => {
    const c = makeCore(dir);
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.start(s.id);

    await c.sessions.setMode(s.id, "terminal");

    expect(c.order).toEqual(["pty-spawn"]);
    expect(c.term.has(s.id)).toBe(true);
    c.sessions.flushNow();
  });

  it("refuses an archived session and never touches its runtime", async () => {
    const c = makeCore(dir);
    const s = c.sessions.create("t", { tool: "codex" });
    c.sessions.archive(s.id);

    await expect(c.sessions.setMode(s.id, "chat")).rejects.toThrow(/archived/);

    expect(c.sessions.list(true).find((e) => e.id === s.id)?.mode).toBe("terminal");
    expect(c.order).toEqual([]);
    c.sessions.flushNow();
  });
});
