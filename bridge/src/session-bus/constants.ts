// Every bound the session bus enforces, named in one file so they can be tuned
// from evidence rather than from argument, and so no call site carries a magic
// number. A cap here is a product decision (what a peer may spend, what a phone
// can render, what a restart must be able to re-read), not a defensive guess.

/** How long an assigned task lives before the bridge calls it lapsed. The clock
 *  PAUSES while the task is waiting on a human (spec 5.3), so this bounds agent
 *  latency and never human latency. */
export const TASK_EXPIRY_MS = 6 * 60 * 60_000;

/** Ceiling on the task rows one session's `tasks.json` carries. The file is
 *  re-read whole on every bridge start, and the schema refuses an over-cap
 *  array — so the writer prunes to this rather than letting a long-lived lead
 *  session grow a file that loads as empty. */
export const MAX_TASKS_PERSISTED = 200;

/** Findings kept per task. A finding is the durable half of a message (spec 6),
 *  so this is what a lead can still read after a peer is gone; past it the
 *  oldest is dropped. */
export const MAX_FINDINGS = 50;

/** Artifact handles referenced by one task. */
export const MAX_TASK_ARTIFACTS = 32;

/** Unacked transitions held per task. Stop-and-wait (D13) keeps this at one in
 *  practice; the bound exists so a bug cannot grow a persisted array without
 *  limit and take the whole store's parse down with it. */
export const MAX_OUTBOX = 8;

/** Outbound messages one session holds for want of a route. D13 allows a
 *  message to be lost, so this bound is where that allowance is actually spent:
 *  past it the oldest held finding goes, rather than a peer cut off for a day
 *  growing a file that loads as empty. */
export const MAX_HELD_MESSAGES = 32;

/** How stale the persisted copy of a carrier route may get while the live one is
 *  being refreshed. Every applied inbound frame restamps a route, and writing
 *  the file each time would put a disk write behind every ack; skipping the
 *  write entirely would let a busy context's persisted timestamp age past the
 *  TTL and be dropped on the next restart while it was never idle. */
export const BUS_ROUTE_PERSIST_INTERVAL_MS = 5 * 60_000;

/** Carrier routes one project remembers across a restart. A route is one live
 *  membership's way home, and `MAX_SESSION_MEMBERS` bounds how many of those a
 *  session has — this is deliberately looser, because expired contexts are
 *  pruned lazily and a project may hold several sessions at once. */
export const MAX_BUS_ROUTES = 64;

/** Retry schedule for an unacked transition, held at the last entry forever
 *  after. There is deliberately no give-up: D11 forbids inferring a state change
 *  from an absence, so a peer offline for an hour has not failed its task. */
export const SESSION_BUS_RETRY_BACKOFF_MS = [1_000, 5_000, 15_000, 60_000] as const;

/** Outstanding requests kept per session (spec 5.3), answered and open
 *  together — a request that was answered is the record proving it was. */
export const MAX_PENDING = 64;

/** The largest artifact one publish may store. Content is written beside the
 *  record and fetched in slices, so this bounds a single peer's evidence, not
 *  the frame that references it. */
export const MAX_ARTIFACT_BYTES = 4 * 1024 * 1024;

/** One `session-bus:fetch` slice. Sized so a chunk plus its base64 expansion
 *  stays well inside a relay frame. */
export const ARTIFACT_CHUNK_BYTES = 64 * 1024;

/** Base64 length of a full chunk, for the wire schema's bound. Derived rather
 *  than written out so the two can never drift. */
export const ARTIFACT_CHUNK_B64_MAX = Math.ceil(ARTIFACT_CHUNK_BYTES / 3) * 4;

/** Artifact records kept per session. */
export const MAX_ARTIFACTS = 200;

/** The message log is a rendering aid, not the record of record — the task
 *  store is. Bounded as a ring so it cannot outgrow the store it annotates. */
export const MAX_LOG_ENTRIES = 500;

/** Part text kept in the LOG. Far below [MAX_PART_CHARS]: the log exists so a
 *  human can see what crossed, and the full part already lives in the finding
 *  or the artifact it came with. */
export const MAX_LOGGED_PART_CHARS = 2_000;

/** One text part on the wire. */
export const MAX_PART_CHARS = 32_000;

/** Parts in one envelope. */
export const MAX_PARTS = 16;

/** The one-line summary spec 6.1 makes mandatory on every message. Short on
 *  purpose: it is what the phone's queue renders, and a paragraph there is a
 *  queue nobody can scan. */
export const MAX_SUMMARY_CHARS = 400;

/** The durable text of a finding. */
export const MAX_FINDING_CHARS = 8_000;

/** The asked question kept in a pending row. Far above [MAX_SUMMARY_CHARS],
 *  because the answer echoes the question back verbatim and a summary is not
 *  what the lead answered; far below [MAX_PART_CHARS], because up to
 *  [MAX_PENDING] of these live in one file that is read on every delivery. A
 *  question longer than this is truncated with a visible marker, never silently.
 */
export const MAX_QUESTION_CHARS = 4_000;

/** Spec 6.2's first-class "here is something you did not ask about" channel. */
export const MAX_UNEXPECTED_CHARS = 4_000;

/** Ceiling on a SERIALIZED envelope, checked before it is queued. Generous for a
 *  summary and deliberately stingy for a diff: past it the answer is
 *  publish-artifact, because an unbounded result is an unbounded prompt on the
 *  other machine. */
export const MAX_ENVELOPE_BYTES = 64 * 1024;
