import { appendFileSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolveAbDir } from "./antgrid-dir";
import { modelwatch, type ModelCallEvent } from "./modelwatch";

/**
 * Machine-level, unlike its sibling `handler-activity.jsonl`, which lives under
 * `agents/<projectId>/` and cannot be reached from here.
 *
 * `appendActivity` takes a projectId because a handler decision always has one:
 * the engine only ever runs inside an armed session on a known project. Two of
 * the three model calls this file records are those decisions; the third is
 * title generation, which holds a terminalId and no armed handler and therefore
 * has no projectId to write under at all. A call feed covering two of the three
 * kinds would be worse than none — the reader would draw conclusions about a
 * machine's model spend from a file that silently omits every naming spawn,
 * which is the one kind that fires on EVERY session — so the feed is filed where
 * all three can reach: beside `host.json`, one per machine.
 */
const MODEL_CALL_LOG_FILE = "model-calls.jsonl";
const MODEL_CALL_LOG_ROLLED_FILE = "model-calls.1.jsonl";

/**
 * Cap per generation, of which one live and one rolled are kept.
 *
 * Higher than `ACTIVITY_LOG_MAX_BYTES`'s 5 MB despite each line here being the
 * smaller of the two — an activity record carries a `reason` written in prose,
 * these carry counts and identifiers — precisely because of the paragraph above.
 * That cap buys a project 5 MB and a machine with eight projects forty; this one
 * file absorbs every project on the machine plus every title spawn, so the same
 * per-project window costs a bigger number here.
 *
 * The arithmetic behind 8 MB: a fully populated line runs to roughly 400 bytes,
 * and one call emits a start, an end and an outcome — a judge that retries emits
 * five or six — so call it 1.4 kB per call. 8 MB is then a bit under 6,000
 * calls. Against the plan's busy machine at a few hundred calls a day that is
 * one to two weeks in the live file alone, and because the rolled generation is
 * a FULL cap rather than a remainder, history never drops below that window even
 * in the instant after a roll. The ring, at its default capacity, holds under a
 * tenth of it and nothing across a restart, which is what this file is for.
 *
 * Exported so a test can build a file at exactly the cap rather than guess.
 */
export const MODEL_CALL_LOG_MAX_BYTES = 8_000_000;

/**
 * The ceiling past which the live log is compacted in place, having given up on
 * ever rolling it.
 *
 * `rotateIfLarge` tolerates a rename the OS refuses, and must — see its comment.
 * What that tolerance needs and `handler/config.ts` does not is a SECOND bound,
 * because the two files fail differently. That one is per project and written
 * once per handler decision, so a project whose rotation is wedged grows slowly
 * and only while that project is worked on. This one absorbs every project on
 * the machine plus every title spawn, three records per call, forever.
 *
 * And "forever" is the literal case, not the pessimistic one. Windows refuses
 * MoveFileEx-with-replace while anything holds the DESTINATION open without
 * FILE_SHARE_DELETE, so a `Get-Content -Wait` on the rolled generation — or an
 * editor, or an agent, left open on it — wedges rotation for as long as that
 * handle lives. Anything that leaves a directory or an undeletable file standing
 * at the rolled path wedges it permanently, and from then on the live log grows
 * at roughly 1.4 kB per model call for the life of the install. An observer must
 * never be the reason a user's disk fills.
 *
 * Twice the cap, so the compaction the ceiling triggers costs one read and one
 * write per cap-worth of appends rather than one per record, and so the ordinary
 * transient refusal — the handle that goes away a second later — is still
 * absorbed by the overshoot the cap already accepts and never reaches this path.
 *
 * Exported for the same reason the cap is: a test builds a file past it rather
 * than guessing where it sits.
 */
export const MODEL_CALL_LOG_HARD_MAX_BYTES = MODEL_CALL_LOG_MAX_BYTES * 2;

/** The live log for a given state dir. Read at write time, never cached: the
 *  `ANTGRID_DIR` override is honoured live by every other reader. */
export function modelCallLogPath(abDir: string = resolveAbDir()): string {
  return join(abDir, MODEL_CALL_LOG_FILE);
}

/** The single rolled generation. */
export function modelCallLogRolledPath(abDir: string = resolveAbDir()): string {
  return join(abDir, MODEL_CALL_LOG_ROLLED_FILE);
}

/**
 * One line of the durable feed: an ALLOW-LIST, and the whole point of this file.
 *
 * Every field is named here by hand. Nothing is spread from a `ModelCallEvent`
 * and nothing is deleted out of a copy of one, because the two differ entirely
 * in what happens to a field NOBODY HAS WRITTEN YET. Under a deny-list, a field
 * added to the event reaches the disk the moment it exists, and staying safe
 * depends on someone remembering to extend a list of exclusions in a file they
 * are not editing. Under this shape a new field is simply absent until a human
 * names it here.
 *
 * `usage` is the first exercise of that rule and STAYS unlisted now that the
 * vendor envelopes fill it in. Two reasons, and the first is structural: this
 * list is also the export allow-list `exportable` (cli/modelwatch.ts) reads, and
 * both index a `ModelCallEvent` BY KEY — so only a top-level event key can be
 * named here. `usage` is an object, and naming it whole is the nested-wholesale
 * admission this shape exists to refuse; a flattened `usageInputTokens` names no
 * key any event has and would silently write nothing at all. The second is that
 * the numbers are not comparable line to line: the four token counts mean a
 * different measurement per vendor (a cross-model sum for one, a per-step sum
 * that structurally undercounts by one call for another), and `money` arrives in
 * dollars, in nano AI credits, or not at all. They stay in the ring, where
 * `antgrid calls` renders each beside the tool that reported it.
 *
 * What the envelopes DO put on disk is the two fields a human had already named
 * for them: `actualModel` — which nothing else on the machine can answer, since
 * a vendor may bill a model the caller never asked for — and `apiMs`, the model
 * time that separates the API call from process startup.
 *
 * The excluded text fields, each with its reason:
 *
 *   `prompt` (all of it, `scaffold` and `goal` and `backlogChars` and the
 *     context digest included) and `stdout` — not because a sha256 or a
 *     character count leaks anything, but because these are the only fields on
 *     the event whose PRESENCE depends on a capture arm. Admitting even the
 *     harmless halves would make a durable record whose shape changes according
 *     to whether somebody armed capture minutes earlier, for reasons invisible
 *     in the file. The rule stays one line long and greppable instead: no
 *     arm-gated field is ever written to disk. `promptChars` and `stdoutChars`
 *     tell the size story anyway, and both are computed at the tap with no arm
 *     involved. It also settles what `Modelwatch.forgetCapturedText` cannot: a
 *     lapsing arm purges the ring, and has no reach into a file already fsynced.
 *
 *   `outcomeDetail` — the one that looks safe and is not. Two of its three
 *     producers are ours (`spawnErrorCode`, "no JSON object found in output"),
 *     but the third is `parsed.error.message` from a Zod safeParse of the
 *     judge's own JSON, and a Zod issue quotes what it received: an unexpected
 *     enum value or an unrecognised key puts the model's text into that string
 *     verbatim. The judge is asked to quote the transcript back character for
 *     character, so its text is the user's text one hop removed. It stays in the
 *     ring, where the arms and the eviction bound it.
 */
export interface ModelCallLogRecord {
  seq: number;
  at: number;
  callId: string;
  phase: string;
  purpose: string;
  attempt: number;
  requestedTool: string;
  actualTool: string;
  reach: string;
  requestedModel?: string;
  actualModel?: string;
  terminalId?: string;
  conversationId?: string;
  projectId?: string;
  wallMs?: number;
  apiMs?: number;
  exitCode?: number | null;
  timedOut?: boolean;
  budgetMs?: number;
  remainingMs?: number;
  outcome?: string;
  promptChars?: number;
  stdoutChars?: number;
}

/** Exported for the test that asserts a written line carries these keys and no
 *  others, so a field added to `ModelCallEvent` and forgotten here is caught by
 *  the suite rather than by whoever reads the file afterwards. */
export const MODEL_CALL_LOG_FIELDS: readonly (keyof ModelCallLogRecord)[] = [
  "seq", "at", "callId", "phase", "purpose", "attempt",
  "requestedTool", "actualTool", "reach", "requestedModel", "actualModel",
  "terminalId", "conversationId", "projectId",
  "wallMs", "apiMs", "exitCode", "timedOut", "budgetMs", "remainingMs",
  "outcome", "promptChars", "stdoutChars",
];

function metadataOf(e: ModelCallEvent): ModelCallLogRecord {
  return {
    seq: e.seq,
    at: e.at,
    callId: e.callId,
    phase: e.phase,
    purpose: e.purpose,
    attempt: e.attempt,
    requestedTool: e.requestedTool,
    actualTool: e.actualTool,
    reach: e.reach,
    requestedModel: e.requestedModel,
    actualModel: e.actualModel,
    terminalId: e.terminalId,
    conversationId: e.conversationId,
    projectId: e.projectId,
    wallMs: e.wallMs,
    apiMs: e.apiMs,
    exitCode: e.exitCode,
    timedOut: e.timedOut,
    budgetMs: e.budgetMs,
    remainingMs: e.remainingMs,
    outcome: e.outcome,
    promptChars: e.promptChars,
    stdoutChars: e.stdoutChars,
  };
}

/**
 * Bound by RENAME, never by rewriting a trailing window in place — the same
 * discipline as `rotateIfLarge` in `handler/config.ts`, and for the same three
 * reasons, which are worth restating because this file is written more often
 * than that one.
 *
 * "Keep the last N records" would turn an O(1) append into a read of the whole
 * file on every event, and this runs three times per model call rather than once
 * per decision.
 *
 * One rolled generation is kept rather than dropped, because the questions this
 * file exists to answer are retrospective — which model actually ran, how a
 * shared retry budget was spent, what a borrow cost — and every one of them is
 * asked about a call that already happened.
 *
 * A failed rotation is a SKIPPED rotation, retried by the next record, never an
 * error. Windows refuses a rename while anything holds the destination open, and
 * an observer that turned a held file handle into a failed model call would be
 * exactly the thing this feature must not be. The file overshooting its cap for
 * a few records is the cheaper half of that trade.
 *
 * The half that tolerance is missing is a floor under it, which is what
 * `MODEL_CALL_LOG_HARD_MAX_BYTES` is: a refusal that never lifts must not mean a
 * file that never stops growing. Past that ceiling the rolled generation is
 * written off and the live file is compacted onto its own tail — which is the
 * whole-file rewrite the paragraph above rejects, and is affordable only here,
 * where it runs once per cap-worth of appends instead of once per record. What
 * survives is a full cap of the MOST RECENT records, because this file's
 * questions are retrospective and the answer is always nearer the end.
 */
function rotateIfLarge(abDir: string): void {
  const path = modelCallLogPath(abDir);
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    return; // No log yet. The append that follows creates it.
  }
  if (size < MODEL_CALL_LOG_MAX_BYTES) return;
  try {
    renameSync(path, modelCallLogRolledPath(abDir));
    return;
  } catch {
    // A rename the OS refused, retried by the next record; not worth a log line
    // of its own from inside an observer.
  }
  if (size < MODEL_CALL_LOG_HARD_MAX_BYTES) return;
  try {
    compactOntoTail(path);
  } catch {
    // Rotation refused AND compaction refused — the file is held against every
    // way this module has of shrinking it, and there is nothing further an
    // observer is entitled to do about it. The append still goes ahead.
  }
}

/**
 * Rewrite `path` as its last `MODEL_CALL_LOG_MAX_BYTES`, cut at a record
 * boundary so the result is still JSONL.
 *
 * Cut on the BUFFER rather than on a decoded string: a fixed byte offset into
 * UTF-8 lands mid-sequence often enough, and a replacement character spliced
 * into the middle of a JSON string would leave a line that no longer parses,
 * inside the one operation whose entire job is to leave the file readable.
 * Slicing after the first newline in the window is what makes the boundary
 * exact — the partial record at the head of it is dropped, never repaired.
 */
function compactOntoTail(path: string): void {
  const buf = readFileSync(path);
  const tail = buf.subarray(Math.max(0, buf.length - MODEL_CALL_LOG_MAX_BYTES));
  const firstNewline = tail.indexOf(0x0a);
  // No newline in a whole cap of bytes means one record has grown past the cap
  // on its own, so there is no boundary to keep and nothing worth keeping.
  writeFileSync(path, firstNewline === -1 ? Buffer.alloc(0) : tail.subarray(firstNewline + 1));
}

/**
 * Synchronous, matching `appendActivity` — a `statSync` and an `appendFileSync`
 * per event, three events per call, measured against a call that spawns a
 * process and waits seconds for a model to answer. The same comparison
 * `modelwatch.ts` uses to justify the ring's cost applies here with several
 * orders of magnitude more room.
 *
 * So do not "fix" this into an async queue. A queue would buy nothing against
 * that baseline and would cost the property the file's readers depend on: lines
 * appear in the order the calls happened, with no window in which a record is
 * owed to a file the process is about to exit without writing.
 *
 * This deliberately does NOT catch. It is only ever reached as a subscriber, and
 * `Modelwatch.push` already swallows a subscriber's throw under "A watcher is an
 * observer" — see `subscribeModelCallLog`.
 */
function appendModelCall(event: ModelCallEvent, abDir: string): void {
  const path = modelCallLogPath(abDir);
  mkdirSync(abDir, { recursive: true });
  rotateIfLarge(abDir);
  appendFileSync(path, `${JSON.stringify(metadataOf(event))}\n`, "utf8");
}

/**
 * On by default, with `ANTGRID_MODELWATCH_LOG=0` as the one kill switch.
 *
 * The reasoning is the ring's own: a call worth reading about — the judge that
 * timed out, the title that named itself after "Invalid API key · Please run
 * /login" — has already happened by the time anyone thinks to ask, so a log that
 * starts filling when someone asks for it is empty exactly when it matters. What
 * makes always-on acceptable is not that anyone opted in; it is that the record
 * is bounded by the cap above and holds metadata only, by the allow-list above
 * that. Take either of those away and the default would have to change with it.
 *
 * Read per event rather than once at import, so the switch takes effect on a
 * running host the way the remote-access switch does, and so the value a test
 * sets is the value that applies.
 */
function logEnabled(): boolean {
  return process.env.ANTGRID_MODELWATCH_LOG !== "0";
}

/**
 * A `bun test` process that has not said where its state dir is writes nothing.
 *
 * The writer attaches at import of `agents/headless.ts` — the chokepoint every
 * model call passes through, and therefore a module that a spec file touching a
 * session, a judge or a title pulls in transitively without ever naming
 * modelwatch. Without this, running ONE of them appends fabricated records to
 * the developer's real `~/.antgrid/model-calls.jsonl`, beside `host.json`:
 * `bun test tests/handler/judge.test.ts` alone wrote seventy, `wallMs: 0`
 * scripted spawns and all.
 *
 * That is worse than an untidy state dir. This file exists to be the
 * authoritative answer to "which model actually ran, and what did the retry
 * get", and a synthetic record is indistinguishable from a real one on the line
 * — so the artifact the feature is for is the thing being corrupted, and it is
 * never cleaned up.
 *
 * Detaching in one spec file's `afterEach` cannot close it. That protects only
 * the files that run AFTER it, Bun does not run spec files in the order they
 * were passed, and the per-file command every brief documents removes the
 * masking file from the run entirely. Nor can "every future spec file remembers
 * an env var", because the failure is silent in both directions: nothing fails,
 * and the writes land somewhere nobody is looking.
 *
 * So the refusal lives at the writer, keyed on the `NODE_ENV=test` that `bun
 * test` sets for itself, and pinning `ANTGRID_DIR` is what lifts it — which is
 * not an escape hatch but the same act that gives such a test somewhere of its
 * own to write. Read per event for the same reason `logEnabled` is: the value a
 * test sets is the value that applies.
 */
function unpinnedTestProcess(): boolean {
  return process.env.NODE_ENV === "test" && process.env.ANTGRID_DIR === undefined;
}

let detach: (() => void) | null = null;

/**
 * Register the writer as a SUBSCRIBER to the ring rather than as a second tap on
 * the call sites.
 *
 * Not a stylistic choice. `Modelwatch.push` already runs every subscriber inside
 * a try whose comment reads "A watcher is an observer. It must never be able to
 * fail a model call", so subscribing puts a disk write — the one part of this
 * feature that can fail for reasons entirely outside the process, a full volume,
 * a file another process holds, a rename Windows refuses — inside a guard that
 * already exists and is already tested, instead of adding a second one that has
 * to be got right in a file nobody reads again.
 *
 * It also means the file records exactly what the ring records. A second tap
 * would carry its own field list, and the two would drift the first time someone
 * added a field to one of them.
 *
 * Idempotent: the module self-registers at import, and every entry point that
 * can reach a model call reaches this module through the spawn path.
 */
export function subscribeModelCallLog(): void {
  if (detach) return;
  detach = modelwatch.subscribe((event) => {
    if (!logEnabled() || unpinnedTestProcess()) return;
    appendModelCall(event, resolveAbDir());
  });
}

/** Test seam. `__resetModelwatchForTest` clears the ring's subscriber set
 *  wholesale, which leaves this module believing it is still registered — so a
 *  spec file that resets the ring must re-register through here, in `beforeEach`
 *  and `afterEach` both, or its own writes go nowhere and the next file's do. */
export function __resubscribeModelCallLogForTest(): void {
  detach?.();
  detach = null;
  subscribeModelCallLog();
}

/** Test seam: leave the ring with no writer attached. */
export function __unsubscribeModelCallLogForTest(): void {
  detach?.();
  detach = null;
}

subscribeModelCallLog();
