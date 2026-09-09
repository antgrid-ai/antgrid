// Every bound the session bus enforces, named in one file so they can be tuned
// from evidence rather than from argument, and so no call site carries a magic
// number. A cap here is a product decision (what a peer may spend, what a phone
// can render, what a restart must be able to re-read), not a defensive guess.

/** How long a message this bridge could not send stays worth delivering. Past
 *  it the far side has moved on, and a stale message arrives as noise rather
 *  than as news. */
export const BUS_MESSAGE_TTL_MS = 6 * 60 * 60_000;

/** How long a learned carrier route is trusted without being re-proven. Sized to
 *  outlast an ordinary exchange so a reply does not arrive to find its way home
 *  forgotten; a route that has expired costs one relearn, never a misdelivery
 *  (route-store.ts). */
export const BUS_ROUTE_TTL_MS = 6 * 60 * 60_000;

/** Outbound messages one session holds for want of a route. A message is
 *  allowed to be lost, so this bound is where that allowance is actually spent:
 *  past it the oldest held message goes, rather than a session cut off for a day
 *  growing a file that loads as empty. */
export const MAX_HELD_MESSAGES = 32;

/** How stale the persisted copy of a carrier route may get while the live one is
 *  being refreshed. Every applied inbound frame restamps a route, and writing
 *  the file each time would put a disk write behind every ack; skipping the
 *  write entirely would let a busy context's persisted timestamp age past the
 *  TTL and be dropped on the next restart while it was never idle. */
export const BUS_ROUTE_PERSIST_INTERVAL_MS = 5 * 60_000;

/** Carrier routes one project remembers across a restart. One live exchange has
 *  one way home; this is deliberately loose, because expired contexts are pruned
 *  lazily and a project may hold several conversations at once. */
export const MAX_BUS_ROUTES = 64;

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

/** The message log is a rendering aid, not the durable copy — an Artifact is.
 *  Bounded as a ring so it cannot outgrow the artifacts it annotates. */
export const MAX_LOG_ENTRIES = 500;

/** Part text kept in the LOG. Far below [MAX_PART_CHARS]: the log exists so a
 *  human can see what crossed, and anything worth keeping whole was published as
 *  an artifact. */
export const MAX_LOGGED_PART_CHARS = 2_000;

/** One text part on the wire. */
export const MAX_PART_CHARS = 32_000;

/** Parts in one envelope. */
export const MAX_PARTS = 16;

/** The one-line summary every message carries. Short on purpose: it is what a
 *  mailbox and a phone's queue render, and a paragraph there is a list nobody
 *  can scan. */
export const MAX_SUMMARY_CHARS = 400;

/** The first-class "here is something you did not ask about" channel. */
export const MAX_UNEXPECTED_CHARS = 4_000;

/** Ceiling on a SERIALIZED envelope, checked before it is queued. Generous for a
 *  summary and deliberately stingy for a diff: past it the answer is
 *  publish-artifact, because an unbounded result is an unbounded prompt on the
 *  other machine. */
export const MAX_ENVELOPE_BYTES = 64 * 1024;
