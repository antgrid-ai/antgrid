// bridge/tests/session-bus-pending-store.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  answerRequest,
  fitQuestion,
  cancelRequest,
  emptyPending,
  expiredRequests,
  isOpenRequest,
  loadPending,
  openRequest,
  openRequests,
  pauseRequest,
  requestFor,
  requestsForTask,
  resumeRequest,
  savePending,
  type PendingRequest,
  type PendingState,
} from "../src/session-bus/pending-store";
import { MAX_PENDING, MAX_QUESTION_CHARS } from "../src/session-bus/constants";
import { sessionBusSessionDir } from "../src/session-bus/store-fs";

const T0 = 2_000_000;

function req(over: Partial<PendingRequest> = {}): PendingRequest {
  return {
    requestId: "r1",
    taskId: "t1",
    contextId: "c1",
    kind: "ask-lead",
    question: "which branch should I target?",
    askedAt: T0,
    expiresAt: T0 + 60_000,
    ...over,
  };
}

function opened(over: Partial<PendingRequest> = {}): PendingState {
  return openRequest(emptyPending(), req(over), T0);
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-pending-"));
}

test("a request opens once; a redelivered ask does not restart its clock", () => {
  const s = opened();
  expect(openRequests(s)).toHaveLength(1);
  const again = openRequest(s, req({ expiresAt: T0 + 999_999 }), T0 + 30_000);
  expect(again).toBe(s);
  expect(requestFor(again, "r1")!.expiresAt).toBe(T0 + 60_000);
});

test("answering closes the request and returns the row that was answered", () => {
  const s = opened();
  const { next, request } = answerRequest(s, "r1", T0 + 10);
  expect(request!.answeredAt).toBe(T0 + 10);
  expect(openRequests(next)).toEqual([]);
  // The answered row is KEPT — it is the record that the answer arrived.
  expect(requestFor(next, "r1")).not.toBeNull();
  expect(isOpenRequest(requestFor(next, "r1")!)).toBe(false);

  // A second answer, and an answer to a request nobody opened, change nothing.
  expect(answerRequest(next, "r1", T0 + 20)).toEqual({ next, request: null });
  expect(answerRequest(next, "missing", T0 + 20)).toEqual({ next, request: null });
});

test("cancel closes without an answer and records the reason", () => {
  const s = cancelRequest(opened(), "r1", "lead abandoned the task", T0 + 5);
  const row = requestFor(s, "r1")!;
  expect(row.canceledAt).toBe(T0 + 5);
  expect(row.cancelReason).toBe("lead abandoned the task");
  expect(row.answeredAt).toBeUndefined();
  expect(openRequests(s)).toEqual([]);
  expect(cancelRequest(s, "r1", "again", T0 + 6)).toBe(s);
});

test("a paused request never expires, and resuming pushes the deadline out by the pause", () => {
  const s = pauseRequest(opened(), "r1", T0 + 10);
  expect(requestFor(s, "r1")!.pausedAt).toBe(T0 + 10);
  expect(expiredRequests(s, T0 + 10_000_000)).toEqual([]);

  const resumedAt = T0 + 10 + 5_000_000;
  const back = resumeRequest(s, "r1", resumedAt);
  const row = requestFor(back, "r1")!;
  expect(row.pausedAt).toBeUndefined();
  expect(row.expiresAt).toBe(T0 + 60_000 + 5_000_000);
  expect(expiredRequests(back, row.expiresAt - 1)).toEqual([]);
  expect(expiredRequests(back, row.expiresAt).map((r) => r.requestId)).toEqual(["r1"]);
});

test("pausing twice is a no-op, and resuming what was never paused changes nothing", () => {
  const s = pauseRequest(opened(), "r1", T0 + 10);
  expect(pauseRequest(s, "r1", T0 + 99)).toBe(s);
  const never = opened();
  expect(resumeRequest(never, "r1", T0 + 99)).toBe(never);
  expect(resumeRequest(never, "missing", T0 + 99)).toBe(never);
});

test("an answered or canceled request is never reported as expired", () => {
  const answered = answerRequest(opened(), "r1", T0 + 1).next;
  expect(expiredRequests(answered, T0 + 10_000_000)).toEqual([]);
  const canceled = cancelRequest(opened(), "r1", undefined, T0 + 1);
  expect(expiredRequests(canceled, T0 + 10_000_000)).toEqual([]);
});

test("past the cap a settled row is evicted before any open one", () => {
  let s = emptyPending();
  for (let i = 0; i < MAX_PENDING; i += 1) {
    s = openRequest(s, req({ requestId: `r${i}`, taskId: `t${i}` }), T0);
  }
  s = answerRequest(s, "r0", T0 + 1).next;
  s = openRequest(s, req({ requestId: "overflow" }), T0 + 2);

  expect(s.pending).toHaveLength(MAX_PENDING);
  expect(requestFor(s, "r0")).toBeNull();
  expect(requestFor(s, "r1")).not.toBeNull();
  expect(requestFor(s, "overflow")).not.toBeNull();
});

test("requests are addressable by task", () => {
  let s = opened();
  s = openRequest(s, req({ requestId: "r2", taskId: "t2", kind: "fetch" }), T0);
  expect(requestsForTask(s, "t1").map((r) => r.requestId)).toEqual(["r1"]);
  expect(requestsForTask(s, "t2")[0]!.kind).toBe("fetch");
});

test("a paused request reloads still paused; a corrupt file loads as empty", () => {
  const abDir = tmpAbDir();
  try {
    const s = pauseRequest(opened(), "r1", T0 + 10);
    savePending(abDir, "p1", "s1", s);
    const back = loadPending(abDir, "p1", "s1");
    expect(requestFor(back, "r1")!.pausedAt).toBe(T0 + 10);
    expect(expiredRequests(back, T0 + 10_000_000)).toEqual([]);

    const dir = sessionBusSessionDir(abDir, "p1", "s1");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "pending.json"), "{truncated");
    expect(loadPending(abDir, "p1", "s1").pending).toEqual([]);

    writeFileSync(join(dir, "pending.json"), JSON.stringify({ version: 99, pending: [] }));
    expect(loadPending(abDir, "p1", "s1").pending).toEqual([]);

    expect(loadPending(abDir, "p1", "never-written").pending).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a question too long for the row is cut with the cut marked", () => {
  const short = "x".repeat(10);
  expect(fitQuestion(short)).toBe(short);

  const long = "x".repeat(MAX_QUESTION_CHARS + 500);
  const fitted = fitQuestion(long);
  expect(fitted.length).toBe(MAX_QUESTION_CHARS);
  // The row is what the answer renderer echoes back, so a question that simply
  // stops mid-sentence reads to the peer as the question it was asked. It also
  // has to FIT: the schema caps the field, and a row that fails validation on
  // the way out loses the request the peer is already blocked on.
  expect(fitted).toEndWith(" […truncated]");
});
