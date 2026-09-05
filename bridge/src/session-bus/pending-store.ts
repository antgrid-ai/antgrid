// Spec 5.3's outstanding requests: the questions and assignments something still
// owes an answer to. Kept apart from the task record because a request outlives
// the exchange that made it — a peer's question survives the turn it was asked
// in, and the human who answers it may not be at this machine for hours.
//
// The pause rule is the task clock's, driven from the same cause: a request
// waiting on a human does not expire, so a task and its own question can never
// lapse on different schedules.

import { join } from "node:path";
import { z } from "zod";
import { MAX_PENDING, MAX_QUESTION_CHARS } from "./constants";
import { readStoreFile, sessionBusSessionDir, writeStoreFile } from "./store-fs";

export const PENDING_STORE_VERSION = 1;

export const PendingRequestSchema = z.object({
  requestId: z.string().min(1).max(200),
  taskId: z.string().min(1).max(200),
  contextId: z.string().min(1).max(200),
  /** What is owed: an answer from the lead, acceptance of an assignment, or the
   *  bytes behind an artifact handle. The three expire on the same clock but
   *  read very differently in a queue, so the kind is stored rather than
   *  inferred from which map the row happens to be in. */
  kind: z.enum(["ask-lead", "assign", "fetch"]),
  /** What was actually asked, as the answer will echo it back. */
  question: z.string().max(MAX_QUESTION_CHARS),
  askedAt: z.number(),
  expiresAt: z.number(),
  /** When the expiry clock stopped, set while the answer is owed by a human. */
  pausedAt: z.number().optional(),
  answeredAt: z.number().optional(),
  canceledAt: z.number().optional(),
  cancelReason: z.string().max(500).optional(),
});
export type PendingRequest = z.infer<typeof PendingRequestSchema>;

/** Fit a question to the row, marking the cut. The marker is the point: an
 *  answer echoes the stored question, and a lead reading a sentence that simply
 *  stops has no way to tell a truncation from the question it was asked. */
export function fitQuestion(question: string): string {
  if (question.length <= MAX_QUESTION_CHARS) return question;
  const marker = " […truncated]";
  return question.slice(0, MAX_QUESTION_CHARS - marker.length) + marker;
}

export const PendingFileSchema = z.object({
  version: z.literal(PENDING_STORE_VERSION),
  pending: z.array(PendingRequestSchema).max(MAX_PENDING),
});

export interface PendingState {
  readonly pending: readonly PendingRequest[];
}

export function emptyPending(): PendingState {
  return { pending: [] };
}

/** Still owed an answer. Answered and canceled rows are KEPT — the record that a
 *  request was answered is the only thing that distinguishes it from one that
 *  was never delivered — so every reader filters rather than trusting length. */
export function isOpenRequest(r: PendingRequest): boolean {
  return r.answeredAt === undefined && r.canceledAt === undefined;
}

export function openRequests(s: PendingState): PendingRequest[] {
  return s.pending.filter(isOpenRequest);
}

export function requestFor(s: PendingState, requestId: string): PendingRequest | null {
  return s.pending.find((r) => r.requestId === requestId) ?? null;
}

export function requestsForTask(s: PendingState, taskId: string): PendingRequest[] {
  return s.pending.filter((r) => r.taskId === taskId);
}

function replace(s: PendingState, next: PendingRequest): PendingState {
  return { pending: s.pending.map((r) => (r.requestId === next.requestId ? next : r)) };
}

/** Record a request this bridge is waiting on. Re-opening an id already present
 *  is a no-op: a redelivered ask must not restart the clock the human is already
 *  inside of. */
export function openRequest(s: PendingState, r: PendingRequest, now: number): PendingState {
  if (requestFor(s, r.requestId)) return s;
  const row: PendingRequest = { ...r, askedAt: r.askedAt || now };
  const pending = [...s.pending, row];
  // Past the cap the oldest SETTLED row goes first; an open request is never
  // evicted, because dropping it strands whoever is waiting on it.
  if (pending.length <= MAX_PENDING) return { pending };
  const victim = pending.find((x) => !isOpenRequest(x));
  return { pending: victim ? pending.filter((x) => x !== victim) : pending.slice(1) };
}

export function answerRequest(
  s: PendingState,
  requestId: string,
  now: number,
): { next: PendingState; request: PendingRequest | null } {
  const row = requestFor(s, requestId);
  if (!row || !isOpenRequest(row)) return { next: s, request: null };
  const answered: PendingRequest = { ...row, answeredAt: now };
  return { next: replace(s, answered), request: answered };
}

/** Close a request without an answer. Cancel means stop and report what was
 *  undone (spec 3.2), so the peer's reply to the cancel lands on the task as a
 *  finding — never as a state change, and never back here. */
export function cancelRequest(
  s: PendingState,
  requestId: string,
  reason: string | undefined,
  now: number,
): PendingState {
  const row = requestFor(s, requestId);
  if (!row || !isOpenRequest(row)) return s;
  return replace(s, {
    ...row,
    canceledAt: now,
    ...(reason ? { cancelReason: reason.slice(0, 500) } : {}),
  });
}

/** Stop the clock: the answer is owed by a human. */
export function pauseRequest(s: PendingState, requestId: string, now: number): PendingState {
  const row = requestFor(s, requestId);
  if (!row || !isOpenRequest(row) || row.pausedAt !== undefined) return s;
  return replace(s, { ...row, pausedAt: now });
}

/** Restart the clock, pushing the deadline out by exactly the time it was
 *  stopped — so the agent latency this bounds is measured across the pause and
 *  the human latency inside it is not counted at all. */
export function resumeRequest(s: PendingState, requestId: string, now: number): PendingState {
  const row = requestFor(s, requestId);
  if (!row || row.pausedAt === undefined) return s;
  const paused = Math.max(0, now - row.pausedAt);
  const next: PendingRequest = { ...row, expiresAt: row.expiresAt + paused };
  delete next.pausedAt;
  return replace(s, next);
}

/** Open requests whose deadline has passed. A paused row is never among them.
 *  The caller reports the lapse; nothing here fabricates an answer, because an
 *  unanswered question is not a "no" (D11). */
export function expiredRequests(s: PendingState, now: number): PendingRequest[] {
  return s.pending.filter((r) => isOpenRequest(r) && r.pausedAt === undefined && r.expiresAt <= now);
}

function pendingPath(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusSessionDir(abDir, projectId, sessionId), "pending.json");
}

export function loadPending(abDir: string, projectId: string, sessionId: string): PendingState {
  const file = readStoreFile<z.infer<typeof PendingFileSchema> | null>(
    pendingPath(abDir, projectId, sessionId),
    PendingFileSchema,
    null,
  );
  return file ? { pending: file.pending } : emptyPending();
}

export function savePending(abDir: string, projectId: string, sessionId: string, s: PendingState): void {
  const dir = sessionBusSessionDir(abDir, projectId, sessionId);
  writeStoreFile(join(dir, "pending.json"), dir, {
    version: PENDING_STORE_VERSION,
    pending: s.pending.slice(-MAX_PENDING),
  });
}
