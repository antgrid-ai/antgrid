// The Win32 primitives exist for one claim, so that claim is what is asserted
// end to end against real processes rather than against a mock: a process the
// coding agent started inside a managed checkout routinely OUTLIVES its parent,
// and `taskkill /T` walks live parent links, so an orphan is unreachable to it
// by construction. A kill-on-close job reaches it because membership is
// inherited at CreateProcess and survives the parent's death — that is the
// whole fix for a checkout Windows refuses to delete, and nothing short of
// spawning a real orphan tests it.
//
// Off Windows the module must be inert, which is its own case here: the
// teardown path calls into it unconditionally, so an exception on Linux or
// macOS would break a delete that has no such problem to begin with.
import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createKillOnCloseJob,
  listProcessesWithCwdUnder,
  win32ProcessApiAvailable,
  type Win32Job,
} from "../src/win32-process";

const onWindows = process.platform === "win32";

/** Runs forever until something kills it; the point is to still be there. */
const SLEEPER = "setInterval(() => {}, 1e6)";

/**
 * Spawns the sleeper and exits, so the sleeper is left with a dead parent.
 * `child_process.spawn` goes through libuv's `uv_spawn`, i.e. a direct
 * `CreateProcess` — the only shape that inherits the job (a `ShellExecute`
 * launch is created by another process entirely and joins that one's job
 * instead). `detached` is what makes the sleeper outlive the exit: Bun reaps
 * its own attached children on the way out, which the survivors in the field
 * never were.
 *
 * The `go` file is what closes the race: the parent must not spawn until the
 * test has put it in the job, or the child would never have been a member and
 * the test would pass for the wrong reason.
 */
const ORPHAN_PARENT = `
import { existsSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
const [go, cwd, pidFile] = process.argv.slice(2);
while (!existsSync(go)) Bun.sleepSync(10);
const child = spawn(process.execPath, ["-e", ${JSON.stringify(SLEEPER)}], {
  cwd,
  stdio: "ignore",
  detached: true,
  windowsHide: true,
});
child.unref();
writeFileSync(pidFile, String(child.pid));
process.exit(0);
`;

const dirs: string[] = [];
const pids: number[] = [];
const jobs: Win32Job[] = [];

function tempDir(): string {
  // The real path, because the module folds case but not 8.3 short names.
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-win32-")));
  dirs.push(dir);
  return dir;
}

function track(pid: number | undefined): number {
  expect(pid).toBeGreaterThan(0);
  pids.push(pid as number);
  return pid as number;
}

/** Liveness via the module's own enumeration: nothing in this process holds a
 *  handle to these pids, and a Toolhelp snapshot answers for a process the test
 *  never owned — which `process.kill(pid, 0)` cannot do reliably on Windows. */
function holds(dir: string, pid: number): boolean {
  return listProcessesWithCwdUnder(dir).some((p) => p.pid === pid);
}

/** The pid once it is readable, not merely once the file exists. */
function readPid(pidFile: string): number | null {
  let text: string;
  try {
    text = readFileSync(pidFile, "utf8").trim();
  } catch {
    return null;
  }
  const pid = Number(text);
  return text.length > 0 && Number.isInteger(pid) && pid > 0 ? pid : null;
}

async function waitUntil(probe: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (probe()) return true;
    await new Promise((r) => setTimeout(r, 50));
  }
  return probe();
}

afterEach(() => {
  // Isolated per item, not merely ordered: the pids here are DETACHED sleepers
  // with no parent, so a throw anywhere in this hook — a job that never loaded,
  // an EBUSY out of `removeEventually` — would abandon every drain after it and
  // leave them running until the machine reboots, each holding a temp directory
  // nothing else on the machine would ever remove.
  let failure: { err: unknown } | undefined;
  const drain = (release: () => void): void => {
    try {
      release();
    } catch (err) {
      failure ??= { err };
    }
  };
  for (const job of jobs.splice(0)) drain(() => job.close());
  for (const pid of pids.splice(0)) drain(() => killHard(pid));
  for (const dir of dirs.splice(0)) drain(() => removeEventually(dir));
  if (failure !== undefined) throw failure.err;
});

/** SIGKILL and its Windows equivalent, taken to the whole tree: every pid these
 *  tests track is an orphan by design, so nothing else will reap it. */
function killHard(pid: number): void {
  if (onWindows) {
    spawnSync("taskkill", ["/F", "/T", "/PID", String(pid)], { windowsHide: true });
    return;
  }
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already gone, which is the outcome most of these tests assert.
  }
}

/** Retries because a just-killed holder releases the directory asynchronously —
 *  the very lag this module exists to survive. Hand-rolled because `rm`'s own
 *  `maxRetries`/`retryDelay` are accepted and honoured by NEITHER on Bun (see
 *  `removeWithRetries` in `worktrees/worktree-manager.ts`), so passing them here
 *  would leave one attempt and an EBUSY thrown out of teardown over whatever
 *  the test was actually reporting. */
function removeEventually(dir: string): void {
  for (let attempt = 0; ; attempt++) {
    try {
      rmSync(dir, { recursive: true, force: true });
      return;
    } catch (err) {
      if (attempt === 9) throw err;
      Bun.sleepSync(100);
    }
  }
}

describe.skipIf(onWindows)("off Windows", () => {
  test("reports itself unavailable and answers inertly", () => {
    expect(win32ProcessApiAvailable()).toBe(false);
    expect(createKillOnCloseJob()).toBeNull();
    expect(listProcessesWithCwdUnder(tmpdir())).toEqual([]);
  });

  test("an unavailable enumeration survives a path that does not exist", () => {
    expect(listProcessesWithCwdUnder(join(tmpdir(), "antgrid-nonexistent"))).toEqual([]);
  });
});

describe.skipIf(!onWindows)("createKillOnCloseJob", () => {
  test("configures the job, which pins the struct layout", () => {
    // SetInformationJobObject validates the length against the info class and
    // reads LimitFlags at a fixed offset, so a drifted
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION cannot produce a job at all.
    const job = createKillOnCloseJob();
    expect(job).not.toBeNull();
    jobs.push(job as Win32Job);
    expect((job as Win32Job).open).toBe(true);
  });

  test("close is idempotent and assignment after it is refused", () => {
    const job = createKillOnCloseJob() as Win32Job;
    job.close();
    job.close();
    expect(job.open).toBe(false);
    expect(job.assign(process.pid)).toBe(false);
  });

  test("assigning a pid that never existed is a false, not a throw", () => {
    const job = createKillOnCloseJob() as Win32Job;
    expect(job).not.toBeNull();
    jobs.push(job);
    expect(job.assign(0x7ffffff0)).toBe(false);
    expect(job.assign(-1)).toBe(false);
  });
});

describe.skipIf(!onWindows)("kill-on-close job", () => {
  test(
    "closing the job kills a grandchild whose parent already exited",
    async () => {
      const dir = tempDir();
      const held = join(dir, "held");
      mkdirSync(held);
      const script = join(dir, "parent.ts");
      const go = join(dir, "go");
      const pidFile = join(dir, "child.pid");
      writeFileSync(script, ORPHAN_PARENT);

      const job = createKillOnCloseJob() as Win32Job;
      expect(job).not.toBeNull();
      jobs.push(job);

      const parent = Bun.spawn([process.execPath, script, go, held, pidFile], {
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
      });
      const parentPid = track(parent.pid);
      expect(job.assign(parentPid)).toBe(true);
      writeFileSync(go, "");

      // On CONTENT, not existence: `writeFileSync` makes the file visible
      // before the pid lands in it, and `Number("")` is 0, which fails `track`
      // on the one test that proves the whole kill-on-close claim.
      expect(await waitUntil(() => readPid(pidFile) !== null, 20_000)).toBe(true);
      const childPid = track(readPid(pidFile) as number);
      await parent.exited;

      // The parent is gone and the child is not, so no parent-link walk from
      // any live pid reaches it — this is exactly the state `taskkill /T`
      // cannot answer for.
      expect(childPid).not.toBe(parentPid);
      expect(await waitUntil(() => holds(held, childPid), 20_000)).toBe(true);

      job.close();

      expect(await waitUntil(() => !holds(held, childPid), 20_000)).toBe(true);
    },
    60_000,
  );
});

describe.skipIf(!onWindows)("listProcessesWithCwdUnder", () => {
  test(
    "names a process holding a directory under the queried root",
    async () => {
      const root = tempDir();
      const cwd = join(root, "nested", "deep");
      mkdirSync(cwd, { recursive: true });
      const proc = Bun.spawn([process.execPath, "-e", SLEEPER], {
        cwd,
        stdin: "ignore",
        stdout: "ignore",
        stderr: "ignore",
      });
      const pid = track(proc.pid);

      expect(await waitUntil(() => holds(root, pid), 20_000)).toBe(true);
      const holder = listProcessesWithCwdUnder(root).find((p) => p.pid === pid);
      expect(holder?.name.toLowerCase()).toContain("bun");
      expect(holder?.cwd.toLowerCase()).toBe(cwd.toLowerCase());

      // A sibling root must not claim it: the prefix test is on path
      // components, not on characters.
      expect(holds(`${root}-other`, pid)).toBe(false);

      proc.kill();
      await proc.exited;
    },
    60_000,
  );

  test("a root nothing runs under reports no holders", () => {
    expect(listProcessesWithCwdUnder(join(tempDir(), "empty"))).toEqual([]);
  });
});
