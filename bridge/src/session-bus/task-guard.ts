// Spec 8. Two agents that can assign each other work with no human between them
// are a closed loop, and the loop spends tokens on two machines. This is the
// same shape as `handler/runaway-guard.ts` — a cap plus a progress reset — and
// like it, refusing is all it ever does: nothing here cancels, fails or deletes.
//
// The counts are DERIVED FROM THE TASK RECORDS' `createdAt`, never from a
// counter of their own, so a bridge restart cannot launder a runaway by
// forgetting. Only the no-progress state has a counter, because "exchanges since
// something moved" is not visible in the records.

import { z } from "zod";

/** Lifetime cap on one lead session's assigns. */
export const MAX_TASKS_PER_SESSION = 24;

/** Rolling cap over [TASK_RATE_WINDOW_MS]. */
export const MAX_TASKS_PER_HOUR = 8;

export const TASK_RATE_WINDOW_MS = 60 * 60_000;

/** Bus exchanges that advance nothing before the context is halted. */
export const NO_PROGRESS_EXCHANGES = 6;

export const GuardStateSchema = z.object({
  /** Bus exchanges since the last one that moved the work forward. */
  exchanges: z.number().int().nonnegative().default(0),
  /** Set when {@link noteExchange} hits the no-progress ceiling. A halt is NOT a
   *  cancel: every task stays exactly as it is, because inferring failure from a
   *  stall is precisely what D11 forbids. Only a human clears it. */
  haltedAt: z.number().optional(),
  haltReason: z.string().max(500).optional(),
});
export type GuardState = z.infer<typeof GuardStateSchema>;

export type GuardCode = "TASK_CAP" | "TASK_RATE" | "NO_PROGRESS";

/** A refusal the caller returns verbatim: the reason is authored once, here, and
 *  the tool that surfaces it never re-words it. */
export interface GuardRefusal {
  code: GuardCode;
  reason: string;
}

export interface GuardBudget {
  /** Assigns left against the lifetime cap. */
  tasksRemaining: number;
  /** Assigns left in the current rolling hour. */
  hourlyRemaining: number;
  /** When the rolling window next frees a slot, or null when it is not the
   *  binding constraint. */
  windowFreesAt: number | null;
  halted: boolean;
}

export function emptyGuard(): GuardState {
  return { exchanges: 0 };
}

function inWindow(createdAts: readonly number[], now: number): number[] {
  return createdAts.filter((at) => now - at < TASK_RATE_WINDOW_MS).sort((a, b) => a - b);
}

export function guardBudget(
  guard: GuardState,
  createdAts: readonly number[],
  now: number,
): GuardBudget {
  const recent = inWindow(createdAts, now);
  const oldest = recent.length >= MAX_TASKS_PER_HOUR ? recent[recent.length - MAX_TASKS_PER_HOUR] : undefined;
  return {
    tasksRemaining: Math.max(0, MAX_TASKS_PER_SESSION - createdAts.length),
    hourlyRemaining: Math.max(0, MAX_TASKS_PER_HOUR - recent.length),
    windowFreesAt: oldest === undefined ? null : oldest + TASK_RATE_WINDOW_MS,
    halted: guard.haltedAt !== undefined,
  };
}

/**
 * Whether one more assign is allowed, given every task this session has ever
 * minted. Null means yes.
 *
 * Enforced in the BRIDGE, at the assign route — never in the MCP server, which
 * is a per-process client of the loopback API and is the thing being bounded.
 */
export function checkAssign(
  guard: GuardState,
  createdAts: readonly number[],
  now: number,
): GuardRefusal | null {
  if (guard.haltedAt !== undefined) {
    return {
      code: "NO_PROGRESS",
      reason:
        guard.haltReason ??
        `this session is halted after ${NO_PROGRESS_EXCHANGES} exchanges that advanced nothing; a human has to look before it resumes`,
    };
  }
  if (createdAts.length >= MAX_TASKS_PER_SESSION) {
    return {
      code: "TASK_CAP",
      reason: `${MAX_TASKS_PER_SESSION} tasks is the lifetime cap for one session; start a new session for further work`,
    };
  }
  const budget = guardBudget(guard, createdAts, now);
  if (budget.hourlyRemaining === 0) {
    // ISO rather than a local clock time: this string is authored on the bridge
    // and read on whatever machine and locale the agent or the human is on, so
    // a rendered wall-clock hour would be wrong for one of them.
    const frees = budget.windowFreesAt === null ? "" : `; the window frees at ${new Date(budget.windowFreesAt).toISOString()}`;
    return {
      code: "TASK_RATE",
      reason: `${MAX_TASKS_PER_HOUR} tasks per hour on this session${frees}`,
    };
  }
  return null;
}

/** Any bus message in or out. Returns the same object when nothing changes, so a
 *  caller can skip a flush. */
export function noteExchange(guard: GuardState, now: number): GuardState {
  if (guard.haltedAt !== undefined) return guard;
  const exchanges = guard.exchanges + 1;
  if (exchanges < NO_PROGRESS_EXCHANGES) return { ...guard, exchanges };
  return {
    exchanges,
    haltedAt: now,
    haltReason: `${NO_PROGRESS_EXCHANGES} bus exchanges advanced no task; a human has to look before this session assigns again`,
  };
}

/** A transition actually applied, or an artifact published — the two things that
 *  move the work forward. Resets the counter but deliberately NOT the halt: a
 *  halt is a human's to lift, and clearing it on the next scrap of progress is
 *  how a loop that produces motion without result stays invisible. */
export function noteProgress(guard: GuardState): GuardState {
  if (guard.exchanges === 0) return guard;
  return { ...guard, exchanges: 0 };
}

/** Lift a no-progress halt. Only a human's action reaches this. */
export function clearHalt(guard: GuardState): GuardState {
  if (guard.haltedAt === undefined) return guard;
  return { exchanges: 0 };
}
