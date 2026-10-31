// Every bound the session bus enforces, named in one file so they can be tuned
// from evidence rather than from argument, and so no call site carries a magic
// number. A cap here is a product decision (what a peer may spend, what a phone
// can render, what a restart must be able to re-read), not a defensive guess.

/** How long a message this bridge could not send stays worth delivering. Past
 *  it the far side has moved on, and a stale message arrives as noise rather
 *  than as news. */
export const BUS_MESSAGE_TTL_MS = 6 * 60 * 60_000;

/** Outbound messages one session keeps until the far side acknowledges them.
 *  Past it the oldest goes and its log entry is stamped refused, so the loss is
 *  said to the sender rather than a session cut off for a day growing a file
 *  that loads as empty. */
export const MAX_HELD_MESSAGES = 32;

/** Unread posts one session's mailbox holds. A post interrupts nothing, so a
 *  chatty peer can fill this while its target is mid-turn; past it the OLDEST
 *  goes and the drop is COUNTED, so the loss is visible to the reader rather
 *  than merely bounded. */
export const MAX_MAILBOX_POSTS = 50;

/** How long an unread post, and the thread it belongs to, stay worth reading:
 *  a thread is garbage once its last message has aged out, so the thread
 *  store runs on this clock rather than growing an expiry of its own. */
export const MAILBOX_TTL_MS = 3 * 24 * 60 * 60_000;

/** Threads one session correlates at once. Above the mailbox bound on purpose:
 *  a notify leaves a thread row and no mail, so threads accrue from exchanges
 *  the mailbox never saw. Past it the oldest `lastAt` goes, and losing a row
 *  costs a reply the only record of where it goes — which is why the cap is
 *  loose rather than tight. */
export const MAX_THREADS_PER_SESSION = 100;

/** How stale the persisted copy of a pair budget may get. Every send and every
 *  applied inbound frame charges the budget, and writing the file each time
 *  would put a disk write behind each of them; a halt is written at once, so
 *  only the counters may lag. */
export const BUS_PERSIST_INTERVAL_MS = 5 * 60_000;

/** How long after a relay receipt a held message waits before it is offered to
 *  the relay again. The receipt says the relay holds it, so a faster resend is
 *  only a duplicate for the recipient to dedupe; this one exists to re-arm a
 *  relay that restarted and lost its queue, and the relay itself redelivers an
 *  unacked entry sooner than this when its recipient is online. */
export const BUS_RELAYED_RESEND_MS = 5 * 60_000;

/** First and longest step of the backoff between attempts at a message the relay
 *  has not yet acknowledged holding. */
export const BUS_RETRY_BASE_MS = 1_000;
export const BUS_RETRY_MAX_MS = 60_000;

/** How long a send waits for the relay's receipt before reporting the rung it
 *  has reached. Bounded because it sits inside a tool call an agent is blocked
 *  on; a slower receipt is still recorded and shows on the thread. */
export const BUS_RUNG_REPORT_WAIT_MS = 1_500;

/** Verdicts the receive side remembers so a resend is re-acked without being
 *  applied twice. Past it the oldest go, which re-opens a replay window only for
 *  a message older than everything the table still holds. */
export const MAX_BUS_SEEN = 10_000;

/** How long an inbound delivery waits for a cold project to open before it is
 *  applied anyway. The store write is durable whether or not the core is warm,
 *  so this bounds latency, not correctness. */
export const BUS_INBOUND_WARM_TIMEOUT_MS = 15_000;

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

/** Rows one peer machine's capability card may carry. Separate from
 *  `MAX_DIRECTORY_ROWS` (session-bus/directory.ts): this bounds what one
 *  answering machine spends per request, not what a merged directory reads
 *  back afterward. */
export const MAX_MACHINE_CARD_ROWS = 40;

/** Local rows `withLocalFloor` (session-bus/directory.ts) never lets a peer
 *  evict. `sortDirectory` has no locality key, so without a floor a peer with
 *  many same-branch running sessions can legitimately outrank and push every
 *  local row off a capped list — the remote half SUCCEEDING is what causes
 *  that, which is what makes it the easiest failure to miss. */
export const LOCAL_ROW_FLOOR = 20;

/** Repo keys one `includeSessions` capability-card request may name. A
 *  matching key, never an authorization input — the cap bounds how many
 *  cached `readRepoKey` probes one request can spend, not what it may see. */
export const MAX_DIRECTORY_REPO_KEYS = 8;

/** How long a refreshed machine's rows are trusted before
 *  `RemoteDirectoryCache` drops them and counts the machine stale. Two refresh
 *  intervals, so one missed ask (a slow peer, a relay blip) leaves the rows in
 *  place rather than blanking the directory. */
export const REMOTE_ROWS_TTL_MS = 120_000;

/** How often this machine asks each of the account's other machines for its
 *  capability card. */
export const REMOTE_DIRECTORY_REFRESH_MS = 30_000;

/** Machines one refresh cycle asks. A product bound, not a wire one: the rest
 *  wait for a later cycle, least recently refreshed first. */
export const MAX_REMOTE_DIRECTORY_MACHINES = 8;

/** A bus request waits this long for its response unless the caller says
 *  otherwise, and is never allowed to wait longer than the ceiling. */
export const BUS_REQUEST_DEFAULT_TIMEOUT_MS = 30_000;
export const BUS_REQUEST_MAX_TIMEOUT_MS = 300_000;

/** Requests one sending machine may have answered per minute. Every request
 *  costs this machine real work (the session-less capability card is up to two
 *  git spawns per project), so the bound is charged per sender before any of it
 *  is done. */
export const BUS_REQUESTS_PER_MIN_PER_MACHINE = 60;

/** A bridge's name for ITSELF on a purely local exchange when it has no
 *  relay identity to be addressed by — a machine launched local-only, or one
 *  whose control-plane registration never landed. Two sessions one bridge
 *  spawned need no network to reach each other, so refusing them an address
 *  refuses the one exchange that cannot fail for transport reasons.
 *
 *  Reserved, and never a real machine id: a relay device id is a uuid. It is
 *  PERSISTED into mailbox rows, thread rows and log peers like any other
 *  address, which is why `SessionBusCoordinator` treats it as naming this
 *  machine under whatever name the machine later acquires. */
export const LOCAL_MACHINE_ID = "local";

/** Rolling-hour `notify` ceiling per (sender, target) pair. `post` is
 *  unbudgeted, so this is deliberately tight: it pushes agents onto `post` for
 *  anything but the genuinely urgent, rather than onto the channel that
 *  interrupts a turn. A product decision, not a default — do not raise it back
 *  toward a "more generous" number without a decision to match. */
export const MAX_NOTIFIES_PER_PAIR_HOUR = 4;

/** Sends one (sender, target) pair may make with no artifact and no new thread
 *  between them before a halt trips. Counted on the OUTBOUND side only:
 *  the halt refuses sends, so what it bounds is what this session sent, and the
 *  peer holds its own row for its own half. Tight on purpose — it only bites
 *  where nobody is watching, because a human typing into either session clears
 *  it (`SessionBusCoordinator.clearHalt`). */
export const NO_PROGRESS_EXCHANGES = 6;
