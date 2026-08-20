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
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { TerminalManager } from "../src/terminal-manager";
import { killProcessTree, processGroupSpawn } from "../src/terminal-session";
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

      const raw = await waitFor(() => (existsSync(pidFile) ? readFileSync(pidFile, "utf8").trim() : undefined), 30_000);
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
      const raw = await waitFor(() => {
        if (!existsSync(pidFile)) return undefined;
        const text = readFileSync(pidFile, "utf8").trim();
        return text.length > 0 ? text : undefined;
      }, 30_000);
      expect(raw).toBeDefined();
      childPid = Number(raw);
      expect(Number.isInteger(childPid)).toBe(true);
      expect(alive(childPid)).toBe(true);
      // The shell must still be up, or a dead group would prove nothing.
      expect(proc.exitCode).toBeNull();

      killProcessTree(proc.pid!);

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
