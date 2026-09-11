// Spec §7.4/§8.2/§11: two agents that can post, notify and reply to each other
// with nobody between them are a closed loop, and the loop spends tokens on two
// machines. This bounds it per **(sender, target) pair** — not per session and
// not per machine — because a per-session ceiling lets a halted pair carry on
// through a third session, and a per-machine one lets one session spend
// another's budget (see "the no-progress halt is per (sender, target) PAIR" in
// bridge/CLAUDE.md).
//
// The record is MIRRORED, not shared: the two ends of a pair can be on two
// machines, and neither can write the other's store, so each keeps its own copy
// and every message is charged at BOTH ends — where it is sent
// (`SessionBusCoordinator.message`) and where it lands (`onMessage`). Charging
// only the outbound half is what makes the two copies diverge, and divergence
// is not a cosmetic difference: each end then counts only the messages IT sent,
// so [NO_PROGRESS_EXCHANGES] takes twice as many exchanges to reach on an
// alternating pair, [MAX_NOTIFIES_PER_PAIR_HOUR] is spent twice per hour, and a
// halt binds only whichever side happened to send last.
//
// Two different ceilings share one record because §7.4 asks two different
// questions of the same pair. `notifiesAtMs` bounds how often a pair may
// INTERRUPT each other's turn — `post` is deliberately unbudgeted, because it
// waits for the target to look and costs nothing until then (§7.1, §7.4's third
// bullet). `exchangesSinceProgress` bounds how long a pair may talk with
// nothing to show for it, across every verb — a halted pair that could still
// `post` would just relabel every `notify` as a `post` and keep going, which is
// why {@link checkHalt} is a separate gate every send consults, not a branch
// inside {@link checkNotify}.
//
// A halt SURVIVES a bridge restart on purpose: §7.4 says "cleared only
// by a human", and an in-memory halt that a restart forgets is not that.
// `loadPairBudgets`/`savePairBudgets` are what make the survival real, so a
// producer that keeps a halted record only in memory has not implemented it.

import { z } from "zod";
import { MAX_NOTIFIES_PER_PAIR_HOUR, NO_PROGRESS_EXCHANGES } from "./constants";
import { refuse, type SessionBusRefusal } from "./errors";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

/** The rolling window [MAX_NOTIFIES_PER_PAIR_HOUR] is spent over. Not in
 *  `constants.ts`: every window constant there is shared by several stores (a
 *  TTL, a persist interval), and this one is read only here. */
const PAIR_NOTIFY_WINDOW_MS = 60 * 60_000;

/** Backstop on `notifiesAtMs`'s length. {@link noteNotify} trims to it on the
 *  way in and {@link loadPairBudgets} on the way out; the schema deliberately
 *  does NOT bound the array, because `readRecords` SKIPS a row that fails to
 *  parse — a length bound there would silently discard the durable halt riding
 *  in the same record. Sized well above anything a pair spending its hourly
 *  ceiling every hour for a day could accumulate. */
const NOTIFY_LOG_CAP = 96;

/** Pair-budget rows one session's own storage may hold at once — one per
 *  distinct peer it has exchanged with. Local rather than in `constants.ts`,
 *  same reasoning as [PAIR_NOTIFY_WINDOW_MS]; sized like `MAX_THREADS_PER_SESSION`
 *  since both count "peers this session currently correlates with". Past it the
 *  least recently touched pair is dropped by {@link upsertPairBudget} — losing a
 *  budget row costs that pair a relearned ceiling, never a bypassed halt, because
 *  a halt already tripped is durable exactly as long as its own row survives. */
const MAX_PAIR_BUDGETS_PER_SESSION = 64;

export const PairBudgetRecordSchema = z.object({
  /** The unordered pair this record is about — see {@link pairKey}. */
  pairKey: z.string().min(1).max(500),
  notifiesAtMs: z.array(z.number().int().nonnegative()),
  exchangesSinceProgress: z.number().int().nonnegative(),
  /** Set when {@link noteExchange} hits [NO_PROGRESS_EXCHANGES]. Never aged out
   *  by time alone — §7.4 makes "cleared only by a human" the whole
   *  point, so nothing in this module may clear it but {@link clearHalt}. */
  haltedAt: z.number().int().nonnegative().nullable(),
});
export type PairBudgetState = z.infer<typeof PairBudgetRecordSchema>;

/** One end of a pair, as bare identity — machine + session, never a project id:
 *  a bus address is matched on machine + session (`bridge/CLAUDE.md`), and the
 *  same two agents can legitimately hold different project ids for the same
 *  checkout. */
export interface PairEnd {
  machineId: string;
  sessionId: string;
}

/**
 * Order-independent: the same record whichever end calls it, because "the
 * pair" — not the direction of one send — is what §7.4 bounds. A reply from B
 * to A has to land on the SAME record A's earlier post to B opened, or the
 * no-progress halt these two counters exist to reach is unreachable — a pair
 * that only ever incremented its own outbound-half counter could ping-pong
 * forever, each side's own tally never reaching [NO_PROGRESS_EXCHANGES].
 */
export function pairKey(from: PairEnd, to: PairEnd): string {
  const a = `${from.machineId}/${from.sessionId}`;
  const b = `${to.machineId}/${to.sessionId}`;
  return a <= b ? `${a}|${b}` : `${b}|${a}`;
}

/**
 * The inverse of {@link pairKey}: who the two ends are, in key order.
 *
 * Exists so a halt lifted in one session can be lifted in the peer's mirror of
 * the same record too ({@link loadPairBudgets} scopes rows per session, so a
 * pair on one machine is TWO rows — see the module header). Splits each half at
 * its FIRST `/`, which is the assumption `pairKey` itself already makes by
 * joining on one; a key that does not carry exactly two halves is answered as
 * unreadable rather than guessed at.
 */
export function pairEnds(key: string): [PairEnd, PairEnd] | null {
  const halves = key.split("|");
  if (halves.length !== 2) return null;
  const ends = halves.map((half) => {
    const cut = half.indexOf("/");
    if (cut <= 0 || cut === half.length - 1) return null;
    return { machineId: half.slice(0, cut), sessionId: half.slice(cut + 1) };
  });
  if (ends[0] === null || ends[1] === null) return null;
  return [ends[0], ends[1]];
}

export function emptyPairBudget(key: string): PairBudgetState {
  return { pairKey: key, notifiesAtMs: [], exchangesSinceProgress: 0, haltedAt: null };
}

/**
 * A halt refuses every send on the pair, not only `notify`. §7.4: "A halt
 * refuses further sends"; §8.2 lists "send at all once the pair is
 * halted" among the things an addressable session cannot do. Gating only notify
 * would leave a halted pair looping on `post` forever — the one channel a
 * ceiling never reaches — and the halt would bound nothing. Nothing here
 * mutates.
 */
export function checkHalt(state: PairBudgetState): SessionBusRefusal | null {
  if (state.haltedAt === null) return null;
  return refuse(
    "NO_PROGRESS",
    `this pair has exchanged ${NO_PROGRESS_EXCHANGES} messages that published no artifact and opened no thread, so it is halted; a human working in either session clears it`,
  );
}

/**
 * The rolling-hour notify ceiling. NOTIFY ONLY — §7.4's third bullet
 * leaves `post` unbudgeted, so the refusal names it as the verb that still
 * reaches (§7.3's "refuse, and name the verb that reaches" pattern).
 * Reads `notifiesAtMs` live rather than trusting it pre-pruned, so a caller
 * holding state between loads still gets a correct answer; nothing here mutates.
 */
export function checkNotify(state: PairBudgetState, now: number): SessionBusRefusal | null {
  const recent = state.notifiesAtMs.filter((at) => now - at < PAIR_NOTIFY_WINDOW_MS);
  if (recent.length < MAX_NOTIFIES_PER_PAIR_HOUR) return null;
  return refuse(
    "NOTIFY_RATE",
    `${MAX_NOTIFIES_PER_PAIR_HOUR} notifies per hour on this pair; post instead — it is unbudgeted and still reaches`,
  );
}

/**
 * Record a notify that actually left. Trims to [NOTIFY_LOG_CAP] here rather
 * than leaving the array to a caller: the cap is what keeps a long-running
 * bridge from carrying an unbounded log between loads, and the entries it drops
 * are the oldest, which the rolling window had already stopped counting.
 */
export function noteNotify(state: PairBudgetState, now: number): PairBudgetState {
  const notifiesAtMs = [...state.notifiesAtMs, now].slice(-NOTIFY_LOG_CAP);
  return { ...state, notifiesAtMs };
}

/**
 * Any bus message in or out on this pair — post, notify or reply alike.
 * Increments the no-progress counter and trips the halt at
 * [NO_PROGRESS_EXCHANGES]. Returns the same object once the pair is already
 * halted, so a caller can skip the write.
 */
export function noteExchange(state: PairBudgetState, now: number): PairBudgetState {
  if (state.haltedAt !== null) return state;
  const exchangesSinceProgress = state.exchangesSinceProgress + 1;
  if (exchangesSinceProgress < NO_PROGRESS_EXCHANGES) {
    return { ...state, exchangesSinceProgress };
  }
  return { ...state, exchangesSinceProgress, haltedAt: now };
}

/**
 * An artifact published, or a NEW thread opened — §7.4's own definition
 * of progress ("bus exchanges that produce no artifact and no new thread trip a
 * halt") and NOTHING ELSE. Counting an ordinary reply as progress would make the
 * halt unreachable, which is a ceiling that reads as enforced and refuses
 * nothing. Resets the counter but deliberately NOT a halt already tripped; only
 * {@link clearHalt} does that.
 */
export function noteProgress(state: PairBudgetState): PairBudgetState {
  if (state.exchangesSinceProgress === 0) return state;
  return { ...state, exchangesSinceProgress: 0 };
}

/** Lift a halt. Only a human's action reaches this — see the module header. */
export function clearHalt(state: PairBudgetState): PairBudgetState {
  if (state.haltedAt === null) return state;
  return { ...state, exchangesSinceProgress: 0, haltedAt: null };
}

/** Clamp a record read back from a store an older build wrote unbounded. The
 *  window pass usually leaves nothing to do here; this is what makes the cap a
 *  property of every record in memory rather than only of the ones this build
 *  appended to. */
function trimNotifies(state: PairBudgetState): PairBudgetState {
  if (state.notifiesAtMs.length <= NOTIFY_LOG_CAP) return state;
  return { ...state, notifiesAtMs: state.notifiesAtMs.slice(-NOTIFY_LOG_CAP) };
}

/** Drop `notifiesAtMs` entries the rolling window has already forgotten. Same
 *  shape as `thread-store.ts`'s `expireThreads` / `mailbox.ts`'s
 *  `expireOldPosts`: run on the way out of the database so a pair idle for a
 *  week does not come back holding notify timestamps the ceiling no longer
 *  counts. Never touches `haltedAt` — a halt has no TTL of its own. */
export function expireNotifies(state: PairBudgetState, now: number): PairBudgetState {
  const notifiesAtMs = state.notifiesAtMs.filter((at) => now - at < PAIR_NOTIFY_WINDOW_MS);
  return notifiesAtMs.length === state.notifiesAtMs.length ? state : { ...state, notifiesAtMs };
}

/** The record for one peer, or a fresh one if this session has never exchanged
 *  with it. */
export function budgetFor(records: readonly PairBudgetState[], key: string): PairBudgetState {
  return records.find((r) => r.pairKey === key) ?? emptyPairBudget(key);
}

/** Record a pair, or advance the one already held. Moves the touched record to
 *  the end, so when [MAX_PAIR_BUDGETS_PER_SESSION] is exceeded the pair evicted
 *  is the one touched longest ago — there is no `lastAt` field on this record
 *  (unlike `thread-store.ts`'s rows) to evict by directly, so position stands
 *  in for it. */
export function upsertPairBudget(records: readonly PairBudgetState[], next: PairBudgetState): PairBudgetState[] {
  const kept = [...records.filter((r) => r.pairKey !== next.pairKey), next];
  return kept.length > MAX_PAIR_BUDGETS_PER_SESSION ? kept.slice(kept.length - MAX_PAIR_BUDGETS_PER_SESSION) : kept;
}

/** Expiry runs on the way OUT of the database, same reasoning as
 *  `loadThreads`/`loadMailbox`: a session reloaded after a long silence should
 *  not come back holding notify timestamps the window had already retired.
 *  `haltedAt` is read back verbatim regardless of age — see {@link expireNotifies}. */
export function loadPairBudgets(abDir: string, projectId: string, sessionId: string, now = Date.now()): PairBudgetState[] {
  const records = readBusDb(
    abDir,
    (db) =>
      readRecords(db, "bus_pair_budget", "budget", { projectId, sessionId }, MAX_PAIR_BUDGETS_PER_SESSION, PairBudgetRecordSchema),
    [] as PairBudgetState[],
  );
  return records.map((r) => trimNotifies(expireNotifies(r, now)));
}

export function savePairBudgets(abDir: string, projectId: string, sessionId: string, records: readonly PairBudgetState[]): void {
  withBusDb(
    abDir,
    (db) => replaceRecords(db, "bus_pair_budget", "budget", { projectId, sessionId }, records.slice(-MAX_PAIR_BUDGETS_PER_SESSION)),
    undefined,
  );
}
