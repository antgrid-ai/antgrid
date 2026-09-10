// bridge/tests/session-bus-mailbox.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendPost,
  emptyMailbox,
  loadMailbox,
  markRead,
  saveMailbox,
  unreadCount,
  unreadPosts,
  type MailboxPost,
  type MailboxState,
} from "../src/session-bus/mailbox";
import { stampEnvelope } from "../src/session-bus/envelope";
import { MAILBOX_TTL_MS, MAX_MAILBOX_POSTS } from "../src/session-bus/constants";
import type { SessionMemberKey, SessionMemberRef } from "../src/protocol";

const FROM: SessionMemberKey = { machineId: "m2", projectId: "p2", sessionId: "s2" };
const PEER: SessionMemberRef = { ...FROM, sessionName: "the other agent" };
const T0 = 5_000_000;

function post(over: { messageId?: string; at?: number; threadId?: string | null; read?: boolean } = {}): MailboxPost {
  const messageId = over.messageId ?? "m-1";
  const at = over.at ?? T0;
  const threadId = over.threadId === undefined ? "th-1" : over.threadId;
  return {
    kind: "post",
    messageId,
    threadId,
    contextId: "ctx-1",
    at,
    from: FROM,
    summary: "the suite is green",
    envelope: stampEnvelope(
      { threadId, contextId: "ctx-1", parts: [{ kind: "text", text: "every test passed" }], summary: "the suite is green" },
      { messageId, peer: PEER, now: at },
    ),
    read: over.read ?? false,
  };
}

function filled(count: number, from = 0): MailboxState {
  let s = emptyMailbox();
  for (let i = from; i < from + count; i += 1) s = appendPost(s, post({ messageId: `m-${i}`, at: T0 + i }), T0 + i);
  return s;
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-mailbox-"));
}

test("the bound spends the oldest post, and says how many it spent", () => {
  // §7.4 makes the drop VISIBLE to the reader, not merely bounded: an inbox
  // that silently forgot is one whose reader cannot tell it from an empty one.
  const s = filled(MAX_MAILBOX_POSTS + 3);

  expect(s.posts).toHaveLength(MAX_MAILBOX_POSTS);
  expect(s.posts[0]!.messageId).toBe("m-3");
  expect(s.dropped).toBe(3);
});

test("a post past the TTL is dropped into the same counter as the bound", () => {
  // One counter for both bounds, because the reader's question is how much it
  // lost and never which rule took it.
  let s = appendPost(emptyMailbox(), post({ messageId: "m-old", at: T0 }), T0);
  s = appendPost(s, post({ messageId: "m-new", at: T0 + MAILBOX_TTL_MS + 1 }), T0 + MAILBOX_TTL_MS + 1);

  expect(s.posts.map((p) => p.messageId)).toEqual(["m-new"]);
  expect(s.dropped).toBe(1);
});

test("expiry runs before the append, so live mail is not evicted for it", () => {
  // The other order fills the mailbox with stale posts, then spends the cap on
  // the newest thing that arrived.
  const now = T0 + MAILBOX_TTL_MS + MAX_MAILBOX_POSTS;
  let s = filled(MAX_MAILBOX_POSTS);
  s = appendPost(s, post({ messageId: "m-fresh", at: now }), now);

  expect(s.posts.map((p) => p.messageId)).toEqual(["m-fresh"]);
  expect(s.dropped).toBe(MAX_MAILBOX_POSTS);
});

test("reading marks exactly what was read", () => {
  let s = filled(3);
  expect(unreadCount(s)).toBe(3);

  s = markRead(s, ["m-1", "m-does-not-exist"]);

  expect(unreadPosts(s).map((p) => p.messageId)).toEqual(["m-0", "m-2"]);
  expect(unreadCount(s)).toBe(2);
  // A mark that changed nothing must not churn the state a save writes back.
  expect(markRead(s, ["m-1"])).toBe(s);
});

test("a mailbox survives a restart, the drop count with it", () => {
  const abDir = tmpAbDir();
  try {
    let s = filled(MAX_MAILBOX_POSTS + 2);
    s = markRead(s, [s.posts[0]!.messageId]);
    saveMailbox(abDir, "p1", "s1", s);

    const back = loadMailbox(abDir, "p1", "s1", T0 + MAX_MAILBOX_POSTS + 2);

    expect(back.posts.map((p) => p.messageId)).toEqual(s.posts.map((p) => p.messageId));
    // The counter is what the bound was spent ON, so it has to outlive every
    // post it counts.
    expect(back.dropped).toBe(2);
    expect(unreadCount(back)).toBe(MAX_MAILBOX_POSTS - 1);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("mail that aged out while the process was down does not come back", () => {
  const abDir = tmpAbDir();
  try {
    saveMailbox(abDir, "p1", "s1", filled(2));

    const back = loadMailbox(abDir, "p1", "s1", T0 + MAILBOX_TTL_MS + 10);

    expect(back.posts).toEqual([]);
    expect(back.dropped).toBe(2);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("one session's mail is not another's", () => {
  const abDir = tmpAbDir();
  try {
    saveMailbox(abDir, "p1", "s1", filled(2));
    saveMailbox(abDir, "p1", "s2", filled(1, 100));

    expect(loadMailbox(abDir, "p1", "s1", T0 + 5).posts.map((p) => p.messageId)).toEqual(["m-0", "m-1"]);
    expect(loadMailbox(abDir, "p1", "s2", T0 + 105).posts.map((p) => p.messageId)).toEqual(["m-100"]);
    expect(loadMailbox(abDir, "p2", "s1", T0 + 5).posts).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});
