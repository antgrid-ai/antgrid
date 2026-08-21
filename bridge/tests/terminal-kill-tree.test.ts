// Killing a terminal must take everything it started with it. A survivor holds
// its working directory open, and on Windows one such orphan is enough to make
// `git worktree remove` abort partway — which is how an isolated session became
// permanently undeletable. `IPty.kill()` signals the PTY leader alone, so the
// PTY case is asserted end to end against a real PTY rather than against the
// helper: the helper is trivial and the ordering around it is not.
//
// The two platforms reach the tree by different means — parent links on
// Windows, the process group on POSIX — and a POSIX group exists only if the
// child was spawned to lead one, so each has its own case here and neither can
// stand in for the other.
import { describe, test, expect } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { TerminalManager } from "../src/terminal-manager";
import { killChildTree, killProcessTree, processGroupSpawn } from "../src/terminal-session";
import { createConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

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
  if (process.platform === "win32") return true;
  return processState(pid) !== "Z";
}

async function waitFor<T>(probe: () => T | undefined, timeoutMs: number): Promise<T | undefined> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = probe();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return undefined;
}

/* The pid file becomes visible before it is readable: on Windows Set-Content
 * still holds it exclusively, so an eager read throws EBUSY, and on either
 * platform the create can be seen before the content lands. Both mean the
 * writer has not finished, which is the poll loop's "not yet". */
function readPidFile(pidFile: string): string | undefined {
  let text: string;
  try {
    text = readFileSync(pidFile, "utf8").trim();
  } catch {
    return undefined;
  }
  return text.length > 0 ? text : undefined;
}

describe("TerminalManager.kill", () => {
  // Windows-only because the gap is Windows-only: there is no process group to
  // signal in the leader's place, so the tree has to be walked explicitly.
  test.skipIf(process.platform !== "win32")("kills a grandchild the terminal's shell started", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-kill-tree-"));
    const pidFile = join(dir, "child.pid");
    const messages: AbMessage[] = [];
    const manager = new TerminalManager((message) => messages.push(message), undefined, createConnState());
    const exited = (): boolean => messages.some((m) => m.type === "terminal:exited" && m.terminalId === "t1");
    let childPid: number | undefined;
    try {
      // The shell is named rather than inherited: SHELL is set to bash in some
      // developer environments, and this case is about Windows process trees.
      // A separate process, not a background job — that is what used to survive.
      manager.spawn({
        terminalId: "t1",
        command: "powershell.exe",
        args: ["-NoProfile", "-NonInteractive", "-Command", [
          "$c = Start-Process -PassThru -FilePath powershell",
          "-ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120';",
          `Set-Content -Encoding ascii -Path '${pidFile}' -Value $c.Id;`,
          "Start-Sleep -Seconds 120",
        ].join(" ")],
      });

      const raw = await waitFor(() => readPidFile(pidFile), 30_000);
      expect(raw).toBeDefined();
      childPid = Number(raw);
      expect(Number.isInteger(childPid)).toBe(true);
      expect(alive(childPid)).toBe(true);
      // Without this the test could pass on a leader that had already died and a
      // child that happened to follow it — proving nothing about the kill.
      expect(exited()).toBe(false);

      manager.kill("t1");

      expect(await waitFor(() => (alive(childPid!) ? undefined : true), 15_000)).toBe(true);
    } finally {
      manager.killAll();
      if (childPid !== undefined && alive(childPid)) {
        try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  // The property `git worktree remove` leans on, and the only direct test of
  // what teardown's await buys: no polling, the grandchild is already gone.
  test.skipIf(process.platform !== "win32")("killAndAwaitTree resolves only once the grandchild is gone", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-kill-await-"));
    const pidFile = join(dir, "child.pid");
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    let childPid: number | undefined;
    try {
      manager.spawn({
        terminalId: "t1",
        command: "powershell.exe",
        args: ["-NoProfile", "-NonInteractive", "-Command", [
          "$c = Start-Process -PassThru -FilePath powershell",
          "-ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120';",
          `Set-Content -Encoding ascii -Path '${pidFile}' -Value $c.Id;`,
          "Start-Sleep -Seconds 120",
        ].join(" ")],
      });

      const raw = await waitFor(() => readPidFile(pidFile), 30_000);
      expect(raw).toBeDefined();
      childPid = Number(raw);
      expect(alive(childPid)).toBe(true);

      await manager.killAndAwaitTree("t1");

      expect(alive(childPid)).toBe(false);
    } finally {
      manager.killAll();
      if (childPid !== undefined && alive(childPid)) {
        try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  // The POSIX half of the same guarantee, so CI — ubuntu-only — actually gates
  // it. The bound is tight rather than zero because SIGKILL returns before the
  // target has finished exiting; what is being ruled out is a promise that
  // resolved while the tree still had 120 seconds to live.
  test.skipIf(process.platform === "win32")("killAndAwaitTree resolves only once the terminal's group is gone", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-kill-await-posix-"));
    const pidFile = join(dir, "child.pid");
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    let childPid: number | undefined;
    try {
      manager.spawn({ terminalId: "t1", command: `sleep 120 & echo $! > ${pidFile}; wait` });

      const raw = await waitFor(() => readPidFile(pidFile), 30_000);
      expect(raw).toBeDefined();
      childPid = Number(raw);
      expect(alive(childPid)).toBe(true);

      await manager.killAndAwaitTree("t1");

      expect(await waitFor(() => (alive(childPid!) ? undefined : true), 2_000)).toBe(true);
    } finally {
      manager.killAll();
      if (childPid !== undefined && alive(childPid)) {
        try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});

describe("processGroupSpawn", () => {
  test("asks for a process group exactly where killProcessTree needs one", () => {
    // Not cosmetic: POSIX has nothing to signal without it, and Windows would
    // pay for it with a console window while reaching the tree another way.
    expect(processGroupSpawn("linux").detached).toBe(true);
    expect(processGroupSpawn("darwin").detached).toBe(true);
    expect(processGroupSpawn("win32").detached).toBe(false);
  });
});

describe("killProcessTree on POSIX", () => {
  // The `command:run` shape rather than the PTY one: a shell holding a
  // background child, which is what survives a kill aimed at the handle alone.
  test.skipIf(process.platform === "win32")("kills a grandchild through the process group", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-kill-group-"));
    const pidFile = join(dir, "child.pid");
    let childPid: number | undefined;
    const proc = spawn("sh", ["-c", `sleep 120 & echo $! > ${pidFile}; wait`], {
      stdio: ["ignore", "pipe", "pipe"],
      ...processGroupSpawn(),
    });
    try {
      const raw = await waitFor(() => readPidFile(pidFile), 30_000);
      expect(raw).toBeDefined();
      childPid = Number(raw);
      expect(Number.isInteger(childPid)).toBe(true);
      expect(alive(childPid)).toBe(true);
      // The shell must still be up, or a dead group would prove nothing.
      expect(proc.exitCode).toBeNull();

      await killProcessTree(proc.pid!);

      expect(await waitFor(() => (alive(childPid!) ? undefined : true), 15_000)).toBe(true);
    } finally {
      if (childPid !== undefined && alive(childPid)) {
        try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
      }
      try { proc.kill("SIGKILL"); } catch { /* already gone */ }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});

describe("killProcessTree contract", () => {
  // Nearly every caller fires this from a message handler and discards the
  // result, so a rejection would surface as an unhandled rejection on an
  // ordinary terminal close rather than at the site that caused it.
  const NO_SUCH_PID = 2_147_483_646;

  test("never rejects, whatever it is handed", async () => {
    await expect(killProcessTree(NO_SUCH_PID)).resolves.toBeUndefined();
    await expect(killProcessTree(0)).resolves.toBeUndefined();
    await expect(killProcessTree(-1)).resolves.toBeUndefined();
    await expect(killProcessTree(1.5)).resolves.toBeUndefined();
    await expect(killProcessTree(Number.NaN)).resolves.toBeUndefined();
  });

  test("hands back something awaitable on every platform", () => {
    const result = killProcessTree(0);
    expect(typeof result.then).toBe("function");
  });

  // CI runs the bridge suite on ubuntu only, so the Windows branch — the whole
  // reason this function is async — never executes there. This reads the source
  // instead: without it, a revert to a blocking exec ships green.
  test("issues the Windows kill without blocking the event loop", () => {
    const source = readFileSync(join(import.meta.dir, "../src/terminal-session.ts"), "utf8");
    const marker = "export function killProcessTree(";
    const start = source.indexOf(marker);
    expect(start).toBeGreaterThan(-1);
    let depth = 0;
    let end = -1;
    for (let i = source.indexOf("{", start); i < source.length; i++) {
      if (source[i] === "{") depth++;
      else if (source[i] === "}" && --depth === 0) {
        end = i;
        break;
      }
    }
    expect(end).toBeGreaterThan(start);
    const body = source.slice(start, end);
    expect(body).not.toContain("execFileSync");
    expect(body).not.toContain("spawnSync");
  });

  // Windows-only by construction: POSIX never blocked here, so only a developer
  // machine can prove the taskkill wait yields.
  test.skipIf(process.platform !== "win32")("does not block the event loop while the tree dies", async () => {
    const proc = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"], {
      stdio: "ignore",
      windowsHide: true,
      ...processGroupSpawn(),
    });
    let ticks = 0;
    const timer = setInterval(() => { ticks++; }, 10);
    try {
      await killProcessTree(proc.pid!);
    } finally {
      clearInterval(timer);
      try { proc.kill(); } catch { /* already gone */ }
    }
    expect(ticks).toBeGreaterThan(0);
  }, 30_000);
});

describe("killChildTree", () => {
  // The shape `teardownCheckoutRuntime` uses: `command:run` children spawned
  // through a shell, killed as a batch, with the checkout directory freed by
  // the time the composite promise resolves.
  test.skipIf(process.platform === "win32")("kills every child's tree before it resolves", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-kill-children-"));
    const procs = [0, 1].map((n) =>
      spawn("sh", ["-c", `sleep 120 & echo $! > ${join(dir, `child${n}.pid`)}; wait`], {
        stdio: ["ignore", "pipe", "pipe"],
        ...processGroupSpawn(),
      }),
    );
    const pids: number[] = [];
    // Counted through a wrapper rather than read off `ChildProcess.killed`:
    // the tree kill has usually left the handle a zombie by then, and whether
    // that second signal is accepted is a reaping race, not the contract.
    let handleKills = 0;
    try {
      for (const n of [0, 1]) {
        const file = join(dir, `child${n}.pid`);
        const raw = await waitFor(() => readPidFile(file), 30_000);
        expect(raw).toBeDefined();
        pids.push(Number(raw));
      }
      for (const pid of pids) expect(alive(pid)).toBe(true);
      for (const proc of procs) expect(proc.exitCode).toBeNull();

      await Promise.all(procs.map((proc) =>
        killChildTree({ pid: proc.pid, kill: () => { handleKills++; return proc.kill("SIGKILL"); } }),
      ));

      // Every handle kill is chained behind its own tree kill, so a composite
      // that resolved early would show up here as a missing one.
      expect(handleKills).toBe(procs.length);
      // Tight rather than zero: SIGKILL returns before the target has finished
      // exiting. What it rules out is a resolve while the trees still had 120
      // seconds to live — the delete this shape serves runs `git worktree
      // remove` the instant the await returns.
      for (const pid of pids) {
        expect(await waitFor(() => (alive(pid) ? undefined : true), 2_000)).toBe(true);
      }
    } finally {
      for (const pid of pids) {
        if (alive(pid)) { try { process.kill(pid, "SIGKILL"); } catch { /* already gone */ } }
      }
      for (const proc of procs) { try { proc.kill("SIGKILL"); } catch { /* already gone */ } }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test("still kills the handle when the child never got a pid", async () => {
    let killed = 0;
    await killChildTree({ pid: undefined, kill: () => { killed++; return true; } });
    expect(killed).toBe(1);
  });
});

// Shutdown's graceful phase is where the sweep is easiest to lose without
// noticing: every session exits, the map empties, and the force-kill branch
// that does the sweeping is skipped as unnecessary. On Windows that is the
// broken case, not the happy one — the leader dying is precisely what puts its
// children beyond reach. Asserted with no polling: the tree is a precondition
// of `git worktree remove`, so it has to be gone when this resolves.
describe("TerminalManager.killAllGracefully", () => {
  test.skipIf(process.platform !== "win32")("takes the grandchild with it", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-kill-graceful-"));
    const pidFile = join(dir, "child.pid");
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    let childPid: number | undefined;
    try {
      manager.spawn({
        terminalId: "t1",
        command: "powershell.exe",
        args: ["-NoProfile", "-NonInteractive", "-Command", [
          "$c = Start-Process -PassThru -FilePath powershell",
          "-ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120';",
          `Set-Content -Encoding ascii -Path '${pidFile}' -Value $c.Id;`,
          "Start-Sleep -Seconds 120",
        ].join(" ")],
      });

      const raw = await waitFor(() => readPidFile(pidFile), 30_000);
      expect(raw).toBeDefined();
      childPid = Number(raw);
      expect(alive(childPid)).toBe(true);

      expect(await manager.killAllGracefully(5_000)).toBe(1);

      expect(alive(childPid)).toBe(false);
    } finally {
      manager.killAll();
      if (childPid !== undefined && alive(childPid)) {
        try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});
