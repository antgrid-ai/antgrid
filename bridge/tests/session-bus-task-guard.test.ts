// bridge/tests/session-bus-task-guard.test.ts
import { test, expect } from "bun:test";
import {
  MAX_TASKS_PER_HOUR,
  MAX_TASKS_PER_SESSION,
  NO_PROGRESS_EXCHANGES,
  TASK_RATE_WINDOW_MS,
  checkAssign,
  clearHalt,
  emptyGuard,
  guardBudget,
  noteExchange,
  noteProgress,
  type GuardState,
} from "../src/session-bus/task-guard";

const T0 = 5_000_000;

function createdAts(n: number, at = T0): number[] {
  return Array.from({ length: n }, () => at);
}

function halted(now = T0): GuardState {
  let g = emptyGuard();
  for (let i = 0; i < NO_PROGRESS_EXCHANGES; i += 1) g = noteExchange(g, now);
  return g;
}

test("an assign under both caps is allowed", () => {
  expect(checkAssign(emptyGuard(), [], T0)).toBeNull();
  expect(checkAssign(emptyGuard(), createdAts(MAX_TASKS_PER_HOUR - 1), T0)).toBeNull();
});

test("the lifetime cap refuses, and it counts tasks the window has forgotten", () => {
  const old = createdAts(MAX_TASKS_PER_SESSION, T0 - TASK_RATE_WINDOW_MS * 5);
  const refusal = checkAssign(emptyGuard(), old, T0)!;
  expect(refusal.code).toBe("TASK_CAP");
  expect(guardBudget(emptyGuard(), old, T0)).toMatchObject({
    tasksRemaining: 0,
    hourlyRemaining: MAX_TASKS_PER_HOUR,
  });
});

test("the rolling hour refuses and says when it frees, then allows again", () => {
  const recent = createdAts(MAX_TASKS_PER_HOUR, T0);
  const refusal = checkAssign(emptyGuard(), recent, T0 + 1)!;
  expect(refusal.code).toBe("TASK_RATE");
  expect(refusal.reason).toContain(new Date(T0 + TASK_RATE_WINDOW_MS).toISOString());

  expect(checkAssign(emptyGuard(), recent, T0 + TASK_RATE_WINDOW_MS)).toBeNull();
  expect(guardBudget(emptyGuard(), recent, T0 + TASK_RATE_WINDOW_MS)).toMatchObject({
    hourlyRemaining: MAX_TASKS_PER_HOUR,
    windowFreesAt: null,
  });
});

test("exchanges that advance nothing halt the session, and the halt outranks the caps", () => {
  let g = emptyGuard();
  for (let i = 1; i < NO_PROGRESS_EXCHANGES; i += 1) {
    g = noteExchange(g, T0);
    expect(g.haltedAt).toBeUndefined();
    expect(checkAssign(g, [], T0)).toBeNull();
  }
  g = noteExchange(g, T0 + 9);
  expect(g.haltedAt).toBe(T0 + 9);

  const refusal = checkAssign(g, [], T0 + 10)!;
  expect(refusal.code).toBe("NO_PROGRESS");
  expect(refusal.reason).toBe(g.haltReason!);
  expect(guardBudget(g, [], T0).halted).toBe(true);

  // A halted guard stops counting: the reason and the moment do not drift.
  expect(noteExchange(g, T0 + 100)).toBe(g);
});

test("progress resets the counter but never lifts a halt; only a human does", () => {
  let g = emptyGuard();
  for (let i = 0; i < NO_PROGRESS_EXCHANGES - 1; i += 1) g = noteExchange(g, T0);
  g = noteProgress(g);
  expect(g.exchanges).toBe(0);
  expect(noteProgress(g)).toBe(g);

  const stopped = halted();
  expect(noteProgress(stopped).haltedAt).toBe(stopped.haltedAt);
  const lifted = clearHalt(stopped);
  expect(lifted.haltedAt).toBeUndefined();
  expect(lifted.exchanges).toBe(0);
  expect(checkAssign(lifted, [], T0)).toBeNull();
  expect(clearHalt(lifted)).toBe(lifted);
});

test("a halt is liftable, and lifting it restores the exchange budget", () => {
  // A halt outranks every other verdict this fold can reach, so a guard nothing
  // could clear would bar the session for as long as the state is held.
  let g = emptyGuard();
  for (let i = 0; i < NO_PROGRESS_EXCHANGES; i += 1) g = noteExchange(g, T0);
  expect(g.haltedAt).toBe(T0);

  const lifted = clearHalt(g);
  expect(lifted.haltedAt).toBeUndefined();
  expect(lifted.exchanges).toBe(0);
  expect(checkAssign(lifted, [], T0)).toBeNull();

  // Nothing to lift is not an error, and returns the same object so a caller can
  // skip the write on every ordinary keystroke.
  expect(clearHalt(lifted)).toBe(lifted);
});
