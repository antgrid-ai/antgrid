// Posts a session has been sent and has not read, plus the count of the ones it
// will never see.
//
// SEPARATE FROM THE MESSAGE LOG, WHICH CANNOT ANSWER THIS. The log is a bounded
// ring over BOTH directions that trims every part on the way in, so it can say
// what crossed and never what is still waiting — a mailbox folded out of it
// would hand the agent a trimmed body and re-offer a message already read. A
// post is read when the target chooses (§7.1); nothing interrupts a turn to
// deliver one, which is the whole reason it has to be parked somewhere.
//
// The bound is spent VISIBLY. Past MAX_MAILBOX_POSTS the oldest goes, past
// MAILBOX_TTL_MS the stale go, and both count into one persisted `dropped`: a
// reader that cannot tell an empty inbox from an emptied one has been told the
// wrong thing, not merely told less.

import { z } from "zod";
import { BusEnvelopeSchema } from "./envelope";
import { MAILBOX_TTL_MS, MAX_MAILBOX_POSTS, MAX_SUMMARY_CHARS } from "./constants";
import { SessionMemberKeySchema } from "../protocol";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

export const MailboxPostSchema = z.object({
  kind: z.literal("post"),
  // messageId, threadId, contextId and summary are all inside the envelope and
  // are copied out anyway: an inbox renders a list, and a list that had to parse
  // a body per row would pay for every message to show one line of each.
  messageId: z.string().min(1).max(200),
  /** Nullable because the WIRE field is: a peer running an older bridge sends
   *  null, and refusing the row over it would cost the reader the mail rather
   *  than the thread. */
  threadId: z.string().min(1).max(200).nullable(),
  contextId: z.string().min(1).max(200),
  at: z.number().int().nonnegative(),
  from: SessionMemberKeySchema,
  summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
  envelope: BusEnvelopeSchema,
  read: z.boolean(),
});
export type MailboxPost = z.infer<typeof MailboxPostSchema>;

/** The drop count is a row of its own, in the same table, because it has to
 *  OUTLIVE every post it counts: the store seam under it holds a list per scope
 *  with no slot for a scalar, and a number hung off the newest post would be
 *  lost at the exact moment the bound was spent. */
const MailboxDropsSchema = z.object({
  kind: z.literal("drops"),
  dropped: z.number().int().nonnegative(),
});

const MailboxRowSchema = z.discriminatedUnion("kind", [MailboxPostSchema, MailboxDropsSchema]);

/** One row over the post cap, for the drop count. Reading a narrower window
 *  would silently lose whichever end fell outside it. */
const MAILBOX_ROW_CAP = MAX_MAILBOX_POSTS + 1;

export interface MailboxState {
  readonly posts: readonly MailboxPost[];
  readonly dropped: number;
}

export function emptyMailbox(): MailboxState {
  return { posts: [], dropped: 0 };
}

/** Drop what has aged out, counting it into the same `dropped` the cap feeds.
 *  One counter for both, because the reader's question is how much it lost and
 *  never which bound took it. */
export function expireOldPosts(s: MailboxState, now: number): MailboxState {
  const posts = s.posts.filter((p) => now - p.at < MAILBOX_TTL_MS);
  if (posts.length === s.posts.length) return s;
  return { posts, dropped: s.dropped + (s.posts.length - posts.length) };
}

/** Park one post. Expires first, so a mailbox nobody has read does not evict
 *  live mail to make room for what is arriving. */
export function appendPost(s: MailboxState, post: MailboxPost, now: number): MailboxState {
  const fresh = expireOldPosts(s, now);
  const posts = [...fresh.posts, post];
  const over = posts.length - MAX_MAILBOX_POSTS;
  return over > 0
    ? { posts: posts.slice(over), dropped: fresh.dropped + over }
    : { posts, dropped: fresh.dropped };
}

export function markRead(s: MailboxState, messageIds: readonly string[]): MailboxState {
  if (messageIds.length === 0) return s;
  const wanted = new Set(messageIds);
  let changed = false;
  const posts = s.posts.map((p) => {
    if (p.read || !wanted.has(p.messageId)) return p;
    changed = true;
    return { ...p, read: true };
  });
  return changed ? { ...s, posts } : s;
}

export function unreadPosts(s: MailboxState): MailboxPost[] {
  return s.posts.filter((p) => !p.read);
}

export function unreadCount(s: MailboxState): number {
  return unreadPosts(s).length;
}

/** Expiry runs on the way OUT of the database as well as on every append: a
 *  session nobody wrote to for a week would otherwise come back holding mail
 *  the TTL had already retired, and the constant would be decoration. */
export function loadMailbox(abDir: string, projectId: string, sessionId: string, now = Date.now()): MailboxState {
  const rows = readBusDb(
    abDir,
    (db) => readRecords(db, "bus_mailbox", "item", { projectId, sessionId }, MAILBOX_ROW_CAP, MailboxRowSchema),
    [] as z.infer<typeof MailboxRowSchema>[],
  );
  const posts: MailboxPost[] = [];
  let dropped = 0;
  for (const row of rows) {
    if (row.kind === "drops") dropped += row.dropped;
    else posts.push(row);
  }
  return expireOldPosts({ posts, dropped }, now);
}

export function saveMailbox(abDir: string, projectId: string, sessionId: string, s: MailboxState): void {
  withBusDb(
    abDir,
    (db) =>
      // The count goes FIRST so an ordinary append stays a suffix of what is
      // stored: `replaceRecords` aligns on a leading prefix, and a counter at
      // the tail would rewrite the whole scope on every message.
      replaceRecords(db, "bus_mailbox", "item", { projectId, sessionId }, [
        { kind: "drops", dropped: s.dropped },
        ...s.posts.slice(-MAX_MAILBOX_POSTS),
      ]),
    undefined,
  );
}
