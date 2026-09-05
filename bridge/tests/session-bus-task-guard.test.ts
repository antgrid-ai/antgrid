// bridge/tests/session-bus-task-guard.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
import {
  applyTransition,
  emptyTasks,
  loadTasks,
  mintTask,
  saveTasks,
  taskCreatedAts,
  type TaskStoreState,
} from "../src/session-bus/task-store";
import type { SessionMemberRef } from "../src/protocol";

const PEER: SessionMemberRef = { machineId: "m2", projectId: "p2", sessionId: "s2" };
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

test("an applied transition counts as progress in the task store's own fold", () => {
  let s: TaskStoreState = emptyTasks();
  for (let i = 0; i < NO_PROGRESS_EXCHANGES - 1; i += 1) {
    s = { guard: noteExchange(s.guard, T0), tasks: s.tasks };
  }
  expect(s.guard.exchanges).toBe(NO_PROGRESS_EXCHANGES - 1);

  const applied = applyTransition(
    s,
    {
      taskId: "t1",
      contextId: "c1",
      seq: 0,
      state: "submitted",
      peer: PEER,
      messageId: "m-0",
      summary: "do the thing",
    },
    T0,
  );
  expect(applied.kind).toBe("applied");
  expect(applied.next.guard.exchanges).toBe(0);
});

test("the counts survive a reload, so a restart cannot launder a runaway", () => {
  const abDir = mkdtempSync(join(tmpdir(), "ab-bus-guard-"));
  try {
    let s = emptyTasks();
    for (let i = 0; i < MAX_TASKS_PER_SESSION; i += 1) {
      s = mintTask(s, { taskId: `t${i}`, contextId: "c1", peer: PEER, title: `task ${i}`, now: T0 }).next;
    }
    s = { guard: halted(T0), tasks: s.tasks };
    saveTasks(abDir, "p1", "s1", s);

    const back = loadTasks(abDir, "p1", "s1");
    expect(taskCreatedAts(back)).toHaveLength(MAX_TASKS_PER_SESSION);
    expect(back.guard.haltedAt).toBe(T0);
    expect(checkAssign(back.guard, taskCreatedAts(back), T0)!.code).toBe("NO_PROGRESS");
    expect(checkAssign(clearHalt(back.guard), taskCreatedAts(back), T0)!.code).toBe("TASK_CAP");
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a halt is liftable, and lifting it restores the exchange budget", () => {
  // The halt is persisted, so a guard nothing could clear would bar this session
  // from ever assigning again — for the life of the checkout, across restarts.
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
