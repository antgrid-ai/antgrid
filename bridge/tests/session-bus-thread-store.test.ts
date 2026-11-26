// bridge/tests/session-bus-thread-store.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  emptyThreads,
  expireThreads,
  loadThreads,
  saveThreads,
  threadById,
  upsertThread,
  type ThreadRow,
  type ThreadState,
} from "../src/session-bus/thread-store";
import { MAILBOX_TTL_MS, MAX_THREADS_PER_SESSION } from "../src/session-bus/constants";
import type { SessionMemberKey } from "../src/protocol";

const PEER: SessionMemberKey = { machineId: "m2", projectId: "p2", sessionId: "s2" };
const T0 = 5_000_000;

function row(over: Partial<ThreadRow> = {}): ThreadRow {
  return {
    threadId: "th-1",
    contextId: "ctx-peer",
    peer: PEER,
    lastAt: T0,
    openedByPeer: true,
    ...over,
  };
}

function filled(count: number): ThreadState {
  let s = emptyThreads();
  for (let i = 0; i < count; i += 1) s = upsertThread(s, row({ threadId: `th-${i}`, lastAt: T0 + i }));
  return s;
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-threads-"));
}

test("a thread a peer opened over a notify is recoverable by id, with the context it arrived on", () => {
  // A notified session holds NO mailbox row, so this store is the only thing
  // that can answer where a reply goes. Without it the reply defaults to the
  // replier's own session id, reads as "lead", and lands on this machine's own
  // desktop app — which accepts it and reports it sent.
  const s = upsertThread(emptyThreads(), row({ threadId: "th-notify", contextId: "ctx-theirs" }));

  const found = threadById(s, "th-notify");

  expect(found?.contextId).toBe("ctx-theirs");
  expect(found?.openedByPeer).toBe(true);
  expect(found?.peer).toEqual(PEER);
  expect(threadById(s, "th-unknown")).toBeNull();
});

test("a later frame on a thread advances it and re-points nothing", () => {
  // `contextId`, `peer` and who opened it are what a reply routes on. A frame
  // naming a thread already held — a stale one, or a peer's — must not be able
  // to move them.
  let s = upsertThread(emptyThreads(), row({ contextId: "ctx-theirs", lastAt: T0 }));
  s = upsertThread(s, row({ contextId: "ctx-mine", openedByPeer: false, lastAt: T0 + 50 }));

  const found = threadById(s, "th-1");

  expect(found?.contextId).toBe("ctx-theirs");
  expect(found?.openedByPeer).toBe(true);
  expect(found?.lastAt).toBe(T0 + 50);
  expect(s.threads).toHaveLength(1);
});

test("the bound evicts the thread nothing has written to for longest", () => {
  let s = filled(MAX_THREADS_PER_SESSION);
  // The head is usually the oldest; touching it is what makes the eviction read
  // `lastAt` rather than position.
  s = upsertThread(s, row({ threadId: "th-0", lastAt: T0 + 10_000 }));
  s = upsertThread(s, row({ threadId: "th-new", lastAt: T0 + 10_001 }));

  expect(s.threads).toHaveLength(MAX_THREADS_PER_SESSION);
  expect(threadById(s, "th-0")).not.toBeNull();
  expect(threadById(s, "th-1")).toBeNull();
  expect(threadById(s, "th-new")).not.toBeNull();
});

test("a thread both sides stopped writing to ages out", () => {
  // §4.2's "a thread is garbage once both sides stop writing", on the mailbox's
  // own clock: `lastAt` is what says when that was.
  let s = upsertThread(emptyThreads(), row({ threadId: "th-stale", lastAt: T0 }));
  s = upsertThread(s, row({ threadId: "th-live", lastAt: T0 + MAILBOX_TTL_MS }));

  const kept = expireThreads(s, T0 + MAILBOX_TTL_MS + 1);

  expect(kept.threads.map((t) => t.threadId)).toEqual(["th-live"]);
  expect(expireThreads(kept, T0 + MAILBOX_TTL_MS + 1)).toBe(kept);
});

test("threads survive a restart, per session", () => {
  const abDir = tmpAbDir();
  try {
    saveThreads(abDir, "p1", "s1", upsertThread(emptyThreads(), row({ threadId: "th-a", contextId: "ctx-a" })));
    saveThreads(abDir, "p1", "s2", upsertThread(emptyThreads(), row({ threadId: "th-b", contextId: "ctx-b" })));

    expect(threadById(loadThreads(abDir, "p1", "s1", T0 + 1), "th-a")?.contextId).toBe("ctx-a");
    expect(threadById(loadThreads(abDir, "p1", "s1", T0 + 1), "th-b")).toBeNull();
    expect(threadById(loadThreads(abDir, "p1", "s2", T0 + 1), "th-b")?.contextId).toBe("ctx-b");
    // And a session reloaded after a long silence does not come back holding
    // what the TTL already retired.
    expect(loadThreads(abDir, "p1", "s1", T0 + MAILBOX_TTL_MS + 1).threads).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});
