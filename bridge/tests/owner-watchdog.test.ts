import { test, expect } from "bun:test";
import { startOwnerWatchdog, pidAlive } from "../src/owner-watchdog";

/** A scheduler seam the test drives by hand — no real timers. */
function manualScheduler() {
  let cb: (() => void) | null = null;
  let cleared = false;
  return {
    schedule: ((fn: () => void) => {
      cb = fn;
      return () => {
        cleared = true;
        cb = null;
      };
    }) as (cb: () => void, ms: number) => () => void,
    tick: () => cb?.(),
    get cleared() {
      return cleared;
    },
    get scheduled() {
      return cb !== null;
    },
  };
}

test("fires onOwnerGone once the owner pid disappears", () => {
  const sched = manualScheduler();
  let alive = true;
  const gone: string[] = [];
  startOwnerWatchdog({
    ownerPid: 4242,
    isAlive: () => alive,
    schedule: sched.schedule,
    onOwnerGone: (reason) => gone.push(reason),
  });

  sched.tick(); // owner still alive
  expect(gone).toEqual([]);

  alive = false;
  sched.tick(); // owner gone
  expect(gone.length).toBe(1);
  expect(gone[0]).toContain("4242");
});

test("does not fire while the owner stays alive", () => {
  const sched = manualScheduler();
  const gone: string[] = [];
  startOwnerWatchdog({
    ownerPid: 1,
    isAlive: () => true,
    schedule: sched.schedule,
    onOwnerGone: (r) => gone.push(r),
  });
  sched.tick();
  sched.tick();
  sched.tick();
  expect(gone).toEqual([]);
});

test("stops polling after firing (clears the interval, fires only once)", () => {
  const sched = manualScheduler();
  const gone: string[] = [];
  startOwnerWatchdog({
    ownerPid: 7,
    isAlive: () => false,
    schedule: sched.schedule,
    onOwnerGone: (r) => gone.push(r),
  });
  sched.tick();
  sched.tick(); // would re-fire if not stopped
  expect(gone.length).toBe(1);
  expect(sched.cleared).toBe(true);
});

test("pidAlive reports the current process alive and an unused pid gone", () => {
  expect(pidAlive(process.pid)).toBe(true);
  // A pid well above the usable range — ESRCH, the one code that means "gone".
  expect(pidAlive(0x7fffffff)).toBe(false);
});

test("stop() halts polling before the owner dies", () => {
  const sched = manualScheduler();
  let alive = true;
  const gone: string[] = [];
  const wd = startOwnerWatchdog({
    ownerPid: 9,
    isAlive: () => alive,
    schedule: sched.schedule,
    onOwnerGone: (r) => gone.push(r),
  });
  wd.stop();
  expect(sched.cleared).toBe(true);
  alive = false;
  sched.tick(); // no-op: scheduler was cleared
  expect(gone).toEqual([]);
});
