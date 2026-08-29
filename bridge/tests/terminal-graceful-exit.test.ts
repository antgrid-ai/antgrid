// An agent is asked to leave before it is killed, on every platform and on
// every teardown path — and the sweep that follows the ask is unconditional, so
// the ask can never cost the process tree.
//
// The two halves of the ladder are exercised by DIFFERENT platforms and neither
// can stand in for the other: POSIX signals a process group, Windows writes a
// keystroke into a ConPTY and leans on a pre-ask snapshot plus the kill-on-close
// job for the reach a departing leader takes with it. CI runs this suite on
// ubuntu only, so the Windows cases below are developer-machine cases and the
// source-invariant ones are what gate the Windows behaviour in CI.
import { describe, test, expect } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { TerminalManager, gracefulBudget } from "../src/terminal-manager";
import { TerminalSession, AGENT_GRACE_MS, WINDOWS_SHUTDOWN_GRACE_MS } from "../src/terminal-session";
import { AGENTS } from "../src/agents/registry";
import { ETX } from "../src/agents/types";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

const isWin = process.platform === "win32";
const posixOnly = test.skipIf(isWin);
const windowsOnly = test.skipIf(!isWin);

/** POSIX process state, by whichever route this system offers: `/proc` on
 *  Linux, `ps` on macOS, and neither in a slim container image. `undefined`
 *  means unknowable, never dead. `comm` is parenthesised and may itself contain
 *  spaces or parens, so the state is read after the LAST `)`. */
function processState(pid: number): string | undefined {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    return stat.slice(stat.lastIndexOf(")") + 1).trim().charAt(0) || undefined;
  } catch {
    // No /proc, or the process is already reaped; `ps` answers the first case.
  }
  const ps = spawnSync("ps", ["-o", "state=", "-p", String(pid)], { encoding: "utf8" });
  if (ps.error || ps.status !== 0) return undefined;
  return ps.stdout.trim().charAt(0) || undefined;
}

/** A zombie is not alive, and `kill(pid, 0)` cannot tell the difference: the
 *  pid survives until someone reaps it. Whoever spawned the killed process is
 *  usually that someone, but when the runner is PID 1 — any container without
 *  an init — nobody is, and a successful kill would read here as survival. */
function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  if (isWin) return true;
  return processState(pid) !== "Z";
}

async function waitFor<T>(probe: () => T | undefined, timeoutMs: number): Promise<T | undefined> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = probe();
    if (value !== undefined) return value;
    if (Date.now() >= deadline) return undefined;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

function readWhenWritten(path: string): string | undefined {
  try {
    const text = readFileSync(path, "utf8").trim();
    return text.length > 0 ? text : undefined;
  } catch {
    return undefined;
  }
}

function tempDir(tag: string): string {
  return mkdtempSync(join(tmpdir(), `antgrid-grace-${tag}-`));
}

function writeScript(dir: string, name: string, body: string): string {
  const path = join(dir, name);
  writeFileSync(path, body);
  return path;
}

/** A terminal that answers nothing this suite sends it: on POSIX it ignores
 *  SIGTERM and loops, on Windows it is a plain sleeper in cooked mode, which is
 *  precisely the reader a ConPTY keystroke cannot reach. */
function stubbornSleeper(dir: string): { command: string; args: string[] } {
  if (isWin) {
    return {
      command: "powershell.exe",
      args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 120"],
    };
  }
  const script = writeScript(dir, "stubborn.sh", "trap '' TERM\nprintf '%s' \"$$\" > \"$1\"\nwhile true; do sleep 1; done\n");
  return { command: "/bin/sh", args: [script, join(dir, "leader.pid")] };
}

describe("gracefulBudget", () => {
  function session(type: "agent" | "service" | undefined, graceMs?: number): TerminalSession {
    return new TerminalSession({
      terminalId: "t",
      type,
      onMessage: () => {},
      ...(graceMs !== undefined ? { gracefulAsk: { graceMs } } : {}),
    });
  }

  test("asks only agent terminals", () => {
    expect(gracefulBudget(session("agent"), 2500)).toBe(2500);
    expect(gracefulBudget(session("service"), 2500)).toBe(0);
    expect(gracefulBudget(session(undefined), 2500)).toBe(0);
  });

  test("a declared grace can shorten the caller's budget but never lengthen it", () => {
    expect(gracefulBudget(session("agent", 1000), 2500)).toBe(1000);
    expect(gracefulBudget(session("agent", 9000), 2500)).toBe(2500);
  });

  test("no budget means no ask, whatever the terminal is", () => {
    expect(gracefulBudget(session("agent"), 0)).toBe(0);
    expect(gracefulBudget(session("agent"), 0, true)).toBe(0);
  });

  // Shutdown is the one caller that asks a service too — and only where it
  // already did. Withdrawing the POSIX SIGTERM would be the regression; Windows
  // returned before the graceful phase entirely and has nothing to preserve.
  test("shutdown keeps the platform's existing answer for a service", () => {
    const budget = gracefulBudget(session("service"), 4000, true);
    expect(budget).toBe(isWin ? 0 : 4000);
  });
});

describe("TerminalSession.close source invariants", () => {
  const source = readFileSync(join(import.meta.dir, "../src/terminal-session.ts"), "utf8");
  const body = source.slice(
    source.indexOf("  close(graceMs: number): Promise<void> {"),
    source.indexOf("  kill(): void {"),
  );

  test("close is not async", () => {
    // `SessionManager.stopAndAwait` reads `treeKilled` right after asking for
    // the stop, before any await of its own. An assignment that landed after a
    // suspension would hand that read the resolved placeholder, the tree wait
    // would be vacuous, and `git worktree remove` would sweep a live checkout.
    expect(body.length).toBeGreaterThan(0);
    expect(source).toContain("\n  close(graceMs: number): Promise<void> {");
    expect(source).not.toContain("async close(");
  });

  test("assigns treeKilledPromise with nothing awaited before it", () => {
    const assigned = body.indexOf("this.treeKilledPromise = exited.then(");
    expect(assigned).toBeGreaterThan(-1);
    // `await`, so `awaitExitWithin` — which suspends nothing — does not read
    // as a suspension.
    expect(body.slice(0, assigned).replace(/\/\/.*$/gm, "")).not.toMatch(/await/);
  });

  test("nothing can return between the grace and the sweep", () => {
    // The escalation is what makes a wrong guess about an agent cost latency
    // rather than a stranded process tree, so no branch may skip it.
    const asked = body.indexOf("exited.then((onOwn)");
    const swept = body.indexOf("return this.gracefulSweep(");
    expect(asked).toBeGreaterThan(-1);
    expect(swept).toBeGreaterThan(asked);
    expect(body.slice(asked, swept)).not.toContain("return ");
  });

  test("the grace is gated on the sweep being job-backed", () => {
    // Without the job, a departing leader's orphans are unreachable and asking
    // first COSTS the sweep — the one case where the old reasoning still holds.
    expect(body).toContain('process.platform === "win32" && !this.hadJob');
  });
});

describe("the graceful phase", () => {
  // The first coverage this phase has ever had: the only killAllGracefully test
  // in the tree is Windows-gated, and the Windows arm used to return BEFORE the
  // SIGTERM loop — so the POSIX ladder could have been deleted without failing
  // anything.
  posixOnly("lets an agent run its own exit path", async () => {
    const dir = tempDir("posix-ask");
    const marker = join(dir, "bye");
    const script = writeScript(dir, "agent.sh", "trap 'printf bye > \"$1\"; exit 0' TERM\nsleep 120\n");
    const messages: AbMessage[] = [];
    const manager = new TerminalManager((m) => messages.push(m), undefined, createConnState());
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command: "/bin/sh", args: [script, marker] });
      await new Promise((r) => setTimeout(r, 300));

      const started = Date.now();
      const tree = manager.killAndAwaitTree("t1", 3000);

      expect(await waitFor(() => readWhenWritten(marker), 3000)).toBe("bye");
      await tree;
      // Well inside the budget: a SIGKILL would have run no trap at all, and an
      // ask that only escalated on timeout would have taken the full 3s.
      expect(Date.now() - started).toBeLessThan(2500);
      expect(messages.some((m) => m.type === "terminal:exited" && m.terminalId === "t1")).toBe(true);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  // The behaviour change this suite exists to pin: the ask names the process
  // GROUP, not the bare leader. A bare-pid SIGTERM reaches the wrapper alone,
  // and the agent underneath it — the `sh -c` wrap `spawn()` puts around every
  // free-form command — never learns the session is ending.
  posixOnly("reaches a child the PTY leader never signals", async () => {
    const dir = tempDir("posix-group");
    const marker = join(dir, "child");
    const child = writeScript(dir, "child.sh", "trap 'printf child > \"$1\"; exit 0' TERM\nsleep 120\n");
    // The wrapper CATCHES TERM rather than ignoring it, and the two are not
    // interchangeable here: SIG_IGN is inherited across fork AND exec, and a
    // non-interactive shell may not trap a signal that was already ignored when
    // it started — so `trap '' TERM` would silently disarm the child's own trap
    // and the test could never pass, whichever pid the ask names. A handler is
    // reset to default in the child, which is what leaves the child free to
    // answer. The `kill -0` loop keeps the leader alive past its own trap, so
    // the child's exit is what ends the PTY.
    const parent = writeScript(
      dir,
      "parent.sh",
      "trap 'true' TERM\n/bin/sh \"$1\" \"$2\" &\nc=$!\nwhile kill -0 \"$c\" 2>/dev/null; do wait \"$c\" 2>/dev/null; done\n",
    );
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command: "/bin/sh", args: [parent, child, marker] });
      await new Promise((r) => setTimeout(r, 400));

      manager.kill("t1", 3000);

      expect(await waitFor(() => readWhenWritten(marker), 3000)).toBe("child");
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  // What NOTHING did before: an agent that finishes on its own leaves helpers
  // behind, and on POSIX no path swept them. The sweep is unconditional now, so
  // it runs after a natural exit as well as after an ignored ask.
  posixOnly("sweeps what an agent leaves behind when it exits on request", async () => {
    const dir = tempDir("posix-sweep");
    const pidFile = join(dir, "helper.pid");
    const script = writeScript(
      dir,
      "agent.sh",
      "/bin/sh -c 'trap \"\" TERM; while true; do sleep 1; done' &\nprintf '%s' \"$!\" > \"$1\"\ntrap 'exit 0' TERM\nwait\n",
    );
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    let helper: number | undefined;
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command: "/bin/sh", args: [script, pidFile] });
      const raw = await waitFor(() => readWhenWritten(pidFile), 15_000);
      expect(raw).toBeDefined();
      helper = Number(raw);
      expect(alive(helper)).toBe(true);

      await manager.killAndAwaitTree("t1", 3000);

      // Bounded rather than immediate: SIGKILL returns before its targets are
      // reaped. What is ruled out is a helper that outlives the session.
      expect(await waitFor(() => (alive(helper!) ? undefined : true), 5000)).toBe(true);
    } finally {
      manager.killAll();
      if (helper !== undefined && alive(helper)) { try { process.kill(helper, "SIGKILL"); } catch { /* gone */ } }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 40_000);

  posixOnly("escalates on an agent that ignores the ask, and still takes its tree", async () => {
    const dir = tempDir("posix-escalate");
    const { command, args } = stubbornSleeper(dir);
    const messages: AbMessage[] = [];
    const manager = new TerminalManager((m) => messages.push(m), undefined, createConnState());
    let leader: number | undefined;
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      const raw = await waitFor(() => readWhenWritten(join(dir, "leader.pid")), 15_000);
      expect(raw).toBeDefined();
      leader = Number(raw);

      const started = Date.now();
      await manager.killAndAwaitTree("t1", 1200);
      const elapsed = Date.now() - started;

      // The grace was genuinely waited out, and the sweep did not wait a second
      // budget on top of it.
      expect(elapsed).toBeGreaterThanOrEqual(1100);
      expect(elapsed).toBeLessThan(6000);
      expect(await waitFor(() => (alive(leader!) ? undefined : true), 5000)).toBe(true);
      expect(await waitFor(
        () => (messages.some((m) => m.type === "terminal:exited" && m.terminalId === "t1") ? true : undefined),
        5000,
      )).toBe(true);
    } finally {
      manager.killAll();
      if (leader !== undefined && alive(leader)) { try { process.kill(leader, "SIGKILL"); } catch { /* gone */ } }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 40_000);

  // The sharpest failure mode this change can have, and it would ship green:
  // `SessionManager.stopAndAwait` reads `treeKilled` the instant it asks for the
  // stop, and a promise that was already resolved by then makes the tree wait
  // vacuous — `git worktree remove` would run against a live checkout.
  test("treeKilled does not resolve while the ask is still in flight", async () => {
    const dir = tempDir("vacuous");
    const { command, args } = stubbornSleeper(dir);
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      await new Promise((r) => setTimeout(r, 500));

      manager.kill("t1", 2000);
      const tree = manager.treeKilled("t1");

      expect(await Promise.race([
        tree.then(() => "resolved"),
        new Promise((r) => setTimeout(() => r("pending"), 600)),
      ])).toBe("pending");
      await tree;
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 40_000);

  test("a second ask neither re-asks nor restarts the clock", async () => {
    const dir = tempDir("reentrant");
    const { command, args } = stubbornSleeper(dir);
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      await new Promise((r) => setTimeout(r, 500));

      const started = Date.now();
      const first = manager.killAndAwaitTree("t1", 1200);
      await new Promise((r) => setTimeout(r, 300));
      const second = manager.killAndAwaitTree("t1", 1200);
      expect(second).toBe(first);
      await second;

      // One budget, not two: a stop racing a delete is ordinary, and each
      // re-ask pushing the teardown out is what would blow the delete's own
      // 15s ceiling.
      expect(Date.now() - started).toBeLessThan(4500);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 40_000);
});

describe("TerminalManager.killAllGracefully", () => {
  // The window the graceful phase opens: nothing has closed the inbound door by
  // then, so a `session:start` or a `servicesModified` respawn can land a new
  // PTY mid-shutdown. Clearing the maps from the entry snapshot would forget it
  // without killing it — an orphan on POSIX, and a leaked job handle on Windows.
  test("kills a terminal that spawns during the grace", async () => {
    const dir = tempDir("late");
    const { command, args } = stubbornSleeper(dir);
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    const sessions: TerminalSession[] = [];
    manager.onSessionCreated((s) => sessions.push(s));
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      await new Promise((r) => setTimeout(r, 400));

      const closing = manager.killAllGracefully(1200);
      await new Promise((r) => setTimeout(r, 250));
      manager.spawn({ terminalId: "t2", command, args });

      expect(await closing).toBe(1);
      const late = sessions.find((s) => s.terminalId === "t2");
      expect(late).toBeDefined();
      expect(late!.isRunning).toBe(false);
      expect(manager.size).toBe(0);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 40_000);

  // Windows is clamped because the app force-kills the whole tree ~3s after
  // asking; POSIX polled the caller's full budget before this change and taking
  // that away would be the regression.
  posixOnly("spends the caller's whole budget on POSIX", async () => {
    const dir = tempDir("budget");
    const { command, args } = stubbornSleeper(dir);
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      await new Promise((r) => setTimeout(r, 400));

      const started = Date.now();
      expect(await manager.killAllGracefully(2600)).toBe(1);

      expect(Date.now() - started).toBeGreaterThanOrEqual(2500);
      expect(WINDOWS_SHUTDOWN_GRACE_MS).toBeLessThan(2600);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 40_000);
});

// `killAndAwaitTree` used to resolve strictly BEFORE the PTY's exit was
// dispatched — `killProcessTree` returning is not the exit — and a teardown
// that calls `forget` next therefore always took `forgotten`'s live branch. A
// graceful close inverts that: the exit is what ENDS the wait. So the branch
// `forget` takes here is the other one, and the checkout teardown that calls it
// has to survive both.
describe("forget after a graceful exit", () => {
  posixOnly("dispatches the exit before the tree wait resolves", async () => {
    const dir = tempDir("forget");
    const script = writeScript(dir, "agent.sh", "trap 'exit 0' TERM\nsleep 120\n");
    const messages: AbMessage[] = [];
    let forgotten = 0;
    const manager = new TerminalManager(
      (m) => messages.push(m),
      { onTerminalForgotten: () => { forgotten++; } },
      createConnState(),
    );
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command: "/bin/sh", args: [script] });
      await new Promise((r) => setTimeout(r, 300));

      await manager.killAndAwaitTree("t1", 3000);

      // No poll: an agent that left on request has already been dispatched by
      // the time its own exit is what resolved the wait.
      expect(messages.some((m) => m.type === "terminal:exited" && m.terminalId === "t1")).toBe(true);

      manager.forget("t1");
      expect(forgotten).toBe(1);
      // The stopped row the exit left behind is gone with it — `forget` on an
      // already-exited terminal has to clear that half too, not just tombstone
      // an exit still owed.
      expect(manager.getStatus().some((t) => t.terminalId === "t1")).toBe(false);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});

// The grace made this reachable rather than theoretical. The window between the
// ask and the exit used to be a couple of hundred milliseconds; it is seconds
// now, which is comfortably long enough for a user to press Stop and then Start
// (`SessionManager.stopTerminal` -> `startNow`, which clears `stopping` and
// spawns on the same terminal id). The replaced run's exit then lands on a slot
// the replacement owns, where the same-id gate drops it — so whatever the exit
// owed has to have been paid at the replacement instead.
describe("a restart inside the grace", () => {
  test("pays the replaced run's exit bookkeeping without telling the app it died", async () => {
    const dir = tempDir("restart");
    const { command, args } = stubbornSleeper(dir);
    const exited: string[] = [];
    const messages: AbMessage[] = [];
    const manager = new TerminalManager(
      (m) => messages.push(m),
      { onTerminalExited: (id) => exited.push(id) },
      createConnState(),
    );
    const exitFrames = (): AbMessage[] =>
      messages.filter((m) => m.type === "terminal:exited" && m.terminalId === "t1");
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      await new Promise((r) => setTimeout(r, 400));

      manager.kill("t1", 3000);
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      // Asserted with nothing awaited in between, because "eventually" is the
      // bug: a dispatch that waits for the real exit arrives after the
      // replacement has registered, and `namer.forget` /
      // `handlerEngine.onTerminalExit` are keyed by terminal id — they would
      // reclaim the live run's title state and arming instead of the dead
      // run's.
      expect(exited).toEqual(["t1"]);

      // Long enough for the replaced PTY's own exit to land on the new session.
      await new Promise((r) => setTimeout(r, 1500));
      expect(exited).toEqual(["t1"]);
      expect(manager.has("t1")).toBe(true);
      // The half the same-id gate exists to protect: an exit frame for a slot a
      // live session holds tells the app a running terminal is dead, and
      // nothing later corrects it.
      expect(exitFrames()).toEqual([]);

      // The replacement is owed its own exit — the split must not have spent it
      // on the run before.
      manager.killAll();
      await waitFor(() => (exitFrames().length > 0 ? true : undefined), 5000);
      expect(exited).toEqual(["t1", "t1"]);
      expect(exitFrames()).toHaveLength(1);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});

describe("the Windows ask", () => {
  /** A raw-mode reader — what every TUI agent is, and the only reader a ConPTY
   *  keystroke reaches. Optionally starts a grandchild through `Start-Process`
   *  first: a ShellExecute launch joins its creator's job, not the PTY's, so it
   *  is reachable ONLY through the pre-ask descendant snapshot once the leader
   *  has left. */
  function agentScript(marker: string, ready: string, grandchildPidFile?: string): string {
    const start = grandchildPidFile
      ? `
import { spawnSync } from "node:child_process";
spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", [
  "$c = Start-Process -PassThru -FilePath powershell",
  "-ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120';",
  ${JSON.stringify(`Set-Content -Encoding ascii -Path '${grandchildPidFile}' -Value $c.Id`)},
].join(" ")], { windowsHide: true });
`
      : "";
    return `
import { writeFileSync } from "node:fs";
${start}
process.stdin.setRawMode?.(true);
process.stdin.on("data", (chunk) => {
  if (chunk.includes(3)) {
    writeFileSync(${JSON.stringify(marker)}, "etx");
    process.exit(0);
  }
});
process.stdin.resume();
// Written LAST, and every caller waits on it: a keystroke sent before the
// reader is attached is simply gone — the ask is one press, not a retry loop —
// and a test that raced it would read as an agent ignoring Ctrl-C.
writeFileSync(${JSON.stringify(ready)}, "ready");
setInterval(() => {}, 1e6);
`;
  }

  /** Spawns the agent and waits for its reader, never for a fixed delay. */
  async function spawnReadyAgent(
    manager: TerminalManager,
    script: string,
    readyFile: string,
  ): Promise<void> {
    manager.spawn({ terminalId: "t1", type: "agent", command: process.execPath, args: [script] });
    expect(await waitFor(() => readWhenWritten(readyFile), 30_000)).toBe("ready");
  }

  windowsOnly("delivers a Ctrl-C the agent's own exit path can see", async () => {
    const dir = tempDir("win-etx");
    const marker = join(dir, "etx");
    const ready = join(dir, "ready");
    const script = writeScript(dir, "agent.ts", agentScript(marker, ready));
    const messages: AbMessage[] = [];
    const manager = new TerminalManager((m) => messages.push(m), undefined, createConnState());
    try {
      await spawnReadyAgent(manager, script, ready);

      const started = Date.now();
      await manager.killAndAwaitTree("t1", 4000);

      expect(existsSync(marker)).toBe(true);
      // The agent left on request rather than being TerminateProcess'd at the
      // end of the budget — which is the whole point: a process terminated that
      // way runs no `process.on("exit")` hook, and Claude Code's fullscreen boot
      // canary is withdrawn in exactly one.
      expect(Date.now() - started).toBeLessThan(3500);
      expect(messages.some((m) => m.type === "terminal:exited" && m.terminalId === "t1")).toBe(true);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  // The falsifier for "reason (2) is stale". A ShellExecute grandchild is NOT a
  // job member, and a leader that exits on request takes the parent links
  // `taskkill /T` walks with it — so nothing but the pre-ask snapshot reaches
  // it, and one survivor holding a checkout is a permanently undeletable
  // isolated session.
  windowsOnly("still takes a grandchild the leader's exit put out of reach", async () => {
    const dir = tempDir("win-orphan");
    const marker = join(dir, "etx");
    const pidFile = join(dir, "grandchild.pid");
    const ready = join(dir, "ready");
    const script = writeScript(dir, "agent.ts", agentScript(marker, ready, pidFile.replace(/\\/g, "\\\\")));
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    let grandchild: number | undefined;
    try {
      await spawnReadyAgent(manager, script, ready);
      const raw = await waitFor(() => readWhenWritten(pidFile), 30_000);
      expect(raw).toBeDefined();
      grandchild = Number(raw);
      expect(alive(grandchild)).toBe(true);

      await manager.killAndAwaitTree("t1", 4000);

      // The agent really did leave on its own, so this is the reach the ask
      // costs and not the one taskkill still had.
      expect(existsSync(marker)).toBe(true);
      // Asserted with no polling: `git worktree remove` runs the instant this
      // resolves, so the tree has to be gone by then.
      expect(alive(grandchild)).toBe(false);
    } finally {
      manager.killAll();
      if (grandchild !== undefined && alive(grandchild)) {
        spawnSync("taskkill", ["/F", "/T", "/PID", String(grandchild)], { windowsHide: true });
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 90_000);

  windowsOnly("escalates on an agent that ignores the keystroke", async () => {
    const dir = tempDir("win-ignore");
    const script = writeScript(dir, "agent.ts", "\nprocess.stdin.resume();\nsetInterval(() => {}, 1e6);\n");
    const messages: AbMessage[] = [];
    const manager = new TerminalManager((m) => messages.push(m), undefined, createConnState());
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command: process.execPath, args: [script] });
      await new Promise((r) => setTimeout(r, 1500));

      const started = Date.now();
      await manager.killAndAwaitTree("t1", 1200);

      expect(Date.now() - started).toBeGreaterThanOrEqual(1100);
      expect(await waitFor(
        () => (messages.some((m) => m.type === "terminal:exited" && m.terminalId === "t1") ? true : undefined),
        10_000,
      )).toBe(true);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  windowsOnly("every PTY is job-backed, which is what the grace is gated on", async () => {
    const dir = tempDir("win-job");
    const { command, args } = stubbornSleeper(dir);
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    const sessions: TerminalSession[] = [];
    manager.onSessionCreated((s) => sessions.push(s));
    try {
      manager.spawn({ terminalId: "t1", type: "agent", command, args });
      await new Promise((r) => setTimeout(r, 400));
      expect(sessions[0]!.jobBacked).toBe(true);
    } finally {
      manager.killAll();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});

describe("AgentSpec.gracefulExit", () => {
  test("claude-code asks with more than one Ctrl-C", () => {
    // Measured against the installed CLI: the first press only arms the quit
    // ("Press Ctrl-C again to exit"), so a single-press ask spends the entire
    // budget and force-kills anyway — which is the bug, not a fix for it.
    const keys = AGENTS["claude-code"].gracefulExit?.keystrokes;
    expect(keys).toBeDefined();
    expect(keys!.length).toBeGreaterThan(1);
    expect(keys!.every((k) => k === ETX)).toBe(true);
  });

  test("no agent declares a grace longer than the caller's", () => {
    // `graceMs` may only shorten. A longer measured need is a reason to move
    // AGENT_GRACE_MS and re-check the delete arithmetic, never to let one agent
    // overrun a budget the delete path already promised away.
    for (const [key, spec] of Object.entries(AGENTS)) {
      const declared = spec.gracefulExit?.graceMs;
      if (declared !== undefined) expect(declared).toBeLessThanOrEqual(AGENT_GRACE_MS);
      expect(key).toBeTruthy();
    }
  });

  test("the agents layer stays free of runtime imports", () => {
    // `terminal-session.ts` reads ETX from `agents/types.ts`, and the reverse
    // import cycles through `tool-detector` back into the registry — which
    // evaluates the spec table while ETX is still in its temporal dead zone.
    // The failure is a ReferenceError at import time across most of the suite,
    // with nothing pointing at the import that caused it.
    const source = readFileSync(join(import.meta.dir, "../src/agents/types.ts"), "utf8");
    // Every form that pulls a module in at RUNTIME, not just `import x from`: a
    // bare `import "./m"` and a value `export { X } from "./m"` both do, and a
    // guard that only inspected `^import .*$` passed them straight through.
    const runtime = source
      .match(/^(?:import|export).*$/gm)
      ?.filter((line) => /from\s*["']|^import\s*["']/.test(line))
      .filter((line) => !/^(?:import|export)\s+type/.test(line)) ?? [];
    expect(source).toContain("import type ");
    expect(runtime).toEqual([]);
  });
});

describe("the per-session budget", () => {
  test("a stop's grace plus taskkill's own ceiling stays inside the delete's", () => {
    // `SessionManager.stopAndAwait` spends ONE TEARDOWN_TIMEOUT_MS (15s) on the
    // exit and the tree together, and a false answer there is converted into a
    // user-visible WORKTREE_DELETE_FAILED. The app's mode-flip reply timeout
    // (25s) has to stay above the whole of it.
    expect(AGENT_GRACE_MS + 5_000).toBeLessThan(15_000);
    // And above what an agent actually needs: claude-code measured 1.4-3.0s
    // ask→exit on Windows, so a budget under that is spent for nothing.
    expect(AGENT_GRACE_MS).toBeGreaterThan(3_000);
    // Shutdown is the tighter caller, not the looser one.
    expect(WINDOWS_SHUTDOWN_GRACE_MS).toBeLessThan(AGENT_GRACE_MS);
  });
});
