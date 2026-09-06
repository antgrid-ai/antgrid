// bridge/src/handler/engine.ts
import { createHash } from "node:crypto";
import {
  createMessage,
  type AbMessage,
  type HandlerEntitlement,
  type HandlerPersonality,
} from "../protocol";
import { classifyDestructive, describeWarning, type FloorWarning } from "./destructive-floor";
import {
  authorizeInstruction, createAuthorization, partitionWarnings,
  type GrantSummary, type InstructionAuthorization, type LiftedTier,
} from "./authorization";
import {
  clearSessionTrash, describeSnapshot, planSnapshots, releaseSnapshots, takeSnapshots, undoSnapshot,
  NO_SNAPSHOT_PATTERNS, SNAPSHOT_PATTERNS,
  type SnapshotEntry, type SnapshotOutcome, type UndoResult,
} from "./snapshot";
import { loadSnapshots, pruneSnapshots, saveSnapshots, type StoredSnapshot } from "./snapshot-store";
import { buildWrapUp, wrapUpDetail, wrapUpPushBody, type WrapUpRecord } from "./wrap-up";
import { loadWrapUps, pruneWrapUps, saveWrapUps } from "./wrap-up-store";
import { RunawayGuard } from "./runaway-guard";
import { assembleContext } from "./context";
import { runDecision as defaultRunDecision, runExtraction as defaultRunExtraction } from "./judge";
import {
  MAX_ITEM_CHARS, amendableItems,
  type Amendment, type ExtractedItem, type ExtractionResult,
} from "./extract";
import { appendActivity, type ActivityRecord } from "./config";
import {
  loadHandlerSession, saveHandlerSession, EscalationChoiceSchema, OpenEscalationSchema,
  type EscalationChoice, type EscalationKind, type HandlerSessionRecord, type OpenEscalation,
} from "./session-store";
import {
  allTerminal, applyTransitions, clip, isTerminalStatus, previewForUser, propagateBlocked, renderBacklog,
  type InstructionItem, type ItemStatus, type RejectionCode,
} from "./backlog";
import { checkReplyShape, findCommand, oneLine, replyShape } from "./reply-shape";
import type { CapCommand } from "../structured/chat-session";
import type { SessionAdapter } from "./session-adapter";
import { handlerObservable, judgeCapable } from "../agents/registry";
import { createEntitlementReader, type EntitlementReader } from "../entitlement";
import { type DecisionAsk, type HandlerDecision, DEFAULT_PERSONALITY } from "./decision";
import {
  LIMIT_FALLBACK_MS, LIMIT_PARK_CEILING, MIN_PARK_MS, TRANSIENT_CEILING, transientBackoffMs,
  defaultSchedule, TimerRegistry, type LifecycleDeps,
} from "./lifecycle";
import { isSubmitKeystroke } from "../keystrokes";
import { logger } from "../logger";

const log = logger.child({ component: "handler-engine" });

/**
 * One escalation as it leaves the engine. A COPY, never the record itself:
 * `handler:status` is a bus REPLAY_TYPE, so the frame is retained by reference until
 * the next one, and `escalate()` pushes onto the live array in place.
 */
function escalationWire(e: OpenEscalation): OpenEscalation {
  return { ...e };
}

export interface HandlerEvent {
  terminalId: string;
  event: "turn_end" | "awaiting_input" | "permission_request" | "question"
       | "limit_hit" | "limit_cleared" | "turn_failed";
  transcriptPath?: string;
  sessionId?: string;
  // Human-readable subject of a blocking prompt (permission title / question
  // text) — carried into the escalation body so the notification says WHAT
  // the agent is asking, not just that it asked.
  detail?: string;
  // The driver's own id for a blocking prompt (permissionId / questionId). The
  // resolve RPC names the same id, which is what lets a resolve retire the one
  // escalation it answered while a second prompt on the same terminal — drivers
  // hold a MAP of pending ones — keeps its row.
  promptId?: string;
  // When the provider's limit window ends (epoch ms). Detectors capture it from
  // a side channel; absent means fall back to a fixed wait.
  resetsAt?: number;
  // The driver's own name for the failure, used as the activity reason.
  errorClass?: string;
  // limit_hit only: the driver retries by itself, so a nudge would be noise.
  selfResuming?: boolean;
}

// The two events a structured driver raises by BLOCKING on the user: the agent
// cannot proceed until the prompt is resolved or retracted. Everything else is
// a pause the judge may handle on its own.
function isBlockingPrompt(evt: HandlerEvent | undefined): boolean {
  return evt?.event === "permission_request" || evt?.event === "question";
}

// Session-lifecycle signals (the provider stopped serving us), as opposed to
// the agent pausing for input. They report a fact rather than requesting a
// decision, so they never reach the judge.
function isLifecycle(evt: HandlerEvent): boolean {
  return evt.event === "limit_hit" || evt.event === "limit_cleared" || evt.event === "turn_failed";
}

/**
 * How much of the Handler a slot can actually get. "unsupported" and "armed but
 * quiet" are different facts, and nothing else separates them: an unobservable
 * terminal session arms cleanly today and then never fires, which reads to the
 * user as a broken feature rather than an absent one.
 */
export type HandlerObservability = "full" | "escalate_only" | "unsupported";

// One tap arms with no payload at all, so an activity row can legitimately be
// written before anything has stated what the session is for.
const NO_GOAL = "(no goal set)";

// A ceiling on the WHOLE stack, where extract.ts's MAX_ITEMS bounds only one
// response: renderBacklog(backlog) is interpolated into every subsequent decide
// prompt, so repeated instructs would starve the supervisor's context budget —
// and that shows up as worse decisions, nowhere near this file.
const MAX_BACKLOG_ITEMS = 100;

// How many `guard_blocked` reports may stand at once. A judge that keeps
// proposing a refused action raises one row per distinct (reason, draft), and
// nothing but the user retires them — so past this the OLDEST is dropped.
// Dropping the newest would hide the situation the session is actually in, and
// every report is preserved verbatim in the activity feed either way: the row is
// only the reminder that one is there.
const MAX_BLOCKED_REPORTS = 5;

// One unanswered question per terminal, and not a queue depth. The answer
// transports name the escalation they answer, so a second standing ask would no
// longer make the user's own answer ambiguous — that reason is spent. What the
// bound still buys is the notification volume a session that is supposed to be
// getting on with the work may spend, and keeping a stranded ask from becoming a
// stranded queue: an ask is retired by the user, by a dismiss, or by
// reconcileAsks finding its claim expired, and none of those scales with depth.
const MAX_OPEN_ASKS = 1;
// How much of a question and its reasoning the row may carry. The row replays on
// every handler:status frame, so it is bounded the way every other replayed
// string is.
const MAX_ASK_CHARS = 400;
// How many refused asks ride along in the next decide prompt, on the same
// bargain as MAX_REMEMBERED_REJECTIONS: enough that a judge learns why its
// question vanished, short enough that it never becomes the prompt.
const MAX_ASK_REJECTIONS = 2;
// The tap options' bounds, kept in lockstep with OpenEscalationSchema's copy and
// enforced by mintAskOptions rather than by a safeParse over the finished array:
// a parse rejects EVERY option at once, so one over-long label would cost the
// user a card the judge sized for four.
const MAX_ASK_OPTION_LABEL = 80;
const MAX_ASK_OPTION_COST = 160;
// The same lockstep for `unblocked`, and this one is the sharp end. A row that
// fails its own schema makes the WHOLE session record unreadable on the next
// start — loadHandlerSession returns null and arm() rebuilds an empty session —
// and a backlog id is `item-<projectId>-<ms>-<n>`, so a long projectId is enough
// to breach it. A dropped id costs one line of the still-working list, which
// reconcileAsks re-derives from the backlog anyway.
const MAX_UNBLOCKED_ID_CHARS = 64;

// How much of those reports the wrap-up push may name. The note shares one OS
// notification with `wrapUpSummary` and `undoNote`, and OS surfaces truncate;
// standing reports are bounded by MAX_BLOCKED_REPORTS, so the cap plus a `+N more`
// tail is what keeps the whole push readable when all five stand.

// What a `guard_blocked` row asks, and — through push/compose.ts — the body of
// its notification. Engine-authored rather than taken from `notify.body`: a judge
// that filled the notify block while deciding `handle` described the pause it was
// answering, not the reply a guard then refused.
const BLOCKED_QUESTION = "Handler did not send its reply";

// How many past floor warnings ride along in the next decide prompt. Enough to
// show a pattern the Assistant keeps repeating, short enough that a long session
// does not spend its context budget re-reading its own history.
const MAX_REMEMBERED_WARNINGS = 5;

// The same trade for refused transitions, set lower: a refusal names one item and
// says how to cite it, so the lesson is carried by the most recent few. A longer
// list mostly repeats itself, and every line of it is context the judge spends
// not reading the agent.
const MAX_REMEMBERED_REJECTIONS = 3;

// How many times one item may be refused for its command anchor ALONE before the
// anchor is dropped for it. The anchor reads the item's own text for a slash
// command, and a token-shaped route or path in the user's wording ("fix the
// /login redirect") names a command nothing will ever run — so its demand is not
// merely unmet, it is unmeetable, and a permanent refusal costs the session its
// wrap-up and eventually a runaway report the user has to dismiss by hand.
// Grounding is untouched by the waiver: what is dropped is the demand for a
// token, never the demand for a real quote. Three, so a judge that could satisfy
// the anchor is asked for it twice more after the first miss — the refusal is fed
// back into the prompt each time — before the harness concludes it cannot be met.
const MAX_ANCHOR_REFUSALS = 3;

// How many literals ride along in the detail of a feed row whose reason is a
// count, and how much of the line they may spend. The reason carries the true
// totals, so the list never has to stand in for the count — it is the sample that
// makes the totals concrete, and a feed row is read at a glance either way.
const MAX_ROW_SAMPLE_ENTRIES = 8;
const MAX_ROW_SAMPLE_CHARS = 200;

// The item outcomes the activity feed carries a kind for. A skip is as
// consequential as a completion, so they stay distinguishable without parsing
// the reason text.
const ITEM_DECISION: Partial<Record<ItemStatus, ActivityRecord["decision"]>> = {
  done: "item_done",
  blocked: "item_blocked",
  skipped: "item_skipped",
  failed: "item_failed",
};

// Identity of the evidence a decide pass reasoned over (see lastJudgedContextHash).
// Deliberately NOT RunawayGuard's 32-bit djb2: a collision there false-escalates,
// which is the safe direction, but a collision HERE skips a real pause and no
// further event raises it again. Over a 12k-char context that margin has to be
// cryptographic, and the cost is one hash per judge call.
function contextHash(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

// `??` is the wrong operator against a judge decision: `notify.body`/`notify.draftReply`
// are `z.string()`, not optional, so a judge answering `handle` fills the whole notify
// block with EMPTY strings rather than omitting it. A nullish fallback then never fires
// and the escalation reaches the app with no question and no draft — a card the user
// can read but cannot act on.
function firstFilled(...values: (string | undefined)[]): string | undefined {
  return values.find((v) => v !== undefined && v.trim() !== "");
}

// A stored snapshot as the app sees it. `state` is derived rather than stored:
// "undone" is the only spent state, and a failed attempt leaves the entry
// retryable, so the two can never disagree with what an undo would actually do.
function snapshotWire(st: StoredSnapshot) {
  return {
    snapshotId: st.entry.id,
    terminalId: st.terminalId,
    at: st.entry.at,
    action: st.action,
    trigger: st.entry.trigger,
    summary: describeSnapshot(st.entry),
    state: st.undoneAt !== undefined ? "undone" as const : st.failure ? "failed" as const : "available" as const,
    ...(st.failure ? { detail: st.failure } : {}),
  };
}

// A stored wrap-up as the app sees it. Named field by field rather than spread:
// the record is a disk format, so publishing a field it gains has to be a
// decision rather than a side effect of storing it.
function wrapUpWire(rec: WrapUpRecord) {
  return {
    wrapUpId: rec.wrapUpId,
    terminalId: rec.terminalId,
    at: rec.at,
    goal: rec.goal,
    outcomes: rec.outcomes.map((o) => ({ status: o.status, total: o.total, items: [...o.items] })),
    blockedTotal: rec.blockedTotal,
    blockedReasons: [...rec.blockedReasons],
  };
}

type Noun = readonly [one: string, many: string];

function countPhrase(n: number, [one, many]: Noun): string {
  return `${n} ${n === 1 ? one : many}`;
}

// What a lift is counted in. Three nouns rather than one, because the tiers are
// three unlike permissions and the count is the half that survives a clip: a
// sentence that lifted the secret-access advisory for the rest of the
// session must not be reported as having allowed a command.
const GRANT_NOUNS: Record<LiftedTier, Noun> = {
  DESTRUCTIVE: ["destructive command", "destructive commands"],
  EGRESS: ["network command", "network commands"],
  SECRETS: ["secret read", "secret reads"],
};
const GRANT_TIERS: LiftedTier[] = ["DESTRUCTIVE", "EGRESS", "SECRETS"];

/**
 * What one instruction's authorization lift added, as the two halves of a feed
 * row: the totals, and a sample of the literals themselves.
 *
 * Null when it added nothing. Most instructions grant nothing at all, and a row
 * saying so every time is exactly the noise that teaches a user to skim past the
 * one row that matters.
 *
 * A single lift is the reason and carries no detail: "1 destructive command"
 * over `rm -rf` spends the row's loudest slot on a count the line below it
 * already implies, and buries the one thing the user came to check — the inverse
 * of how the `floor_warning` row about that same command reads.
 */
function describeGrant(g: GrantSummary): { reason: string; detail?: string } | null {
  const groups: { noun: Noun; entries: string[] }[] = [];
  for (const tier of GRANT_TIERS) {
    const matched = g.operations.filter((o) => o.tier === tier).map((o) => o.matched);
    if (matched.length > 0) groups.push({ noun: GRANT_NOUNS[tier], entries: matched });
  }
  if (g.paths.length > 0) groups.push({ noun: ["path", "paths"], entries: g.paths });
  // `destinations`, never `hosts`: the harvest reads any dotted token as a host so
  // that granting and checking agree with each other, and repeating that superset
  // back would call every source file the user named a network permission.
  if (g.destinations.length > 0) {
    groups.push({ noun: ["host", "hosts"], entries: g.destinations });
  }
  const entries = groups.flatMap((x) => x.entries);
  if (entries.length === 0) return null;
  if (entries.length === 1) return { reason: entries[0]! };
  return {
    reason: joinPhrases(groups.map((x) => countPhrase(x.entries.length, x.noun))),
    detail: rowSample(entries),
  };
}

function joinPhrases(parts: string[]): string {
  return parts.length <= 1
    ? parts.join("")
    : `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}`;
}

/** The capped list under a feed row whose title is a count.
 *
 *  The first entry always rides, however long: a row whose list is empty while
 *  its count says "2 commands" reads as a bug in the row. And a sample that
 *  stopped short says so where it stopped — the grant row's drawer echo shows
 *  this half with no title over it. */
function rowSample(entries: string[]): string {
  const shown: string[] = [];
  let budget = MAX_ROW_SAMPLE_CHARS;
  for (const e of entries.slice(0, MAX_ROW_SAMPLE_ENTRIES)) {
    if (shown.length > 0 && e.length > budget) break;
    shown.push(e);
    budget -= e.length + 3;
  }
  const more = entries.length > shown.length ? ` +${entries.length - shown.length} more` : "";
  return `${shown.join(" · ")}${more}`;
}

// The item text quoted back in an amendment row. Long enough to recognise a line
// the user wrote, short enough that two of them still read at a glance.
const MAX_AMENDMENT_QUOTE_CHARS = 60;

// What a change to the list is counted in. Three nouns rather than one, for the
// reason GRANT_NOUNS has three: a removal and a reword are unlike changes, and
// "2 items changed" over two quotes leaves the user unable to tell which of those
// lines are gone — which, once a line is off the backlog, this row is the only
// place left to ask.
type AmendmentKind = "removed" | "reworded" | "recondition";
const AMENDMENT_NOUNS: Record<AmendmentKind, Noun> = {
  removed: ["item removed", "items removed"],
  reworded: ["item reworded", "items reworded"],
  recondition: ["condition changed", "conditions changed"],
};
const AMENDMENT_KINDS: AmendmentKind[] = ["removed", "reworded", "recondition"];

interface AmendmentChange {
  /** What the row counts this as beside the others. An item whose wording AND
   *  condition both moved counts once, as a reword: counting it twice would read
   *  as two items on a row whose whole job is saying how many lines moved. */
  kind: AmendmentKind;
  /** How the row names it when it is the only change. */
  verb: string;
  /** The item as the user last saw it. */
  text: string;
  /** What it says now, where the change left something to show. */
  now?: string;
}

/**
 * What one instruction changed about the list the user was already keeping, as
 * the two halves of a feed row.
 *
 * The item is quoted as the user last saw it — the question this row answers is
 * which of their lines moved, and the old wording is the only version they can
 * recognise. What it says NOW rides in the detail for a single change, because
 * the replacement text is the extractor's rather than the user's and the drawer
 * is the only other surface carrying it — which is no help to the reader this
 * feed is for, who was away and is reading it afterwards.
 */
function describeAmendments(changes: AmendmentChange[]): { reason: string; detail?: string } {
  const first = changes[0];
  if (changes.length === 1 && first) {
    return {
      reason: `${first.verb} "${clipQuote(first.text)}"`,
      // The arrow is composed here rather than by the app: this kind carries two
      // detail shapes, and only the bridge knows which one it just sent.
      ...(first.now ? { detail: `→ ${first.now}` } : {}),
    };
  }
  const parts = AMENDMENT_KINDS.flatMap((kind) => {
    const n = changes.filter((c) => c.kind === kind).length;
    return n > 0 ? [countPhrase(n, AMENDMENT_NOUNS[kind])] : [];
  });
  return {
    reason: joinPhrases(parts),
    detail: rowSample(changes.map((c) => `"${clipQuote(c.text)}"`)),
  };
}

// Flattened AND escaped: an amendment quotes the user's own backlog text back at
// them in a feed row, so a control character smuggled into an item must not reach
// the row raw. previewForUser is the one escaping rule; this only picks a tighter
// cap, since several quotes share one row.
function clipQuote(text: string): string {
  return previewForUser(oneLine(text), MAX_AMENDMENT_QUOTE_CHARS);
}

// `clip` appends its ellipsis PAST the cap it is given, so clip(s, 80) can be 81
// characters long. That is harmless where the cap is a reading budget, and fatal
// where it is a wire bound the result is then validated against — one character
// over and the whole array is refused. Clip to one short of the bound so the
// ellipsis lands inside it, and leave a string already within the bound alone.
function clipWithin(text: string, max: number): string {
  return text.length <= max ? text : clip(text, max - 1);
}

function wakeClock(at: number): string {
  const d = new Date(at);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// The "don't do it" half of a quick-choice card. Engine-authored and constant, not
// judge output: reject has to mean the same thing on every card, and it is the one
// choice whose text a user is least likely to read before tapping.
const REJECT_CHOICE_TEXT = "Do not proceed. Wait for my instructions.";

/**
 * The quick-choice card for an escalation the engine has already built.
 *
 * Minted here rather than asked of the judge: the judge could propose a richer set,
 * but its labels are Assistant output reaching a one-tap control, and nothing
 * about authorization may derive from Assistant output (authorization.ts). The
 * one thing the judge does contribute is the draft it already composed, which the
 * [Approve] choice sends VERBATIM — so the app must render `text`, not only `label`.
 *
 * A tap carries NO authorization lift. It answers through the ordinary reply
 * transport (terminal:input / agent:prompt), never through handler:instruct:
 * - `instruct` is the single feed point for authorization and it also queues an
 *   extraction, so a tap would mint a backlog item no terminal status can ever
 *   resolve and the session could never wrap up.
 * - A lift minted by tapping a label the judge wrote is the laundering path that
 *   instruction-scoped authorization closes: a compromised agent composes an
 *   escalation whose [Approve] chip silences every later advisory row.
 * The costs are not symmetric — under-lifting costs one advisory activity row per
 * repeat (post-Phase-5 the advisory floor records rather than escalates), while
 * over-lifting costs a session-wide grant the user never read. The real lift stays
 * one control away, in the user's own words, through the PA bar.
 *
 * WHY AN `ask` OPTION IS OUTSIDE ALL OF THE ABOVE, mechanically rather than by
 * assertion. An `ask` (see raiseAsk) carries `askOptions`, a DIFFERENT field on a
 * different code path; it never carries `choices` and never calls this function.
 * Nothing here is loosened for it, and nothing here may be loosened for it later.
 *
 * 1. `authorizeInstruction` (authorization.ts) is the only writer of `s.auth`,
 *    and it has exactly ONE call site in bridge/src: HandlerEngine.instruct.
 *    An ask TAP arrives as `handler:answer` and reaches answerAsk, which calls
 *    neither instruct nor authorizeInstruction nor queueExtraction nor
 *    injectReply nor guard.reset. `s.auth.patterns`, `s.auth.paths` and
 *    `s.auth.hosts` are therefore byte-identical across a tap. That is pinned as
 *    a test (engine.test.ts, "a tap grants nothing"), not left as prose here.
 *
 * 2. The label the judge writes IS the entire payload of a tap. An askOption has
 *    no `text`: the app sends `choiceId` alone, the bridge resolves it against
 *    its OWN persisted row, and what is parked for the judge is the engine-
 *    clipped label — the exact string the user read on the button. A label that
 *    misrepresents what a tap sends is unspellable, because the label is what a
 *    tap sends. This is why askOptions is a separate field rather than a second
 *    producer into `choices`, where `text` and `label` can diverge and where
 *    every existing consumer would type `text` into a PTY.
 *
 * 3. What a tap actually moves is text the agent could already put in front of
 *    the judge. assembleContext feeds the transcript into ctx.text on every
 *    pass, so a compromised agent can already steer the judge's prompt. A tap
 *    moves agent-influenced text from one prompt section to another and moves
 *    nothing into s.auth. No privilege is gained. What IS new is that the user's
 *    tap ENDORSES one option — and an endorsement buys no floor exemption
 *    anywhere: the judge's relay is an ordinary `handle`, screened by
 *    checkReplyShape, the HARD floor (which nothing lifts), partitionWarnings
 *    against an untouched s.auth, guard.check and the snapshot pass, exactly as
 *    every other handle is.
 *
 * 4. Free text on an ask is the one path that DOES lift, and it lifts the same
 *    way it always has: through this same single feed point, on the raw payload,
 *    before extraction (see instruct). The lift stays in what the user typed.
 *    Two things keep that true rather than aspirational — an ask row is minted
 *    with `draftReply: ""` and the judge's `ask` object has no draftReply field
 *    at all, so there is no judge-authored artifact for a composer to prefill;
 *    and the ask sheet is its own widget with no prefill parameter, rather than
 *    a branch inside the sheet that mints the lift.
 *
 * 5. The honest residue, stated so nobody mistakes it for a hole that was
 *    missed. The judge writes the question rendered above that composer, so it
 *    can ELICIT a string the user then types in their own words. That is a
 *    human keystroke in the middle, not a lift derived from Assistant output, so
 *    the invariant above is intact — but it raises the rate at which short,
 *    late-night answers enter the funnel. Which is why the ask-answer branch of
 *    instruct records an `instruction_authorized` row whenever ANYTHING was
 *    granted, including the bare hosts describeGrant deliberately omits from its
 *    ordinary feed row: at most one row per answered question, and the silent
 *    session-long egress grant becomes visible exactly where this feature made
 *    it more likely.
 *
 * NOTHING THIS FUNCTION COVERS CHANGED. quickChoicesFor is not edited by the ask
 * feature. `choices` keeps its exact semantics and its exact transport
 * (answerWithChoice -> reply -> terminal:input / agent:prompt). The [Approve]
 * chip still answers that way and still takes no lift. If a future change ever
 * routes askOptions through `choices`, or gives an askOption a `text`, or gives
 * an ask tap a path into instruct, every numbered clause above stops holding at
 * once and this comment is the record of what was being relied on.
 */
export function quickChoicesFor(p: {
  kind?: EscalationKind;
  floorRule?: string;
  draftReply: string;
  projectPath: string;
  open?: readonly OpenEscalation[];
}): EscalationChoice[] | undefined {
  // An option-based agent prompt is answered by the chat resolve RPC alone, and a
  // chip's only transport is injected text (terminal:input / agent:prompt), which
  // such a prompt cannot consume — which is what `kind` exists to say. So any chip
  // offered here would be a button that does nothing at all.
  if (p.kind === "resolve_in_session") return undefined;
  // A report exists BECAUSE a guard refused this exact text, so a one-tap that
  // re-sent it would be the thinnest human in the loop there is. The reply sheet
  // costs the same send and makes the user read what was refused first. The HARD
  // case already falls out through `floorRule`; this covers the shape and runaway
  // rejections, which set no rule.
  if (p.kind === "guard_blocked") return undefined;
  // Escalations stack per terminal (nothing serializes the blocking-prompt path).
  // An agent blocked on a permission/question reads nothing until that prompt is
  // resolved, so a one-tap offered beside an unanswered one sends text into a
  // stalled session and leaves the pill exactly where it was: an action that looks
  // like it cleared the situation and did not. The free-text sheet costs the user
  // the same send but makes them read first; that is the deliberate half-step this
  // withholds. The app enforces the mirror of this for the order the bridge cannot
  // see (a prompt arriving AFTER a card was already minted).
  if (p.open?.some((e) => e.kind === "resolve_in_session")) return undefined;
  // floorRule is set only by the HARD floor, which nothing lifts. Those keep
  // costing a human who reads the text behind the reply sheet's floor banner.
  if (p.floorRule !== undefined) return undefined;
  const draft = p.draftReply.trim();
  if (!draft) return undefined;
  // A one-tap must not carry a command the floor recognizes — advisory hits as much
  // as hard ones, since the editable sheet is where the user actually reads what
  // they are about to send.
  const floor = classifyDestructive(draft, p.projectPath);
  if (floor.hard.length > 0 || floor.warnings.length > 0) return undefined;
  // Validated against the wire rule itself rather than a second copy of its bounds:
  // an over-long or control-char draft is one the app could not offer as a chip, and
  // it falls back to the free-text sheet instead.
  const approve = EscalationChoiceSchema.safeParse({ choiceId: "approve", label: "Approve", text: draft });
  if (!approve.success) return undefined;
  return [approve.data, { choiceId: "reject", label: "Reject", text: REJECT_CHOICE_TEXT }];
}

export interface HandlerEngineDeps {
  projectId: string;
  // Per terminal, not per project: an isolated session runs in its own managed
  // worktree, and both the judge's cwd and the destructive floor's inside-project
  // test must follow it there. Omit the id for the project-wide default.
  projectPath: (terminalId?: string) => string;
  // A thunk, not a snapshot: resolved lazily per terminal so chat slots report
  // their own tool (session entry) and the project default can change after
  // construction (the first-run wizard sets config.agent.tool later). Omit the
  // id for the project-wide default (handler:status has no terminal in scope).
  tool: (terminalId?: string) => string;
  /** Whether the engine can observe this slot at all — its tool's integration
   *  in its CURRENT mode. A thunk for the same reason `tool` is: a slot's mode
   *  can flip after construction. Absent = assume observable (a bare engine in
   *  a test, or a caller that predates the declaration). */
  observable?: (terminalId: string) => boolean;
  /** Whether the account behind this machine pays for Handler. Built by
   *  {@link createEntitlementReader} from the live device token, and read on
   *  every arm and every event rather than once — a token is re-minted hourly
   *  and a subscription can lapse under a session that is already armed.
   *  Absent = a bare engine with no host (a test), which is the unwired answer:
   *  allowed. Refusal is spelled inside the verdict, never by absence. */
  entitlement?: EntitlementReader;
  // The agent's native conversation id for a slot (codex thread id / opencode
  // sessionID), used to locate its on-disk transcript. Optional: absent means
  // context falls back to PTY scrollback.
  agentSessionId?: (terminalId: string) => string | undefined;
  abDir: string;
  adapter: SessionAdapter;
  sendAb: (msg: AbMessage) => void;
  /** `terminalId` names the supervised slot so the notification carries the
   *  same session identity the hook-sourced ones do; without it the per-session
   *  work reduction would miss the one turn end the handler resolves itself. */
  sendPush?: (message: string, terminalId: string) => void;
  runDecisionFn?: typeof defaultRunDecision;
  runExtractionFn?: typeof defaultRunExtraction;
  // Snapshot/undo (snapshot.ts), injectable: the real ones shell out to git and
  // copy trees, so a test that could not replace them would need a repo on disk.
  takeSnapshotsFn?: typeof takeSnapshots;
  undoSnapshotFn?: typeof undoSnapshot;
  clearTrashFn?: (sessionId: string) => Promise<void>;
  releaseSnapshotsFn?: (entries: SnapshotEntry[]) => Promise<void>;
  loadSnapshotsFn?: () => StoredSnapshot[];
  saveSnapshotsFn?: (entries: StoredSnapshot[]) => void;
  loadWrapUpsFn?: () => WrapUpRecord[];
  saveWrapUpsFn?: (entries: WrapUpRecord[]) => void;
  appendActivityFn?: (rec: ActivityRecord) => void;
  loadSessionFn?: (terminalId: string) => HandlerSessionRecord | null;
  saveSessionFn?: (rec: HandlerSessionRecord) => void;
  now?: () => number;
  schedule?: LifecycleDeps["schedule"];
  guard?: RunawayGuard;
}

interface ArmedSession {
  goal: string;
  // The live instruction stack, and the only record of progress: an item's own
  // status is what it has reached, so nothing accumulates alongside it.
  backlog: InstructionItem[];
  armedAt: number;
  state: "watching" | "handling" | "needs_you" | "parked";
  // Full payloads, not a count: status snapshots replay these so the app can
  // always render an answerable row for every pending escalation.
  escalations: OpenEscalation[];
  judgeTool?: string;
  judgeModel?: string;
  // Absent until the user picks one. Resolved to DEFAULT_PERSONALITY at the two
  // points that consume it — the status emit and the decide prompt — rather than
  // defaulted here, so "never chosen" stays distinguishable on disk from a
  // session the user deliberately set back to the default preset.
  personality?: HandlerPersonality;
  parkKind?: "limit" | "outage";
  parkedUntil?: number;
  selfResuming?: boolean;
  // Consecutive terminal transient failures. A judged decision clears it.
  transientFailures: number;
  // Advisory floor hits on replies this session already injected, fed back
  // into the next decide prompt. Deliberately not persisted: the activity log is
  // the durable audit trail, and this copy exists only to shape the next call.
  floorWarnings: string[];
  // Terminal transitions the citation gate refused last pass, fed back the way
  // floorWarnings are. Not persisted for the same reason limitParks is not: a
  // restart is itself a break in continuity, and the activity feed already holds
  // the durable trail. Carries the item id, not just the rendered line: the
  // prompt section states the refused items are STILL OPEN, so an entry has to be
  // dropped when its item closes or it contradicts the backlog beside it.
  evidenceRejections: { id: string; line: string }[];
  // Asks the harness refused to raise, fed back the way the two lists above are
  // and not persisted for the same reason. Fed to the JUDGE and not to the user:
  // the reply was sent and the work went on, so nothing is waiting — but a judge
  // that never learns why its question vanished asks the same one every pass.
  askRejections: string[];
  // Per item, how many times the command anchor ALONE has refused a completion.
  // The waiver it feeds is the only exit from an item whose text carries a
  // command-shaped token that is not a command (see MAX_ANCHOR_REFUSALS). Not
  // persisted, like the two above it.
  anchorRefusals: Map<string, number>;
  // Items that have already spent their one `evidence_rejected` feed row. A judge
  // that keeps re-citing the same way is refused every pass, and one row per
  // ITEM — not per attempt — is what keeps the feed a record of what happened to
  // the backlog rather than a transcript of the judge's retries.
  evidenceRejected: Set<string>;
  // What the user's own instructions authorized for this session. Not
  // persisted, unlike the backlog those instructions also produced: rebuilding it
  // after a restart could only come from the stored item text, which extraction
  // wrote — laundering judge output into an authorization is exactly what
  // instruction-scoped authorization exists to prevent. A restart therefore costs
  // one advisory row per operation the user has to name again, which is the cheap
  // side of that trade.
  auth: InstructionAuthorization;
  // Consecutive limit parks that ended with the limit still in force. Not
  // persisted, unlike transientFailures: it bounds one in-process park→nudge
  // cycle, and a restart is itself a break in that cycle.
  limitParks: number;
  // One push per park episode: a re-park is the same wait, not a new one.
  parkPushSent?: boolean;
  // Fingerprint of the context the last COMPLETED decide pass reasoned over. An
  // event whose context hashes the same brings the judge no information it has
  // not already ruled on, so it is skipped rather than judged again (claude's
  // post-completion idle nudge raises one such event per turn; work-status.ts
  // filters it for the status dot, the /handler-event path does not).
  //
  // Keyed on the CONTEXT ALONE, never the backlog: a backlog move is the judge's
  // own bookkeeping, and re-judging because a prior pass unblocked an item is the
  // self-referential loop this exists to break — an item was once marked `done` on
  // a re-read of the very message that had just completed its dependency. New
  // evidence has to come from the agent. User-originated input (a re-arm, stacked
  // instructions, a submitted line) clears it; a transition never does.
  //
  // Not persisted, for the reason limitParks is not: a restart is itself a break
  // in continuity, and a stale hash surviving one would skip a pause that nothing
  // re-raises.
  lastJudgedContextHash?: string;
  // Outage park born of a judge failure: the pause was never judged, so the
  // wake re-runs this event instead of nudging past supervision.
  retryEvent?: HandlerEvent;
  // The persisted shadow of retryEvent. The event itself is too stale to keep
  // across a restart, but the fact that a judge still owes this pause a verdict
  // is not — without it the rehydrated park would wake and nudge, letting the
  // agent carry on from a pause nobody ever assessed.
  parkAwaitingJudge?: boolean;
  // The user's answer to a standing ask, waiting for a judge pass to relay it to
  // the agent in the judge's own words. Set is unrelayed: the handle branch is
  // what clears it, and it is the only place text provably reached the agent.
  // Persisted, for the reason the record's own field states — answering an ask
  // retires the row, so an answer lost to a restart leaves the user with no
  // surface that could tell them it went missing.
  askAnswer?: NonNullable<HandlerSessionRecord["askAnswer"]>;
  // An injected reply is outstanding, so the agent is working and its own
  // turn_end is already in flight. maybeRelayNow reads it to decide whether an
  // answer waits for that event or re-enters immediately: with a reply
  // outstanding, re-entering would land the relay mid-turn, which is the
  // delivery a framed answer exists to avoid.
  //
  // Deliberately not persisted. A restart leaves nothing outstanding, and that
  // default is the conservative one: the first answer after it re-enters rather
  // than waiting on an event no process is going to raise.
  awaitingAgent?: boolean;
}

// The rejections a REFUSED CITATION produces, as opposed to the harness
// invariants (a minted id, a walked-back completion) a judge cannot be taught
// around. Only these reach the user's feed and the next decide prompt.
const EVIDENCE_CODES: ReadonlySet<RejectionCode> = new Set<RejectionCode>([
  "missing_evidence", "unverified_evidence", "missing_command_anchor",
]);

// Items whose command anchor has been refused so often that the harness stops
// asking — the token in their text is not a command anything can run, so no
// wording of the truth would ever satisfy it (see MAX_ANCHOR_REFUSALS).
function waivedAnchors(s: ArmedSession): ReadonlySet<string> {
  const waived = new Set<string>();
  for (const [id, n] of s.anchorRefusals) if (n >= MAX_ANCHOR_REFUSALS) waived.add(id);
  return waived;
}

// Escalations that are a QUESTION waiting on the human, as opposed to a report
// of something Handler could not do. Every rule that means "somebody is already
// being waited on" reads this rather than the row count: a `guard_blocked` row
// is retired by an explicit dismiss alone, so a report nobody has got round to
// would otherwise silence the session — no further escalation, no park nudge, no
// wrap-up — for the rest of its life.
function pendingQuestions(s: ArmedSession): number {
  return s.escalations.filter((e) => e.kind !== "guard_blocked").length;
}

// Questions the session has actually STOPPED for, as opposed to every question
// it has put to the user. An ask rides a pass that already replied to the agent,
// so the work went on and nothing is waiting on it — which is a different fact
// from "somebody is being waited on", and only the park nudge wants this one.
//
// `!e.nonBlocking` rather than `e.nonBlocking === false`: a row written before
// the field, and one an older bridge stripped it from and re-persisted, both mean
// the session stopped.
function blockingQuestions(s: ArmedSession): number {
  return s.escalations.filter((e) => e.kind !== "guard_blocked" && !e.nonBlocking).length;
}

// Where a session lands once whatever it was doing is over — a judged decision,
// a submitted line, the end of a park. An escalation the user never answered
// outranks all three: "watching" with a pending row is a session the app draws
// as quiet over an agent that is still waiting.
//
// Reports count here, unlike in pendingQuestions: `pendingEscalations` on the
// wire is a count of ROWS, so resting at "watching" over a listed row would have
// the Needs-you list and the run-state pill disagree about the same escalation.
// The way out of that state is the row's own Dismiss, not a state that hides it.
function restingState(s: ArmedSession): "watching" | "needs_you" {
  return s.escalations.length > 0 ? "needs_you" : "watching";
}

export class HandlerEngine {
  private guard: RunawayGuard;
  private sessions = new Map<string, ArmedSession>();
  private seq = 0;
  // Per-terminal work chain, covering everything that spawns an agent CLI.
  // handleEvent is fire-and-forget from agent-core (each /handler-event POST is
  // unawaited), so two events for one terminal could otherwise run concurrent
  // judge calls that both pass the disarm recheck and both inject — two
  // conflicting replies from one supervised decision. Extraction rides the same
  // chain: two instructions typed a second apart would otherwise extract
  // concurrently and append in completion order, and for items the user stated
  // without an ordering word their position in the list is the ONLY record of
  // the order they asked for them in.
  private chains = new Map<string, Promise<void>>();
  // Newest event per terminal, for coalescing: events queued behind a slow judge
  // call are stale by the time they'd run (the agent has already moved on), so
  // only the most recent one gets a judge call. Serialization without coalescing
  // would run one full judge spawn (up to 45s) per queued event, composing
  // replies against context the agent left minutes ago.
  private latest = new Map<string, HandlerEvent>();
  // Blocking-prompt events on the chain but not yet judged. Prompts are exempt
  // from `latest` (see handleEvent), so a retraction that lands while one is
  // still waiting has nothing there to take it out of — this is what it removes
  // it from instead. Keyed by event, not by prompt id, so a prompt that never
  // named one is still droppable.
  private queuedPrompts = new Map<string, Set<HandlerEvent>>();
  private timers: TimerRegistry;
  // Read-through cache of the project's snapshot store. Cached because
  // emitStatus reads the whole list on every status broadcast; every mutation
  // writes through and prunes on the same terms as the file, so the two agree.
  private storedSnapshots: StoredSnapshot[] | null = null;
  // The same read-through cache for the wrap-up store, for the same reason: every
  // status broadcast renders the whole list.
  private storedWrapUps: WrapUpRecord[] | null = null;
  // Undos in flight, by snapshot id. Two taps on one row must not run two undos:
  // the second would be acting on a tree the first already moved.
  private undoing = new Set<string>();
  private entitlement: EntitlementReader;

  constructor(private deps: HandlerEngineDeps) {
    this.entitlement = deps.entitlement ?? createEntitlementReader();
    this.guard = deps.guard ?? new RunawayGuard();
    this.timers = new TimerRegistry({
      now: () => this.now(),
      schedule: deps.schedule ?? defaultSchedule,
    });
  }

  /**
   * The one entitlement question this engine asks, in the two places it asks
   * it. Nothing here compares a tier — the capability name goes to the registry
   * (../entitlement.ts) and a verdict comes back, so the next capability is
   * added there and nowhere else.
   *
   * Not to be confused with `./authorization.ts`, which decides what a sentence
   * a HUMAN typed permits a supervised agent to do. This decides what the
   * account paid for.
   */
  private entitledForHandler(terminalId: string, at: "arm" | "event"): boolean {
    const verdict = this.entitlement("handler");
    if (verdict.allowed) return true;
    // Logged for the machine's owner, who is the only reader who can see a
    // tier claim go wrong. What the USER is told rides the status frame
    // instead (see entitlementForApp) — a warn line on a desktop is no answer
    // for a shield pressed on a phone.
    log.warn(
      "handler %s refused for %s: entitlement %s (tier=%s)",
      at, terminalId, verdict.reason, verdict.tier ?? "unknown",
    );
    return false;
  }

  /**
   * The same verdict, shaped for the app — null whenever Handler is available,
   * so a status frame carries this key only while the answer is "no".
   *
   * Derived on every emit rather than latched at the refusal: the claim is a
   * thunk over a token re-minted roughly hourly, so an account that upgrades
   * (or a machine whose credentials come back) is entitled from the next frame
   * with nothing to clear. The app is told once and the shield stops gating —
   * which is why nothing here is remembered between emits.
   */
  private entitlementForApp(): HandlerEntitlement | null {
    const verdict = this.entitlement("handler");
    if (verdict.allowed) return null;
    return verdict.tier === undefined
      ? { reason: verdict.reason }
      : { reason: verdict.reason, tier: verdict.tier };
  }

  // Judge choice application, shared by fresh-arm and edit-arm. Fields arrive
  // through HandlerConfigureWire (typed string|undefined), but the VALUES are
  // still untrusted: '' = clear to default, an unknown tool is ignored
  // outright (buildJudgeCommand would return null and gate the Handler off)
  // rather than clearing the working one.
  private applyJudgeChoice(
    s: { judgeTool?: string; judgeModel?: string },
    p: { judgeTool?: string; judgeModel?: string },
  ): void {
    if (p.judgeTool !== undefined && (p.judgeTool === "" || judgeCapable(p.judgeTool))) {
      s.judgeTool = p.judgeTool || undefined;
    }
    if (p.judgeModel !== undefined) s.judgeModel = p.judgeModel.trim() || undefined;
  }

  // Absent leaves the stored posture alone, the same rule applyJudgeChoice
  // follows. Zod has already bounded the value to the three presets, so unlike
  // judgeTool there is nothing further to validate here.
  private applyPersonality(
    s: { personality?: HandlerPersonality },
    p: { personality?: HandlerPersonality },
  ): void {
    if (p.personality !== undefined) s.personality = p.personality;
  }

  // The session's stored judge: the live armed session if one exists, else the
  // on-disk record (a disarmed session keeps its pick for the next arm).
  // Callers that already loaded the record pass it as `rec` (null = "loaded,
  // absent") so one call doesn't read and parse the same file twice.
  private storedJudge(terminalId: string, rec?: HandlerSessionRecord | null): { tool?: string; model?: string } {
    const live = this.sessions.get(terminalId);
    if (live) return { tool: live.judgeTool, model: live.judgeModel };
    const r = rec !== undefined ? rec : this.loadSession(terminalId);
    return { tool: r?.judgeTool, model: r?.judgeModel };
  }

  private now(): number { return this.deps.now ? this.deps.now() : Date.now(); }
  private id(prefix: string): string { return `${prefix}-${this.deps.projectId}-${this.now()}-${this.seq++}`; }
  private loadSession(terminalId: string): HandlerSessionRecord | null {
    return this.deps.loadSessionFn
      ? this.deps.loadSessionFn(terminalId)
      : loadHandlerSession(this.deps.abDir, this.deps.projectId, terminalId);
  }
  private saveSession(rec: HandlerSessionRecord): void {
    (this.deps.saveSessionFn ?? ((r: HandlerSessionRecord) =>
      saveHandlerSession(this.deps.abDir, this.deps.projectId, r)))(rec);
  }
  private snapshots(): StoredSnapshot[] {
    this.storedSnapshots ??= this.deps.loadSnapshotsFn
      ? this.deps.loadSnapshotsFn()
      : loadSnapshots(this.deps.abDir, this.deps.projectId);
    return this.storedSnapshots;
  }

  // Prunes before caching, not only before writing: an entry the file drops is an
  // undo offer the next restart cannot honor, so advertising it would promise a
  // tap that silently stops working. Whatever the prune drops takes its bytes and
  // its gc pin with it.
  private saveSnapshots(entries: StoredSnapshot[]): void {
    const { kept, dropped } = pruneSnapshots(entries);
    this.storedSnapshots = kept;
    (this.deps.saveSnapshotsFn ?? ((e: StoredSnapshot[]) =>
      saveSnapshots(this.deps.abDir, this.deps.projectId, e)))(kept);
    if (dropped.length) this.release(dropped);
  }

  private wrapUps(): WrapUpRecord[] {
    this.storedWrapUps ??= this.deps.loadWrapUpsFn
      ? this.deps.loadWrapUpsFn()
      : loadWrapUps(this.deps.abDir, this.deps.projectId);
    return this.storedWrapUps;
  }

  // Prunes before caching on the same terms as saveSnapshots — the cache and the
  // file have to advertise the same set — but nothing is reclaimed on the way out:
  // a wrap-up pins no stash, backup ref or trash copy, so ageing one out costs
  // only the reading of it.
  private saveWrapUps(entries: WrapUpRecord[]): void {
    const kept = pruneWrapUps(entries);
    this.storedWrapUps = kept;
    (this.deps.saveWrapUpsFn ?? ((e: WrapUpRecord[]) =>
      saveWrapUps(this.deps.abDir, this.deps.projectId, e)))(kept);
  }

  // Fire-and-forget: the entries are already unreachable through the store, so
  // nothing the user can still act on waits on the cleanup.
  private release(entries: StoredSnapshot[]): void {
    this.releaseEntries(entries.map((e) => e.entry));
  }

  // The same cleanup for captures that never made it INTO the store, which the store
  // can therefore never retire on their behalf.
  private releaseEntries(entries: SnapshotEntry[]): void {
    if (entries.length === 0) return;
    void (this.deps.releaseSnapshotsFn ?? ((e: SnapshotEntry[]) =>
      releaseSnapshots(e, { abDir: this.deps.abDir })))(entries)
      .catch((err: unknown) => log.warn("handler snapshot cleanup failed: %s", err));
  }

  private persist(terminalId: string, s: ArmedSession, armed: boolean, suspended?: boolean): void {
    this.saveSession({
      version: 2, terminalId, armed, suspended, goal: s.goal, backlog: s.backlog,
      armedAt: s.armedAt, escalations: s.escalations,
      judgeTool: s.judgeTool, judgeModel: s.judgeModel, personality: s.personality,
      parkKind: s.parkKind, parkedUntil: s.parkedUntil, transientFailures: s.transientFailures,
      parkAwaitingJudge: s.parkAwaitingJudge, askAnswer: s.askAnswer,
    });
  }

  arm(p: {
    terminalId: string; goal?: string; backlog?: InstructionItem[];
    judgeTool?: string; judgeModel?: string; personality?: HandlerPersonality;
  }): void {
    // Entitlement first, ahead of every side effect below — the backlog clamp
    // records an activity row, and a refused arm must leave nothing behind.
    //
    // This is the narrowest correct point in the engine: `sessions.set` happens
    // exactly once in this file, inside this method, and the restart-rehydration
    // path is inside it too, so a persisted armed record cannot route around the
    // gate by resurrecting itself. Every other public method is already a no-op
    // without a session.
    if (!this.entitledForHandler(p.terminalId, "arm")) {
      // Refuse WITHOUT disarming, exactly as a malformed `handler:configure`
      // does (agent-core.ts): a live session must not be torn down by a request
      // that failed to replace it. The re-emit is what ANSWERS the sender: the
      // frame carries the refusal (entitlementForApp), so an app whose cached
      // verdict was stale learns the real one within a round trip instead of
      // waiting out its arm-confirmation window on a state that never moved.
      this.emitStatus();
      return;
    }
    // MAX_BACKLOG_ITEMS bounds the stack renderBacklog interpolates into every
    // later decide prompt, and appendItems is not the only way in: a
    // `handler:configure` payload assigns the list wholesale and BacklogWire
    // bounds only its shape. Clamped here, the one place a backlog is ever
    // assigned, so the wire path cannot outgrow the extraction path.
    const backlog = p.backlog !== undefined && p.backlog.length > MAX_BACKLOG_ITEMS
      ? p.backlog.slice(0, MAX_BACKLOG_ITEMS)
      : p.backlog;
    // Same reason appendItems records its drops: the status snapshot the app
    // gets back carries the clamped list with nothing saying why it is short,
    // so without a feed row the missing items are indistinguishable from items
    // the user never sent.
    if (p.backlog !== undefined && backlog !== undefined && backlog.length < p.backlog.length) {
      this.record(p.terminalId, "instruction_dropped",
        `backlog is full (${MAX_BACKLOG_ITEMS} items)`,
        `${p.backlog.length - backlog.length} item(s) not tracked`);
    }
    const existing = this.sessions.get(p.terminalId);
    if (existing) {
      // Mutate in place, never replace: an in-flight judge call holds a reference
      // to this session and re-checks identity after its await — swapping in a
      // fresh object would silently drop that decision and leave the copied
      // "handling" state with nothing left to reset it.
      //
      // Absent means "leave it alone", never "clear it" (an empty backlog is sent
      // as []): a re-arm or a goal edit carries no backlog, and the bridge's
      // copy is the one holding the statuses this session has banked.
      const goalChanged = p.goal !== undefined && p.goal.trim() !== existing.goal.trim();
      if (p.goal !== undefined) existing.goal = p.goal;
      if (backlog !== undefined) existing.backlog = backlog;
      // A configure is the user restating what this session is for, so the last
      // pass's verdict no longer covers the same question — the next event is
      // judged even if the agent has not moved.
      existing.lastJudgedContextHash = undefined;
      this.applyJudgeChoice(existing, p);
      this.applyPersonality(existing, p);
      this.persist(p.terminalId, existing, true);
      // Only when the goal actually moved: `handler:configure` is also the
      // backlog-edit and judge-pick path (see updateBacklog in the app), and a
      // "Goal edited" row over an unchanged goal is a feed that misreports what
      // happened on every reorder and every judge change.
      if (goalChanged) this.record(p.terminalId, "goal_edited", existing.goal || NO_GOAL);
      this.emitStatus();
      // A goal landing on a session whose backlog is still empty is the user's
      // first statement of what this session is for — the 1-tap arm before it had
      // nothing to extract. Once items exist, a new goal is a rename: stacking
      // more work goes through handler:instruct, and re-extracting here would
      // append a second copy of the sentence on every edit.
      if (goalChanged && backlog === undefined && existing.goal.trim()) {
        this.queueExtraction(p.terminalId, existing.goal.trim(), { onlyIfEmpty: true });
      }
      return;
    }
    // No in-memory session, but a bridge restart leaves the persisted record
    // behind — rehydrate goal/backlog/escalations from it so re-arming doesn't
    // clobber progress the previous process already banked.
    //
    // `suspended` is what makes that reachable across a restart at all: a host
    // shutdown kills the PTYs, and a dead terminal disarms (onTerminalExit), so
    // gating on `armed` alone meant the record was ALWAYS unarmed by the time
    // anyone re-armed. `armed` still counts on its own — a hard kill leaves the
    // record as it stood, with no exit handler to run.
    const rec = this.loadSession(p.terminalId);
    const resumed = rec && (rec.armed || rec.suspended) ? rec : null;
    // A genuinely new session on this slot is the moment the previous one's undo
    // offers stop meaning anything — and the only such moment. Disarm is NOT one:
    // a wrap-up disarms while the offer still matters, since the summary that
    // carries it is read hours later. A resumed record is the same session
    // continuing across a restart, so it keeps everything.
    if (!resumed) this.retireSnapshots(p.terminalId);
    const stored = this.storedJudge(p.terminalId, rec);
    // A `resolve_in_session` row names a prompt held by a driver in a runtime that
    // is gone — suspension follows the terminal's exit, and a restart rebuilds every
    // driver with no pending prompts — so nothing is left to resolve or retract it.
    // Carrying one across would wedge the slot: no typed line clears it, wrap-up
    // never fires, and the park nudge stops.
    const carried = (resumed?.escalations ?? []).filter((e) => e.kind !== "resolve_in_session");
    const s: ArmedSession = {
      goal: p.goal ?? resumed?.goal ?? "",
      backlog: backlog ?? resumed?.backlog ?? [],
      armedAt: resumed?.armedAt ?? this.now(),
      state: carried.length > 0 ? "needs_you" : "watching",
      escalations: carried,
      // Seed from the persisted record (armed pre-restart OR the last disarmed
      // pick), then let an explicit choice on this arm override it.
      judgeTool: stored.tool,
      judgeModel: stored.model,
      // Off the RECORD, not off `resumed`: a deliberate disarm keeps the pick
      // for the next arm, exactly as the judge fields above do.
      personality: rec?.personality,
      // Carried across the restart the way the escalations above it are, and for
      // the sharper version of the same reason: the row this answers is already
      // retired, so dropping the answer here would leave the user believing they
      // had answered with nothing on any surface saying otherwise.
      askAnswer: resumed?.askAnswer,
      transientFailures: resumed?.transientFailures ?? 0,
      limitParks: 0,
      floorWarnings: [],
      evidenceRejections: [],
      askRejections: [],
      evidenceRejected: new Set(),
      anchorRefusals: new Map(),
      auth: createAuthorization(),
    };
    this.applyJudgeChoice(s, p);
    this.applyPersonality(s, p);
    this.sessions.set(p.terminalId, s);
    this.persist(p.terminalId, s, true);
    // "armed" either way: nothing is edited on this path — the goal is whatever the
    // previous process banked — and a real edit re-arms an in-memory session, which
    // is recorded above. Deliberately NOT "resumed", which belongs to the park
    // lifecycle; spending it here would make "did the park end?" unanswerable from
    // the feed. The rehydrated rows above this one are what mark it as a resume.
    this.record(p.terminalId, "armed", s.goal || NO_GOAL);
    this.emitStatus();
    // Rehydrated last, so the arm record still reads as the session's opening
    // line and a deadline already past can resume straight into the new process.
    if (resumed?.parkKind && resumed.parkedUntil !== undefined) {
      this.rehydratePark(p.terminalId, s, resumed.parkKind, resumed.parkedUntil, resumed.parkAwaitingJudge);
    }
    // The user types one sentence and the session arms immediately, with
    // extraction resolving behind the handoff. Skipped once a backlog exists — a
    // rehydrated or app-supplied one is already the user's list, and extracting
    // the goal alongside it would double every item.
    if (s.goal.trim() && backlog === undefined) {
      this.queueExtraction(p.terminalId, s.goal.trim(), { onlyIfEmpty: true });
    }
  }

  // selfResuming and retryEvent are deliberately not persisted: a restart drops
  // the stale pause event, and a driver that parks itself re-announces.
  private rehydratePark(
    terminalId: string, s: ArmedSession, kind: "limit" | "outage", until: number, awaitingJudge?: boolean,
  ): void {
    s.state = "parked";
    s.parkKind = kind;
    s.parkedUntil = until;
    s.parkAwaitingJudge = awaitingJudge;
    // A deadline that expired while we were down wakes into a runtime this
    // process never armed: the PTY may have been respawned empty, so a nudge
    // would submit "continue" to a shell prompt the instant the user re-arms.
    // Resume quietly and let the next real event reach the judge — the same
    // answer the judge-owed park below gives, for the same reason.
    if (until <= this.now()) {
      this.unparkIfParked(terminalId, s);
      this.persist(terminalId, s, true);
      this.record(terminalId, "resumed", "park expired while the bridge was down");
      this.emitStatus();
      return;
    }
    this.timers.arm(terminalId, until - this.now(), () => this.runParkTimer(terminalId));
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  /**
   * Stack more instructions onto a live session. Returns without waiting
   * on the extraction spawn: arming and stacking are one tap, and a supervisor
   * that made the user watch a 20s CLI run before their sentence appeared would
   * be a worse product than one that fills the list a moment later.
   *
   * Instructing never arms — `handler:configure` is the only thing that does.
   *
   * This is also the ONE feed point for instruction-scoped authorization. The
   * arm-time goal is deliberately not one: it is a statement of what the session
   * is for, and a lift has to be traceable to a sentence the user wrote to
   * authorize an action.
   *
   * Returns what the sentence granted, or null where it reached no session and no
   * lift was taken. The grant is the half of an instruction the user cannot infer
   * from their own words — "clear out the build dir" reads as a chore and is also
   * a session-long permission — so it is recorded here rather than left implicit.
   */
  instruct(p: { terminalId: string; text: string; escalationId?: string }): GrantSummary | null {
    const s = this.sessions.get(p.terminalId);
    // Free text ANSWERING a standing ask, per the answer transport: the frame names
    // the row it answers, and everything below this branch is left byte for byte as
    // it was for an ordinary instruction.
    if (p.escalationId !== undefined) {
      const esc = s?.escalations.find((e) => e.escalationId === p.escalationId && e.nonBlocking);
      // Fails CLOSED. Falling through here would authorize and extract a sentence
      // the user sent as an ANSWER, on a window an agent can influence:
      // reconcileAsks retires an ask by clearing `nonBlocking`, driven by agent
      // events. Same reason a duplicate Send must not become a second instruction.
      // The resync is what takes the row off the sender's list.
      if (!s || !esc) {
        log.warn("handler instruct ignored: %s is not a standing ask on %s", p.escalationId, p.terminalId);
        this.emitStatus();
        return null;
      }
      const text = p.text.trim();
      if (!text) return null;
      // UNMOVED, and this ordering is the whole security property: the lift is
      // taken on the raw payload, before extraction, at the single feed point.
      const granted = authorizeInstruction(s.auth, text, this.deps.projectPath(p.terminalId));
      // describeGrant reports g.destinations and NOT g.hosts, on purpose (see its
      // comment) — the harvest reads any dotted token as a host, so echoing the
      // superset back would call every source file a network permission. That is
      // right for an instruction the user composed unprompted; it is wrong here,
      // because Handler's own question is what elicited this sentence. At most one
      // row per answered ask, so naming the hosts costs nothing and closes the
      // only session-long grant the user could never see.
      const described = describeGrant(granted) ?? (granted.hosts.length > 0
        ? { reason: countPhrase(granted.hosts.length, ["host", "hosts"]), detail: rowSample(granted.hosts) }
        : null);
      if (described) this.record(p.terminalId, "instruction_authorized", described.reason, described.detail);
      // NO queueExtraction. The extractor is told to split a sentence into work
      // (extract.ts) and has no third result arm, so an answer routed through it
      // becomes a backlog item the judge DRIVES at the agent — where the judge is
      // supposed to relay it in its own words on the next pass.
      this.parkAskAnswer(p.terminalId, s, esc, text, false);
      this.record(p.terminalId, "escalate", "you answered Handler's question", previewForUser(text));
      this.maybeRelayNow(p.terminalId, s);
      return granted;
    }
    if (!s) {
      log.warn("handler instruct ignored: no armed session for %s", p.terminalId);
      return null;
    }
    const text = p.text.trim();
    if (!text) return null;
    // Taken from the raw payload and BEFORE the extraction spawn: extraction output is
    // judge-authored, so deriving a lift from it would let a compromised agent widen
    // its own permissions through the extractor.
    const granted = authorizeInstruction(s.auth, text, this.deps.projectPath(p.terminalId));
    const described = describeGrant(granted);
    if (described) {
      this.record(p.terminalId, "instruction_authorized", described.reason, described.detail);
    }
    this.queueExtraction(p.terminalId, text);
    return granted;
  }

  /**
   * One tap on an ask's option, recorded as the user's own answer.
   *
   * What it deliberately does NOT do, because every one of these is a path the
   * ask shape exists to keep judge-authored text off (see quickChoicesFor):
   * `authorizeInstruction`, `queueExtraction`, `injectReply`, `guard.reset`,
   * `arm`, `disarm`, `enterPark`, and minting a snapshot. `s.auth` is
   * byte-identical across a tap, and nothing here reaches the agent — the judge
   * relays the answer in its own words on the pass that follows.
   *
   * The option's words never travel back on the wire: the app sends a
   * `choiceId` and the label is resolved from this bridge's OWN persisted row,
   * so what is parked for the judge is exactly the string the user read.
   *
   * Fails CLOSED in every direction the app can get wrong, and unlike
   * `answerWithChoice` app-side there is no fallback to a caller-supplied row: an
   * id this session does not hold as a standing ask (a tap racing the frame that
   * already retired it) resyncs the sender rather than answering something else.
   */
  answerAsk(p: { terminalId: string; escalationId: string; choiceId: string }): void {
    const s = this.sessions.get(p.terminalId);
    if (!s) {
      log.warn("handler answer ignored: no armed session for %s", p.terminalId);
      return;
    }
    const esc = s.escalations.find((e) => e.escalationId === p.escalationId && e.nonBlocking);
    if (!esc) {
      log.warn("handler answer ignored: %s is not a standing ask on %s", p.escalationId, p.terminalId);
      this.emitStatus();
      return;
    }
    // Resolved against this row's own options, never against anything the frame
    // carried: a `choiceId` is identity, and the label it names is what the user
    // read on the button they pressed.
    const option = esc.askOptions?.find((o) => o.choiceId === p.choiceId);
    if (!option) {
      log.warn("handler answer ignored: %s names no option on %s", p.choiceId, p.escalationId);
      this.emitStatus();
      return;
    }
    this.parkAskAnswer(p.terminalId, s, esc, option.label, true);
    // The existing `escalate` value rather than a new one: the activity kind is
    // hand-mirrored into two more files and a value missing from either renders
    // as an unknown row at runtime, never as a build error.
    this.record(p.terminalId, "escalate", "you answered Handler's question", previewForUser(option.label));
    this.maybeRelayNow(p.terminalId, s);
  }

  /**
   * Bank the user's answer and retire the question it answers. Shared by the tap
   * and the free-text arms, so the two cannot come to differ about what
   * answering an ask means.
   */
  private parkAskAnswer(
    terminalId: string, s: ArmedSession, esc: OpenEscalation, answer: string, tapped: boolean,
  ): void {
    // A parked answer is by definition unrelayed — the handle branch clears it the
    // moment one reaches the agent — so this is a real answer about to be lost.
    // At most one ask stands at a time, and a silent replace would drop the first
    // one with nothing anywhere saying so.
    if (s.askAnswer) {
      this.record(terminalId, "escalate", "your earlier answer was replaced",
        previewForUser(s.askAnswer.answer));
    }
    s.askAnswer = {
      escalationId: esc.escalationId, question: esc.question, answer, tapped, at: this.now(),
    };
    s.escalations = s.escalations.filter((e) => e !== esc);
    // Without this the answer is discarded with no row, no log and no push.
    // `contextHash` is computed over `ctx.text` alone and `assembleContext` builds
    // that from the transcript plus recent PTY, so an answer that lives only in a
    // prompt option moves nothing in it — and the next pass would return at the
    // unmoved-context check having judged nothing at all.
    s.lastJudgedContextHash = undefined;
    // A park is not over because a question was answered — the dismissEscalation
    // precedent: the timer is still armed and parkKind/parkedUntil still describe
    // the wait.
    if (s.state !== "parked") s.state = restingState(s);
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  /**
   * Relay the parked answer now, or leave it for the pass that is already coming.
   *
   * The ask rides a handle that already injected a reply, so when a reply is
   * still outstanding the agent's own turn_end is in flight and IS the pass that
   * relays. Re-entering here would race it and land the relay mid-turn — the
   * moment a framed delivery exists to avoid — so we do nothing and handleEvent's
   * agent-originated producers stay the only sources of a pass.
   *
   * With nothing outstanding, no event is coming: the reply that carried the ask
   * was answered hours ago and the agent is idle at a prompt. Then re-entering IS
   * the delivery, and on an event `latest` already holds it is the same
   * handleEvent call the two retryEvent sites already make (limit_cleared, park
   * wake) — `latest.set` on the value already there is a no-op, and handleEvent's
   * own liveness re-check still drops this pass if a fresher event overtakes it.
   *
   * An empty `latest` is the case that makes this a genuinely NEW producer, and
   * it is the answered-after-a-restart one: `latest` is in-memory, so a bridge
   * that came back between the ask and the answer has nothing to re-enter on and
   * no agent event is guaranteed ever again. Guaranteed delivery was chosen over
   * the smaller producer set, so one event is synthesised — at most one per
   * answered ask, since answering retires the row and the synthesised event then
   * becomes the `latest` any later answer re-enters on. It deliberately carries no
   * transcriptPath: the one a pre-restart event held names a file for a PTY that
   * is gone, and handleEventInner resolves the live adapter's path instead, which
   * degrades to the PTY tail (and to no context at all) rather than throwing.
   */
  private maybeRelayNow(terminalId: string, s: ArmedSession): void {
    if (s.awaitingAgent) return;
    const evt = this.latest.get(terminalId);
    // Nothing awaits either call: they carry their own sink the way the two
    // retryEvent sites do, and a judge that fails re-parks through the same path.
    if (evt) {
      void this.handleEvent(evt).catch(() => {});
      return;
    }
    // A pass nothing on the machine asked for is exactly the kind of thing a
    // future reader has to be able to find in the feed.
    this.record(terminalId, "escalate", "no agent event was due, so Handler started a pass to relay your answer");
    void this.handleEvent({ terminalId, event: "turn_end" }).catch(() => {});
  }

  // `onlyIfEmpty` is for the arm-time pass: the goal is extracted once,
  // and the check has to happen at DEQUEUE time, or a goal edited twice while the
  // first spawn was still running would append the sentence in both forms.
  private queueExtraction(terminalId: string, text: string, opts: { onlyIfEmpty?: boolean } = {}): void {
    void this.enqueue(terminalId, () => this.extractAndAppend(terminalId, text, opts));
  }

  private async extractAndAppend(
    terminalId: string, text: string, opts: { onlyIfEmpty?: boolean },
  ): Promise<void> {
    // Resolved here rather than where the work was queued: the session may have
    // been disarmed, or its judge re-picked, while this waited its turn.
    const s = this.sessions.get(terminalId);
    if (!s) return;
    if (opts.onlyIfEmpty && s.backlog.length > 0) return;

    // Same resolution the decide path uses, through the same helper: the tool is
    // an untrusted string either way, and `judgeCapable` is where that check
    // lives for every caller.
    const tool = s.judgeTool ?? this.deps.tool(terminalId);
    // Held to the bound the extractor's own items are held to. The fallback is
    // the EXPECTED path on a rate-limited account, so an unbounded one would put
    // a whole pasted instruction into every decide prompt from here on.
    const raw: ExtractedItem[] = [{ ref: "raw", text: text.slice(0, MAX_ITEM_CHARS) }];

    let result: ExtractionResult | null = null;
    if (judgeCapable(tool)) {
      const runExtractionFn = this.deps.runExtractionFn ?? defaultRunExtraction;
      try {
        result = await runExtractionFn({
          tool, model: s.judgeModel, text,
          // Shown to the extractor so one sentence can take an earlier one back,
          // and never the list anything is APPLIED to: what comes back is
          // resolved against the backlog as it stands after this await.
          backlog: s.backlog,
          cwd: this.deps.projectPath(terminalId),
        });
      } catch (err) {
        // A session parked on a provider limit lands here: the extraction spawn
        // shares that limited account. The instruction survives as one raw item,
        // which is why this path needs no park-aware branching.
        log.warn("handler extraction failed for %s: %s", terminalId, err);
      }
    }
    // Caught rather than thrown on: nothing awaits this chain entry, and the
    // append is the whole point of the call, so a failed disk write would
    // otherwise be invisible.
    try {
      const named = result?.amend ?? [];
      const amended = this.applyAmendments(terminalId, s, named);
      // The session this sentence was about has been replaced. appendItems warns
      // and says nothing to the user for the same case, and a feed row here would
      // be written against whichever session now holds this terminal id.
      if (amended === null) return;
      const items = result?.items ?? [];
      if (items.length > 0) {
        this.appendItems(terminalId, s, items);
        return;
      }
      if (amended > 0) {
        this.escalateIfEmptied(terminalId, s);
        return;
      }
      // The extractor read the sentence as taking something back, and nothing it
      // named is still open. Landing it as an item instead is the exact deadlock
      // amendments exist to end — "actually skip the commit" is a line no
      // transcript can ever satisfy — so the sentence is reported as untracked
      // rather than tracked as work. It is quoted, because a user reading the feed
      // hours later has no other way to tell which of their sentences this was.
      if (named.length > 0) {
        this.record(terminalId, "instruction_dropped",
          "nothing it named is still open in the backlog", clipQuote(text));
        // Unchanged snapshot, sent anyway — see appendItems' cap return for why
        // every instruction record owes one.
        this.emitStatus();
        return;
      }
      this.appendItems(terminalId, s, raw);
    } catch (err) {
      log.error("handler instruct append failed for %s: %s", terminalId, err);
    }
  }

  /**
   * The half of an instruction that changes what is already tracked.
   *
   * Applied here and never by the judge: a terminal transition needs a verbatim
   * quote from the transcript, which a change of mind can never produce, so
   * routing "actually skip the commit" through the judge earns an
   * `evidence_rejected` and leaves the item actionable. That gate is untouched by
   * this method — `drop` REMOVES the item rather than closing it, and there is no
   * path here to a status at all, so nothing the user says can add to what the
   * session will later report as done, skipped or failed.
   *
   * Every id is resolved against the items the extractor was actually SHOWN
   * (`amendableItems`), as they stand NOW, and one naming anything else is
   * discarded in silence — the discipline the dangling-ref filter takes, for the
   * same reason: the extractor is an LLM that can now name live ids, and its
   * output is untrusted input.
   *
   * Returns how many items actually moved, or null when the session under this
   * terminal id is no longer the one the sentence was about — which is not the
   * same answer as "nothing matched", and the caller reports the two differently.
   */
  private applyAmendments(terminalId: string, s: ArmedSession, amendments: Amendment[]): number | null {
    if (amendments.length === 0) return 0;
    // The same re-check appendItems makes, for the same reason: the extraction
    // await yielded the event loop, and amending a session the user has since
    // disarmed would re-persist it as armed.
    if (this.sessions.get(terminalId) !== s) {
      log.warn("handler dropped %d amendment(s) for %s: session no longer armed",
        amendments.length, terminalId);
      return null;
    }

    // The terminal states are a one-way door in both directions — an item the
    // harness closed cannot be reopened from the user's words, or the walk-back
    // that re-completes one item per pass forever is back with a new entrance —
    // and everything past the extractor's own cap was offered to it as "not
    // changeable". amendableItems is both bounds in one place.
    const byId = new Map(amendableItems(s.backlog).map((i) => [i.id, i]));
    const dropped = new Set<string>();
    const revised = new Map<string, { text?: string; condition?: string }>();
    const changes: AmendmentChange[] = [];
    for (const a of amendments) {
      const item = byId.get(a.id);
      if (!item) continue;
      if (a.action === "drop") {
        dropped.add(a.id);
        changes.push({ kind: "removed", verb: "removed", text: item.text });
        continue;
      }
      // Compared against the item rather than read off the amendment's shape: a
      // revise carrying the text the item already has, or `"condition":""` for an
      // item that never had one, is an extractor answering with no change at all
      // — and counting it would print a row asserting a change that did not
      // happen AND suppress the fallback that would have tracked the sentence.
      const text = a.text !== undefined && a.text !== item.text ? a.text : undefined;
      const wanted = a.condition === "" ? undefined : a.condition;
      const condition = a.condition !== undefined && wanted !== item.condition ? a.condition : undefined;
      if (text === undefined && condition === undefined) continue;
      revised.set(a.id, { text, condition });
      const nowCondition = condition === undefined
        ? undefined
        : condition === "" ? "no condition" : `only if ${clipQuote(condition)}`;
      changes.push({
        kind: text !== undefined ? "reworded" : "recondition",
        verb: text !== undefined
          ? (condition !== undefined ? "reworded and changed the condition on" : "reworded")
          : "changed the condition on",
        text: item.text,
        now: [
          ...(text !== undefined ? [`"${clipQuote(text)}"`] : []),
          ...(nowCondition ? [nowCondition] : []),
        ].join(" · "),
      });
    }
    if (changes.length === 0) return 0;

    // The dropped items that were themselves BLOCKING something. propagateBlocked
    // derives a block from a dependency that is blocked or failed, so only such a
    // dependency can have been the reason for a dependent's — a block the judge
    // wrote about an item whose dependency was merely queued is not this
    // instruction's to lift, and its outcome is not this instruction's to erase.
    const wasBlocking = new Set(
      [...dropped].filter((id) => byId.get(id)?.status === "blocked"),
    );
    const revived = new Set<string>();
    const next: InstructionItem[] = [];
    for (const i of s.backlog) {
      if (dropped.has(i.id)) continue;
      const item: InstructionItem = { ...i };
      const deps = (i.dependsOn ?? []).filter((d) => !dropped.has(d));
      // A removed item's id survives in every dependsOn that named it, and
      // nextActionable reads an id it cannot resolve as UNSATISFIED — so the
      // dependent would sit queued, undrivable and non-terminal forever, which is
      // the deadlock this whole path exists to end.
      if (deps.length > 0) item.dependsOn = deps; else delete item.dependsOn;
      const rev = revised.get(i.id);
      if (rev) {
        if (rev.text !== undefined) item.text = rev.text;
        // Empty clears, absent leaves alone — see AmendmentSchema.
        if (rev.condition !== undefined) {
          if (rev.condition === "") delete item.condition; else item.condition = rev.condition;
        }
      }
      // propagateBlocked only ever moves an item TOWARD blocked, so a dependent
      // blocked by the item just removed has nothing left to lift it. Reset, and
      // let the sweep below re-derive it from the dependencies that remain.
      if (item.status === "blocked" && (i.dependsOn ?? []).some((d) => wasBlocking.has(d))) {
        item.status = "queued";
        revived.add(item.id);
      }
      next.push(item);
    }
    // Replaced, not mutated: an earlier emitStatus handed the old array out by
    // reference, and absorbTransitions keeps the same discipline.
    s.backlog = propagateBlocked(next);
    // The judge's justification goes only where the revive actually held. An item
    // the sweep put straight back to `blocked` on a dependency that SURVIVED is
    // still in the state that reason describes, and the row renders `outcome` as
    // its subtitle — clearing it there leaves the row saying blocked with nothing
    // under it, and nothing regenerates one until some later transition does.
    for (const item of s.backlog) {
      if (!revived.has(item.id) || item.status === "blocked") continue;
      delete item.outcome;
      delete item.evidence;
    }
    // The list the last verdict was reached against is not the list any more, so
    // the staleness guard must not skip the pass that reads the new one.
    s.lastJudgedContextHash = undefined;

    const described = describeAmendments(changes);
    // The user did not tap Delete, and the drawer may not even be open: without
    // this row an item they wrote stops existing with nothing anywhere saying so,
    // and the feed is what they read to reconstruct the hours they were away.
    this.record(terminalId, "instruction_amended", described.reason, described.detail);
    this.persist(terminalId, s, true);
    this.emitStatus();
    return changes.length;
  }

  /**
   * The one end state an amendment can leave behind that nothing else resolves:
   * an armed session watching an empty list.
   *
   * `allTerminal` refuses to call an empty backlog terminal — the user is asked
   * rather than handed a wrap-up reporting that nothing was accomplished — so
   * the session can never wrap up, keeps spending a judge pass on every terminal
   * event, and has nothing to drive. Reachable before this only by arming with no
   * goal, which the user chose and can see; "forget all of that" against a short
   * list reaches it in one ordinary sentence that reads as having worked.
   */
  private escalateIfEmptied(terminalId: string, s: ArmedSession): void {
    if (s.backlog.length > 0) return;
    this.escalate(terminalId, s, {
      decision: "escalate", confidence: 0,
      reason: "that took the last item off the backlog",
      notify: {
        title: "Handler",
        body: "Nothing left to work through — add an instruction or disarm Handler",
        draftReply: "", urgency: "normal",
      },
    });
  }

  // The one path items reach the backlog by. Everything the extractor is not
  // allowed to own — ids, status, createdAt — is decided here, after the spawn.
  private appendItems(terminalId: string, s: ArmedSession, extracted: ExtractedItem[]): void {
    // The extraction await yielded the event loop; a concurrent disarm or
    // terminal-exit may have dropped or replaced this session, and appending
    // would re-persist a session the user stopped as armed. An auto-wrap-up
    // reaches here the same way, and there the user has already been pushed
    // "done" — so the lost instruction leaves no other trace at all.
    if (this.sessions.get(terminalId) !== s) {
      log.warn("handler dropped %d extracted item(s) for %s: session no longer armed",
        extracted.length, terminalId);
      return;
    }

    const room = Math.max(0, MAX_BACKLOG_ITEMS - s.backlog.length);
    const kept = extracted.slice(0, room);
    const dropped = extracted.length - kept.length;
    if (dropped > 0) {
      log.warn("handler backlog cap reached for %s: dropped %d item(s)", terminalId, dropped);
      // The bridge's stdout is not a surface the phone can read, and the status
      // snapshot it gets back is byte-identical to the one it already had — so
      // without a feed row the user's instruction vanishes silently.
      this.record(terminalId, "instruction_dropped",
        `backlog is full (${MAX_BACKLOG_ITEMS} items)`, `${dropped} item(s) not tracked`);
    }
    // Nothing appended, so nothing to persist — but the frame still goes out.
    // The app credits its NEXT status frame to every instruction record it
    // retires a "sending" row off (_withOldestPendingRetired,
    // app/lib/services/handler_service.dart), because the two outcomes that ride
    // WITH a frame carry a backlog the retired sentence itself moved. A record
    // with no frame behind it hands that credit to the next sentence's own
    // append instead, and the row it should have retired stands forever. An
    // unchanged snapshot answers for nothing and costs one re-baseline.
    if (kept.length === 0) {
      this.emitStatus();
      return;
    }

    // Minted against the backlog AS IT STANDS NOW, never before the spawn: the
    // backlog may have moved while extraction ran, and a duplicate id leaves the
    // shadowed item unreachable by every transition — so `allTerminal` can never
    // be true again and the session can never wrap up.
    const used = new Set(s.backlog.map((i) => i.id));
    const ids = kept.map(() => {
      let id = this.id("item");
      while (used.has(id)) id = this.id("item");
      used.add(id);
      return id;
    });

    // Refs are resolved after every id exists, because an item may depend on one
    // declared later in the same response. First occurrence wins: a ref names one
    // item, and a dependsOn was written against the first thing to claim it.
    const idByRef = new Map<string, string>();
    kept.forEach((e, n) => { if (!idByRef.has(e.ref)) idByRef.set(e.ref, ids[n]!); });

    const now = this.now();
    // Replaced, not pushed into: an earlier emitStatus handed the old array out
    // by reference, and absorbTransitions keeps the same discipline.
    s.backlog = [...s.backlog, ...kept.map((e, n): InstructionItem => {
      const id = ids[n]!;
      // Intra-batch only, and a ref naming nothing in this batch (or itself) is
      // DROPPED rather than carried through: nextActionable reads an unresolvable
      // dependency id as unsatisfied, so keeping one would strand the item queued,
      // undrivable and non-terminal forever.
      const dependsOn = (e.dependsOn ?? [])
        .flatMap((ref) => { const dep = idByRef.get(ref); return dep && dep !== id ? [dep] : []; });
      return {
        id, text: e.text, status: "queued", createdAt: now,
        ...(dependsOn.length > 0 ? { dependsOn } : {}),
        ...(e.condition ? { condition: e.condition } : {}),
      };
    })];

    // Work the user stacked on an agent that may already be idle: without this the
    // staleness guard would skip the very pass meant to pick the new items up,
    // and no further event would arrive to raise them.
    s.lastJudgedContextHash = undefined;

    // No propagateBlocked: every item here is `queued` with intra-batch deps, so
    // there is nothing to derive. The decide path already runs it each pass.
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  /**
   * `suspended` distinguishes "the runtime went away" from "the user turned
   * supervision off" — see the resume gate in arm(). Only onTerminalExit passes
   * it; a `handler:configure {armed:false}` is the user's own decision and must
   * leave nothing to rehydrate.
   */
  disarm(terminalId: string, opts?: { suspended?: boolean }): void {
    const s = this.sessions.get(terminalId);
    if (!s) return;
    this.sessions.delete(terminalId);
    this.latest.delete(terminalId);
    this.queuedPrompts.delete(terminalId);
    this.unparkIfParked(terminalId, s);
    this.persist(terminalId, s, false, opts?.suspended);
    this.guard.reset(terminalId);
    this.emitStatus();
  }

  /**
   * A human answered on this terminal. `resolvedPromptId` marks the caller as a
   * chat resolve RPC (`agent:permission-resolve` / `-question-resolve`) and names
   * the prompt it answered — the only thing that retires a `resolve_in_session`
   * row, see the clearing rule below.
   */
  onUserReply(terminalId: string, data: string, opts?: { resolvedPromptId?: string }): void {
    // Called per terminal:input — every keystroke, and once the agent enables mouse
    // tracking a report per pointer event — so nothing below may run until the frame
    // is known to be a human ANSWER. `guard.reset` drops the consecutive cap AND the
    // circular-reply hashes, so resetting on a pointer move would hand an armed
    // session an unbounded auto-reply budget for the price of moving the mouse; the
    // rest of the body costs one disk write plus one encrypted status broadcast per
    // byte.
    //
    // The test is the SUBMIT rule, not "contains a newline": alt+enter (`\x1b\r`)
    // and a pasted multi-line blob both carry a CR that submits nothing — the app
    // strips a paste's trailing CR on purpose, so "git status" copied off a web
    // page does not auto-run (see _sanitizePaste in terminal_view_wrapper.dart) —
    // and the agent stays blocked on whatever it asked. Escalations never
    // supersede, so a row cleared by an unsubmitted line drops the session to
    // "watching" and nothing re-raises it: escalation needs a NEW event, and a
    // blocked agent emits none. The bare `"\r"` agent-core.ts sends for an
    // app-routed prompt/resolve IS a submit, which is why the rule is the
    // submitting CR and not typed content — an answer given from the app carries
    // none of the latter.
    if (!isSubmitKeystroke(data)) return;
    // Above the session lookup, so a terminal with no live session still has its
    // guard state reclaimed.
    this.guard.reset(terminalId);
    const s = this.sessions.get(terminalId);
    if (!s) return;
    // A submitted line ordinarily reaches the transcript and moves the hash by
    // itself; cleared anyway because the two are written by different processes
    // and the guard must never be the reason a human's own instruction goes
    // unjudged.
    s.lastJudgedContextHash = undefined;
    // A human at the keyboard ends a park — before the nothing-changed
    // early-return below, which a parked session normally satisfies.
    const unparked = this.unparkIfParked(terminalId, s);
    // Pending escalations clear only on a SUBMITTED line — a stray keypress must
    // not silently swallow an unanswered question — and a submit clears every row
    // that a line can actually answer: once a human line reaches the agent, each
    // earlier free-text pause-question for this terminal is stale (each pause
    // supersedes the last).
    //
    // A `resolve_in_session` row is not one of those. It names an option-based
    // prompt that only the chat resolve RPC can answer (see OpenEscalationWire.kind),
    // so a typed line retires nothing: clearing it would drop the session to
    // "watching" while the agent stays blocked, and nothing would re-raise it —
    // escalation needs a NEW event, and a blocked agent emits none.
    //
    // A `guard_blocked` row is not one either, for the opposite reason: it reports
    // an action Handler could NOT take, so there is no pause for a later one to
    // supersede and nothing a typed line could be an answer to. Clearing it is
    // exactly how a report reached disk and then vanished on an unrelated line,
    // leaving the user never knowing Handler had wanted to act. `handler:dismiss`
    // is the only thing that retires one.
    //
    // A `nonBlocking` row is not one either, and for a third reason. It is a
    // question Handler put to the USER, raised on a pass that had already replied
    // to the agent — so it is not a stale pause waiting to be superseded, and the
    // line the user types is aimed at the AGENT, not at it. Retiring it here would
    // consume an answer to a different question. What DOES retire one: an
    // escalationId-bearing handler:answer or handler:instruct (the answer itself),
    // a dismiss, or reconcileAsks finding nothing left that it did not gate.
    //
    // A resolve retires the row for the prompt it names, plus any row too old to
    // carry an id at all. Never every row: drivers hold a MAP of pending prompts
    // (parallel tool calls open two at once), and dropping the sibling's row would
    // be the same silently-blocked session by another route.
    const resolved = opts?.resolvedPromptId;
    // Same race onPromptRetracted handles, by the other route: a prompt still waiting
    // on its judge call has no escalation row yet, so the filter below cannot reach it
    // and claimQueuedPrompt would mint a `resolve_in_session` row for a prompt the user
    // already answered — one nothing can ever retire, since the resolve that would name
    // it has been and gone.
    if (resolved !== undefined) this.dropQueuedPrompts(terminalId, resolved);
    // The ask clause is FIRST and outside the kind tests on purpose: an ask is
    // minted kind `reply` and carries no `promptId`, so a future restructuring of
    // the resolve arm around `promptId` rather than `kind` would swallow it.
    // Spelled truthily to match the field's polarity — a row an older
    // bridge stripped the flag from and re-persisted falls into the drop arm,
    // which is the conservative reading.
    const kept = s.escalations.filter((e) => e.nonBlocking
      || e.kind === "guard_blocked"
      || (e.kind === "resolve_in_session"
        && (resolved === undefined || (e.promptId !== undefined && e.promptId !== resolved))));
    const cleared = kept.length < s.escalations.length;
    // A human line is a fresh attempt, so the failure series that led here is
    // over. Without this the counters stay at their ceiling — only a judged turn
    // clears transientFailures — and the very next failure would page again
    // instead of backing off.
    //
    // Above the early return, because that reason was always about the human line
    // and never about which rows it happened to clear — the coupling was
    // incidental, which is why `guard.reset` and the hash clear already sit here.
    // It therefore now also fires on a session standing only on an ask, and on
    // one with no rows at all. The persist and the broadcast stay behind the
    // gate, so the per-keystroke disk write and encrypted fan-out are unchanged;
    // what a restart loses is a counter a fresh process starts at zero anyway.
    s.transientFailures = 0;
    s.limitParks = 0;
    if (!unparked && !cleared) return;
    s.escalations = kept;
    s.state = restingState(s);
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  /**
   * The user cancelled the turn from the app. A self-resuming park deliberately
   * arms no timer — the driver's own retry loop is the wake path — but a cancel
   * ends that loop without a `limit_cleared`, so nothing else would ever end the
   * park and the session would sit "PARKED · UNTIL 14:05" long past 14:05.
   * Unparks only: a cancel is not an answer, so pending escalations stand.
   */
  onTurnCancelled(terminalId: string): void {
    const s = this.sessions.get(terminalId);
    if (!s) return;
    if (!this.unparkIfParked(terminalId, s)) return;
    this.persist(terminalId, s, true);
    this.record(terminalId, "resumed", "turn cancelled");
    this.emitStatus();
  }

  /**
   * A driver withdrew a pending permission/question (agent:request-retracted):
   * the forced escalation now points at a prompt that no longer exists. Retires
   * that row — unlike a typed line, a retraction means the prompt is genuinely
   * gone, so nothing can still be waiting on it — but WITHOUT resetting the
   * runaway guard: retraction is the agent moving on, not a human answering.
   *
   * Scoped to `promptId` because drivers withdraw one at a time: codex keys its
   * retractors per JSON-RPC request, so cancelling one elicitation leaves every
   * other prompt on that session live. Clearing the list wholesale took their
   * rows with it and rested the session at "watching" over a blocked agent.
   *
   * No id means the whole set is gone — both wire fields are optional, and
   * work-status.ts's `closeRequest` reads an id-less retraction the same way.
   */
  onPromptRetracted(terminalId: string, promptId?: string): void {
    // Before the session lookup, and never against `latest`: a prompt can still
    // be waiting behind an earlier slow judge call when the retraction lands, and
    // it must not escalate on dequeue for a prompt the driver already took back.
    // Drivers send agent:turn-end and then retract synchronously in the same
    // stack (claude's endActiveTurnOnFailure/onResult, codex's turn-complete
    // handler), so anything that reached into `latest` here would swallow the
    // turn_end queued microseconds earlier — leaving an armed session watching a
    // dead agent on exactly the case turn_end-on-error exists to catch.
    this.dropQueuedPrompts(terminalId, promptId);
    const s = this.sessions.get(terminalId);
    if (!s) return;
    // Before the no-op return: a parked session normally has no escalations at
    // all, so an unpark placed after it would be dead code.
    const unparked = this.unparkIfParked(terminalId, s);
    // An id-less retraction means every PROMPT is gone. A `guard_blocked` row is
    // not a prompt — it carries no promptId, so the id-ed arm already keeps it,
    // and no driver ever had anything to withdraw. Neither is an ask: it is a
    // question Handler put to the USER, held by nothing in the agent's runtime,
    // so there is nothing here for a driver to take back.
    const kept = promptId === undefined
      ? s.escalations.filter((e) => e.kind === "guard_blocked" || e.nonBlocking)
      : s.escalations.filter((e) => e.promptId !== promptId);
    if (!unparked && kept.length === s.escalations.length) return;
    s.escalations = kept;
    s.state = restingState(s);
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  // Ends a park without recording anything: the caller (human input, a blocking
  // prompt, disarm) is itself the reason the wait is over.
  private unparkIfParked(terminalId: string, s: ArmedSession): boolean {
    if (s.state !== "parked") return false;
    this.timers.cancel(terminalId);
    s.state = restingState(s);
    s.parkKind = undefined;
    s.parkedUntil = undefined;
    s.selfResuming = undefined;
    s.parkPushSent = undefined;
    s.retryEvent = undefined;
    s.parkAwaitingJudge = undefined;
    return true;
  }

  /**
   * A terminal died. Reclaim its guard and pending state, and disarm — a
   * runtime that is gone cannot be supervised.
   *
   * Persisted as SUSPENDED, not plainly disarmed: the session slot outlives its
   * PTY (reopening it reuses the id), so the backlog and any unanswered
   * escalation must survive to the next arm. Without that, every host shutdown
   * silently emptied the session it was supposed to preserve.
   *
   * `keepArmed` is for a session:set-mode flip, where the runtime is being
   * swapped underneath a session that itself survives. The supervisor is keyed
   * by session id, so disarming there would answer "I changed how I'm viewing
   * this" with "your supervision is off" — a status flap the user never asked
   * for, on a session that never stopped being supervised.
   */
  onTerminalExit(terminalId: string, opts?: { keepArmed?: boolean }): void {
    this.guard.reset(terminalId);
    if (!this.sessions.has(terminalId)) return;
    if (opts?.keepArmed) return;
    this.disarm(terminalId, { suspended: true });
  }

  // Tack work onto the terminal's chain. A prior item's rejection must not block
  // later ones, so it is swallowed before ours runs.
  private enqueue(terminalId: string, run: () => Promise<void>): Promise<void> {
    const prev = this.chains.get(terminalId) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(run);
    this.chains.set(terminalId, next);
    const done = () => { if (this.chains.get(terminalId) === next) this.chains.delete(terminalId); };
    next.then(done, done);
    return next;
  }

  handleEvent(evt: HandlerEvent): Promise<void> {
    // At dequeue time, run only if this is still the newest event for the
    // terminal — anything superseded while waiting is dropped, not judged.
    //
    // Lifecycle events sit outside that rule entirely: a limit_hit and a later
    // turn_end mean different things, so neither may supersede the other. They
    // still ride the chain, so they cannot race a judge call already in flight.
    //
    // Blocking prompts sit outside it for the same reason: an agent can be
    // stopped on two at once — every driver holds a MAP of pending ones, and
    // work-status.ts models them as a set per session — so a second prompt is
    // another question, not a fresher reading of one state. Superseding left the
    // agent blocked on a prompt with no row, no push, and no further event to
    // raise it again. Retraction is what takes a prompt off the chain instead.
    const lifecycle = isLifecycle(evt);
    const blocking = isBlockingPrompt(evt);
    if (!lifecycle && !blocking) this.latest.set(evt.terminalId, evt);
    if (blocking) this.trackQueuedPrompt(evt);
    return this.enqueue(evt.terminalId, async () => {
      const live = blocking
        ? this.claimQueuedPrompt(evt)
        : lifecycle || this.latest.get(evt.terminalId) === evt;
      if (live) await this.handleEventInner(evt);
    });
  }

  private trackQueuedPrompt(evt: HandlerEvent): void {
    const queued = this.queuedPrompts.get(evt.terminalId) ?? new Set<HandlerEvent>();
    queued.add(evt);
    this.queuedPrompts.set(evt.terminalId, queued);
  }

  // Whether this prompt is still worth escalating. A retraction that arrived
  // while it waited has already removed it, which is what stops a withdrawn
  // prompt from becoming a "needs you" row nothing can ever answer.
  private claimQueuedPrompt(evt: HandlerEvent): boolean {
    const queued = this.queuedPrompts.get(evt.terminalId);
    if (!queued?.delete(evt)) return false;
    if (queued.size === 0) this.queuedPrompts.delete(evt.terminalId);
    return true;
  }

  private dropQueuedPrompts(terminalId: string, promptId?: string): void {
    const queued = this.queuedPrompts.get(terminalId);
    if (!queued) return;
    if (promptId === undefined) queued.clear();
    else for (const evt of queued) if (evt.promptId === promptId) queued.delete(evt);
    if (queued.size === 0) this.queuedPrompts.delete(terminalId);
  }

  private async handleEventInner(evt: HandlerEvent): Promise<void> {
    const s = this.sessions.get(evt.terminalId);
    if (!s) return; // unarmed session: Handler is per-session now

    // The agent produced an event, so whatever was injected into it is no longer
    // outstanding. Cleared here rather than on any one decision branch, and before
    // any judge work: every event answers the question this flag asks, including
    // the ones that return early below, and a flag nothing clears would leave every
    // later answer waiting on a turn_end that has already been and gone.
    s.awaitingAgent = undefined;

    // Before every early return below, for the same reason the clear above is: a
    // standing ask's claim about what the work is getting on with is re-checked
    // against the backlog on every event, not only on the ones that reach a judge.
    this.reconcileAsks(evt.terminalId, s);

    // The second read of the same predicate, and what actually bounds the
    // revocation lag to the token's 3600s TTL — gating only at arm() would make
    // it the armed session's lifetime instead. Suspend rather than return
    // quietly: an armed row that silently never acts is worse than no row, and
    // `suspended` (not a plain disarm) is what a host shutdown uses, so the goal
    // and backlog survive for a re-arm once the subscription is back.
    if (!this.entitledForHandler(evt.terminalId, "event")) {
      this.disarm(evt.terminalId, { suspended: true });
      return;
    }

    if (isLifecycle(evt)) return this.handleLifecycle(evt, s);

    if (s.state === "parked") {
      // A parked session spends no judge call: during a limit window the judge
      // usually shares the provider account and would fail anyway. Blocking
      // prompts are the exception — an agent asking a question is demonstrably
      // past its limit, and wake rules trump a park.
      const blocking = isBlockingPrompt(evt);
      if (!blocking && !s.selfResuming) return;
      this.unparkIfParked(evt.terminalId, s);
      if (!blocking) {
        this.persist(evt.terminalId, s, true);
        this.record(evt.terminalId, "resumed", "agent resumed on its own");
        this.emitStatus();
      }
    }

    // Structured blocking prompts (permission / AskUserQuestion) are option-
    // based: the judge only emits free text, and auto-approving a tool call
    // would bypass the destructive floor (it inspects reply text, not the
    // pending call). Forced escalation, no judge — wake-rules trump handling.
    if (isBlockingPrompt(evt)) {
      const subject = evt.detail?.trim();
      const body = evt.event === "permission_request"
        ? `Agent requests permission${subject ? `: ${subject}` : ""}`
        : `Agent asks${subject ? `: ${subject}` : " a question"}`;
      this.escalate(evt.terminalId, s, {
        decision: "escalate", confidence: 1, reason: "blocking prompt requires you",
        notify: { title: "Handler", body, draftReply: "", urgency: "high" },
      }, undefined, undefined, "resolve_in_session", evt.promptId);
      return;
    }

    s.state = "handling";
    this.emitStatus();

    // Scoped to the judge itself: a judge that could not run is a transient
    // outage, not a verdict, so it parks and re-judges this same event later.
    // The act-on-decision body below keeps its own catch — parking there would
    // re-judge a decision that was already made and acted on.
    let decision: HandlerDecision | null;
    // Assigned only once the pass is known to be worth judging, and banked only
    // after a verdict comes back: a judge outage parks and re-runs THIS event, so
    // banking the hash up front would make the retry skip the pause it exists to
    // re-judge.
    let judgedHash: string | undefined;
    // Read once, before the judge runs, and reused by the handle branch below: the
    // membership rule must be checked against the catalog the judge was actually
    // shown, not one a driver re-published while it was thinking.
    let catalog: CapCommand[] | undefined;
    // The material this pass's judge was shown, and the only corpus a citation can
    // be checked against. Declared out here for the same reason `catalog` is: the
    // gate below must grade the evidence against what the judge actually read, not
    // against whatever the terminal has scrolled to since.
    let judgedContext = "";
    // The park row is the only durable record of a judge that could not answer, and
    // "timed out" versus "never ran" is the one distinction that would let the
    // budget in judge.ts be set from data rather than guessed at.
    let judgeTimedOut = false;
    try {
      const tool = this.deps.tool(evt.terminalId);
      catalog = this.deps.adapter.commandCatalog(evt.terminalId);
      const transcriptPath = evt.transcriptPath ?? this.deps.adapter.transcriptPath(evt.terminalId);
      const ctx = await assembleContext({
        tool, transcriptPath,
        agentSessionId: this.deps.agentSessionId?.(evt.terminalId),
        recentPty: await this.deps.adapter.recentOutput(evt.terminalId),
        recentKind: this.deps.adapter.outputKind(evt.terminalId),
        purpose: "decide",
      });
      judgedContext = ctx.text;
      // Nothing has happened since the last pass reached a verdict, so a second
      // judge call can only re-rule on evidence already ruled on — and a judge
      // that answers differently the second time is answering from noise. Skipped
      // silently: a duplicate row would say the same thing the open one already says.
      const hash = contextHash(ctx.text);
      if (hash === s.lastJudgedContextHash) {
        // assembleContext awaited the filesystem; a concurrent disarm may have
        // dropped this session, and resting it would re-persist it as armed.
        if (this.sessions.get(evt.terminalId) === s) {
          s.state = restingState(s);
          this.emitStatus();
        }
        return;
      }
      judgedHash = hash;
      // One retry, spent INSIDE the judge call so it shares that call's total budget
      // and structurally cannot wrap the destructive floor or the runaway guard —
      // those are safety verdicts, and a retry loop around them is a bypass. Only
      // rules the prompt states are retried; a catalog miss is not one of them.
      const retryIfShape = (d: HandlerDecision): string | null => {
        if (d.decision !== "handle") return null;
        const r = checkReplyShape(replyShape(d), catalog);
        return r?.retryable ? r.reason : null;
      };
      const runDecisionFn = this.deps.runDecisionFn ?? defaultRunDecision;
      decision = await runDecisionFn({
        tool: s.judgeTool ?? tool, model: s.judgeModel, goal: s.goal,
        personality: s.personality ?? DEFAULT_PERSONALITY,
        backlogText: renderBacklog(s.backlog),
        context: ctx.text, transcriptPath: ctx.transcriptPath ?? transcriptPath,
        cwd: this.deps.projectPath(evt.terminalId),
        floorWarnings: s.floorWarnings,
        evidenceRejections: s.evidenceRejections.map((r) => r.line),
        // Read off the live guard, so it is never stored on the session and never
        // persisted. It is honest only in one direction: it is taken BEFORE the
        // judge runs, while absorbTransitions calls guard.recordProgress after it
        // on any `done`, so a prompt that said "1 left" can be followed by a fully
        // restored cap in the same pass. That direction only ever makes the judge
        // under-spend, which is why the prompt states a floor and never a promise.
        replyBudget: this.guard.remaining(evt.terminalId),
        // The SUPERVISED agent, not the judge: `tool:` above is `s.judgeTool ?? tool`,
        // and a per-session judge pick can name a different CLI entirely.
        agentTool: tool,
        commands: catalog,
        retryIfShape,
        onTimeout: () => { judgeTimedOut = true; },
      });
    } catch {
      if (this.sessions.get(evt.terminalId) === s) this.onJudgeUnavailable(evt, s);
      return;
    }

    // The judge await yields the event loop; a concurrent disarm/terminal-exit may
    // have dropped or replaced this session. Never inject into a session the user
    // stopped mid-judge — supervise-safely boundary.
    if (this.sessions.get(evt.terminalId) !== s) return;

    if (!decision) return this.onJudgeUnavailable(evt, s, judgeTimedOut ? "judge timeout" : undefined);

    // A judge that answered proves the provider is serving us again.
    s.transientFailures = 0;
    s.limitParks = 0;
    s.lastJudgedContextHash = judgedHash;

    // A rejection must not strand state in "handling" — reset before rethrowing so
    // the next event isn't ignored and the app's status pill reflects reality.
    try {
      this.absorbTransitions(evt.terminalId, s, decision, judgedContext, catalog);
      // Wrap-up is checked AFTER acting on the decision (see each branch below):
      // a final `handle` reply must reach the agent before disarm, and an
      // escalation never wraps up — wake-rules trump completion.

      if (decision.decision === "handle") {
        // Every shape rule lives in reply-shape.ts because the judge is re-asked
        // against the SAME function (see retryIfShape above): a rule the retry teaches
        // but this gate does not enforce — or the reverse — is the exact failure this
        // path exists to end.
        const shape = replyShape(decision);
        const rejection = checkReplyShape(shape, catalog);
        // forcedReason only: floorRule is the HARD floor's alone, and setting it
        // here would suppress the escalation card's one-tap choices.
        //
        // `guard_blocked`, like the two rejections below it: this row reports an
        // action Handler wanted to take and a harness guard refused, so no later
        // pause supersedes it and a typed line is not an answer to it. Every OTHER
        // escalate() call site in this file is a question about the AGENT and keeps
        // its kind.
        if (rejection) {
          return this.escalate(evt.terminalId, s, decision, rejection.reason, undefined, "guard_blocked");
        }

        // The probe is the whole command line — args included — because that is what
        // reaches the agent, and what the runaway guard must hash to notice a repeat.
        const probe = `${shape.reply}\n${shape.actionText}`;
        // The path check gets the reply plus the ARGUMENT TAIL and never the verb: the
        // VERB rule checkReplyShape just applied forbids both path separators inside a
        // verb, while an absolute path in the args is a real one the floor has to see.
        const pathText = `${shape.reply}\n${shape.args}`;

        // The floor's ONE call site. It inspects the text Handler is
        // about to inject, never the commands the agent goes on to run.
        const projectPath = this.deps.projectPath(evt.terminalId);
        const floor = classifyDestructive(probe, projectPath, pathText);
        // Checked before the partition, and never against it: the HARD tier is
        // liftable by nothing, so no instruction can reach this branch.
        if (floor.hard.length > 0) {
          const reason = describeWarning(floor.hard[0]!);
          return this.escalate(evt.terminalId, s, decision, `floor: ${reason}`, reason, "guard_blocked");
        }
        // What the user's own instructions already authorized drops out of the
        // warning stream. It stays a separate list rather than being filtered away
        // because an authorized action is still snapshotted — the snapshot pass
        // reads `authorized` here, alongside `warn`.
        const { warn, authorized } = partitionWarnings(s.auth, floor.warnings, probe, projectPath);

        const guardReason = this.guard.check(evt.terminalId, probe);
        if (guardReason) {
          return this.escalate(evt.terminalId, s, decision, guardReason, undefined, "guard_blocked");
        }

        if (authorized.length > 0) {
          log.info("handler floor: %d warning(s) authorized by instruction for %s",
            authorized.length, evt.terminalId);
        }
        // The reason the floor can afford to be advisory: prepare the undo
        // BEFORE the agent is told to do the thing. Authorized warnings count here —
        // a lift drops the warning, never the safety net ("I asked for it" is not the
        // same as "I wanted that exact result").
        const snapshots = warn.length + authorized.length > 0
          ? await this.prepareSnapshots(evt.terminalId, shape.written)
          : [];
        // The snapshot pass awaits git and the filesystem; a concurrent disarm may
        // have dropped this session, and injecting into one the user stopped is the
        // boundary this whole file is built around. A reply that was never sent has
        // nothing to undo, so what was captured is released here rather than stored:
        // it never reached the store, so no later retire can see it, and a backup ref
        // left behind pins its stash commit against `git gc` for the life of the repo.
        if (this.sessions.get(evt.terminalId) !== s) {
          this.releaseEntries(snapshots.flatMap((o) => (o.status === "snapshotted" ? [o.entry] : [])));
          return;
        }

        // A catalog hit routes on the driver's own command id, so a chat transport
        // sends the argument tail alone; a PTY ignores it and types the whole line.
        // A miss against an AVAILABLE catalog never gets here (checkReplyShape
        // escalated it); a session with no catalog degrades to plain text, which the
        // agent rejects visibly rather than the supervisor refusing in advance.
        const command = findCommand(catalog, shape.verb);
        this.deps.adapter.injectReply(evt.terminalId, shape.written,
          command ? { id: command.id, args: shape.args } : undefined);
        // AFTER the inject and never before it: this claims a reply is genuinely
        // outstanding, and an answer that arrives while it is set waits for the
        // agent's turn_end instead of re-entering (see maybeRelayNow). Setting it
        // ahead of a reply that then failed to go out would strand every answer on
        // this session until some other event happened to arrive.
        s.awaitingAgent = true;
        // The first `handle` after an answer is where that answer stops being
        // unrelayed: the judge held it in this pass's prompt and the reply it
        // composed has just reached the agent. Deliberately not cleared on
        // `continue` or `escalate` — a pass that relayed nothing leaves an answer
        // that is still true and still owed to the agent.
        s.askAnswer = undefined;
        this.guard.recordAutoReply(evt.terminalId, probe);
        // Both recorded after the inject and before the handle row, so the feed reads
        // as "what was saved, what was flagged, then what was sent". Auditability is
        // what prevention was traded for, so nothing here is conditional on the
        // Assistant's own view of the risk.
        this.recordSnapshots(evt.terminalId, s, snapshots, [...warn, ...authorized]);
        this.noteFloorWarnings(evt.terminalId, s, warn);
        this.record(evt.terminalId, "handle", decision.reason, shape.written);
        // Raised only here. Every guard above returns before this line — the shape
        // rejection, the HARD floor, the runaway cap — so a row that says the work
        // went on is one written after the reply provably reached the agent. That
        // injected reply is also what schedules the pass which follows: the agent's
        // own turn_end arrives on the paths agent-core already owns, the transcript
        // has moved so contextHash differs, and nothing here arms a timer or clears
        // the hash.
        //
        // The position is load-bearing in both directions and a later edit must
        // keep it: after the concurrent-disarm recheck above (a session the user
        // stopped mid-pass must gain no row), and before maybeWrapUp (which must
        // see the row, so a pass that both finishes the backlog and asks cannot
        // disarm out from under the question).
        if (decision.ask) this.raiseAsk(evt.terminalId, s, decision.ask);
        if (this.maybeWrapUp(evt.terminalId, s)) return;
        s.state = restingState(s);
        this.persist(evt.terminalId, s, true);
        this.emitStatus();
        return;
      }

      if (decision.decision === "continue") {
        // Neither this branch nor the escalate below sends the agent anything, so a
        // question marked "the work goes on" would sit over a session with no
        // further event to raise it again — the exact state the ask shape exists to
        // make unspellable.
        if (decision.ask) {
          log.warn("handler ask ignored on %s decision for %s", decision.decision, evt.terminalId);
        }
        this.record(evt.terminalId, "continue", decision.reason);
        if (this.maybeWrapUp(evt.terminalId, s)) return;
        s.state = restingState(s);
        this.persist(evt.terminalId, s, true);
        this.emitStatus();
        return;
      }

      // escalate: deliberately no wrap-up check — an escalation raised on the
      // same pass that completed the backlog stays pending for the human;
      // auto-disarming would bury the question.
      //
      // An `ask` here is ignored for the reason the continue branch states: this
      // pass replies to nobody, so the row would have no event to raise it again.
      if (decision.ask) {
        log.warn("handler ask ignored on %s decision for %s", decision.decision, evt.terminalId);
      }
      this.escalate(evt.terminalId, s, decision);
    } catch (err) {
      // A wrap-up (or a concurrent disarm) may already have dropped this
      // session; resetting its state here would re-persist it as armed.
      if (this.sessions.get(evt.terminalId) === s) {
        s.state = restingState(s);
        this.emitStatus();
      }
      throw err;
    }
  }

  // Lifecycle events state a fact about the provider, never a verdict about the
  // supervised work: they park or resume. Only the transient ceiling escalates.
  private handleLifecycle(evt: HandlerEvent, s: ArmedSession): void {
    if (evt.event === "limit_cleared") {
      // Read before the unpark clears them: the provider coming back says
      // nothing about a pause a judge still owes a verdict on.
      const retry = s.retryEvent;
      if (!this.unparkIfParked(evt.terminalId, s)) return;
      this.persist(evt.terminalId, s, true);
      this.record(evt.terminalId, "resumed", "provider limit cleared");
      this.emitStatus();
      // Re-judge rather than resume unsupervised — otherwise a limit that
      // clears mid-backoff silently forgets the pause nobody ever assessed.
      // Nothing awaits a lifecycle event, so the re-judge carries its own sink.
      if (retry) void this.handleEvent(retry).catch(() => {});
      return;
    }

    if (evt.event === "limit_hit") {
      // Floored: a detector can hand us a reset time already in the past (a
      // stale snapshot, clock skew), and a park expiring on arrival would nudge
      // straight back into the failure that caused it.
      const until = Math.max(
        evt.resetsAt ?? this.now() + LIMIT_FALLBACK_MS,
        this.now() + MIN_PARK_MS,
      );
      // A repeat limit_hit is the same wait with a fresher deadline: refresh it,
      // but don't re-announce a park the user was already told about.
      const refresh = s.state === "parked" && s.parkKind === "limit";
      // Each NEW limit episode is a wait that did not work — the last one ended
      // and the limit came straight back. A refresh is the same wait, so it does
      // not count. Past the ceiling, waiting is no longer the answer.
      if (!refresh && ++s.limitParks >= LIMIT_PARK_CEILING) {
        const unparked = this.unparkIfParked(evt.terminalId, s);
        // One unanswered question is enough: until the user responds, every
        // further limit says the same thing.
        if (pendingQuestions(s) === 0) {
          this.escalate(evt.terminalId, s, {
            decision: "escalate", confidence: 0, reason: "provider limit outlasted repeated waits",
            notify: {
              title: "Handler", body: "Agent needs you (the provider limit keeps returning)",
              draftReply: "", urgency: "normal",
            },
          });
        } else if (unparked) {
          this.persist(evt.terminalId, s, true);
          this.emitStatus();
        }
        return;
      }
      this.enterPark(evt.terminalId, s, {
        kind: "limit", until, selfResuming: evt.selfResuming, retryEvent: s.retryEvent,
      });
      if (!refresh) {
        this.record(evt.terminalId, "parked", evt.errorClass ?? "usage limit", new Date(until).toISOString());
        if (!s.parkPushSent) {
          s.parkPushSent = true;
          this.deps.sendPush?.(`Handler: paused until ${wakeClock(until)} — resuming automatically`, evt.terminalId);
        }
      }
      this.emitStatus();
      return;
    }

    // turn_failed. A park already represents waiting, so a failure arriving
    // mid-park is dropped: counting it would shorten a limit window into an
    // outage backoff and spend the ceiling on a wait we chose. The counter
    // measures post-resume failures.
    if (s.state === "parked") return;
    this.registerTransientFailure(evt, s);
  }

  private registerTransientFailure(evt: HandlerEvent, s: ArmedSession, retryEvent?: HandlerEvent): void {
    s.transientFailures += 1;
    if (s.transientFailures >= TRANSIENT_CEILING) {
      // The one lifecycle outcome that IS a decision, so it goes through the
      // normal escalation path and the phone gets an answerable row. Every
      // driver burns its own retry budget first, so three of these in a row
      // means the blip was not a blip. The counter stays at the ceiling until a
      // judged turn or a human line clears it — so escalate only while no
      // question is already pending, or a stuck judge would append an identical
      // row (and a push) on every single failure from here on.
      if (pendingQuestions(s) === 0) {
        this.escalate(evt.terminalId, s, {
          decision: "escalate", confidence: 0, reason: "repeated transient failures",
          notify: {
            title: "Handler", body: "Agent needs you (repeated transient failures)",
            draftReply: "", urgency: "normal",
          },
        });
        return;
      }
      // Suppressing the duplicate row must not also suppress the state move: a
      // judge failure arrives with handleEventInner having already set
      // "handling", and neither the park nor the escalate below runs on this
      // leg — so the pill would report work nobody is doing until the next
      // event happens to land.
      s.state = "needs_you";
      this.persist(evt.terminalId, s, true);
      this.emitStatus();
      return;
    }
    const until = this.now() + transientBackoffMs(s.transientFailures);
    this.enterPark(evt.terminalId, s, { kind: "outage", until, retryEvent });
    this.record(evt.terminalId, "parked", evt.errorClass ?? "transient failure", new Date(until).toISOString());
    this.emitStatus();
  }

  // A judge that could not run says nothing about the agent, so the pause it was
  // asked about is stashed and re-judged after the backoff. Nudging "continue"
  // here would let the agent proceed with no supervision at all.
  private onJudgeUnavailable(evt: HandlerEvent, s: ArmedSession, errorClass = "judge unavailable"): void {
    this.registerTransientFailure({ ...evt, errorClass: evt.errorClass ?? errorClass }, s, evt);
  }

  private enterPark(terminalId: string, s: ArmedSession, p: {
    kind: "limit" | "outage"; until: number; selfResuming?: boolean; retryEvent?: HandlerEvent;
  }): void {
    s.state = "parked";
    s.parkKind = p.kind;
    s.parkedUntil = p.until;
    s.selfResuming = p.selfResuming;
    s.retryEvent = p.retryEvent;
    s.parkAwaitingJudge = p.retryEvent ? true : undefined;
    // A driver that resumes itself needs no timer: our nudge would land in a
    // session that never stopped retrying.
    if (p.selfResuming) this.timers.cancel(terminalId);
    else this.timers.arm(terminalId, Math.max(0, p.until - this.now()), () => this.runParkTimer(terminalId));
    this.persist(terminalId, s, true);
  }

  // Nothing awaits a timer callback, and the wake path writes to disk (the
  // session record, the activity log): an EPERM from an AV scanner holding the
  // .tmp rename, or an ENOSPC, would escape to the event loop as an
  // uncaughtException and take the whole bridge — every project, every PTY, the
  // relay socket — down with one session's expired park.
  private runParkTimer(terminalId: string): void {
    try {
      this.onParkTimer(terminalId);
    } catch (err) {
      log.error("handler park timer failed for %s: %s", terminalId, err);
    }
  }

  private onParkTimer(terminalId: string): void {
    const s = this.sessions.get(terminalId);
    if (!s || s.state !== "parked") return;
    const retry = s.retryEvent;
    const owedJudge = s.parkAwaitingJudge;
    this.unparkIfParked(terminalId, s);
    this.persist(terminalId, s, true);
    this.record(terminalId, "resumed", "park timer elapsed");
    this.emitStatus();
    if (retry) {
      // Nothing awaits a timer callback, so the re-judge carries its own sink;
      // a judge that fails again simply re-parks through the same path.
      void this.handleEvent(retry).catch(() => {});
      return;
    }
    // Same park, rehydrated after a restart that dropped the stashed event: the
    // pause it was waiting on is still unjudged, so resume quietly and let the
    // next real event reach the judge. Nudging would be the supervision bypass
    // the stash exists to prevent.
    if (owedJudge) return;
    // The nudge is an unsupervised submitted line (injectReply appends CR), so
    // it must never land while a question is waiting on the human: it would
    // answer a pending permission prompt on their behalf. The park is over
    // either way — the human is the resume path now. A report answers nothing,
    // so it is not one of those: leaving it in the count would strand every
    // parked session that happened to be holding one. An ask is not one either,
    // and for the sharper version of the same reason — the agent was already
    // working PAST it when the park began, so it holds no prompt for a nudge to
    // answer, and counting it here would strand the session on a question the
    // user was told did not stop the work.
    if (blockingQuestions(s) > 0) return;
    // Straight to the adapter, never through the auto-reply path: the nudge is
    // the supervisor's own recovery action, so it must neither advance the
    // runaway counter nor enter the circular-exchange window — a second park
    // would otherwise write an identical "continue" and false-escalate.
    this.deps.adapter.injectReply(terminalId, "continue");
  }

  // Move backlog items on the evaluator's word — inside the bounds
  // applyTransitions enforces — and count real progress toward the runaway guard:
  // progress is evidence of non-looping.
  private absorbTransitions(
    terminalId: string, s: ArmedSession, decision: HandlerDecision, evidenceCorpus: string,
    catalog?: CapCommand[],
  ): void {
    // The catalog the judge was actually shown, so the anchor asks about the same
    // commands the prompt listed and checkReplyShape would accept.
    const result = applyTransitions(s.backlog, decision.transitions ?? [], this.now(), {
      evidenceCorpus,
      commandNames: catalog?.map((c) => c.name),
      anchorWaived: waivedAnchors(s),
    });
    // A rejection is an attempted invariant violation — a minted id, a terminal
    // move with no evidence, a completed item walked back — and this log is the
    // only place it can surface: the item simply does not move, so no downstream
    // state ever looks wrong. Dropping these silently is how a judge quietly
    // fishing for progress stays invisible.
    for (const r of result.rejected) {
      log.warn("handler transition rejected for %s: %s (id=%s status=%s)",
        terminalId, r.reason, r.transition.id, r.transition.status);
      if (!EVIDENCE_CODES.has(r.code)) continue;
      const item = result.backlog.find((i) => i.id === r.transition.id);
      if (!item) continue;
      // Counted per item, not per session: the waiver answers "this item's token
      // cannot be quoted", which says nothing about the next item's.
      if (r.code === "missing_command_anchor") {
        s.anchorRefusals.set(item.id, (s.anchorRefusals.get(item.id) ?? 0) + 1);
      }
      // A refused completion is the one rejection the user has to be able to see:
      // the item does not move, so the next status snapshot is identical to the
      // last, and a session that will now never wrap up looks exactly like one
      // still working. The log line above reaches nobody who is not tailing it.
      if (!s.evidenceRejected.has(item.id)) {
        s.evidenceRejected.add(item.id);
        this.record(terminalId, "evidence_rejected", item.text, r.reason);
      }
      s.evidenceRejections.push({
        id: item.id, line: `"${oneLine(item.text).slice(0, 80)}" — ${r.reason}`,
      });
      if (s.evidenceRejections.length > MAX_REMEMBERED_REJECTIONS) {
        s.evidenceRejections = s.evidenceRejections.slice(-MAX_REMEMBERED_REJECTIONS);
      }
    }
    // Blocking is derived, never judged: an item is blocked because
    // something it depends on is, which is why it carries no evidence and why the
    // evaluator is not asked for it. Without this call `dependsOn` would be
    // decorative — extracted, rendered, and never acted on.
    const wasBlocked = new Set(result.backlog.filter((i) => i.status === "blocked").map((i) => i.id));
    s.backlog = propagateBlocked(result.backlog);
    const byId = new Map(s.backlog.map((i) => [i.id, i]));
    // The prompt section these feed is headed "those items are still open", and an
    // item can close on a later pass — on a second, better-cited transition. Kept
    // any longer, the section contradicts the BACKLOG block rendered beside it and
    // asks the judge to re-cite work it has already closed.
    s.evidenceRejections = s.evidenceRejections.filter((r) => {
      const item = byId.get(r.id);
      return item !== undefined && !isTerminalStatus(item.status);
    });

    for (const a of result.applied) {
      const kind = ITEM_DECISION[a.item.status];
      // `queued`/`active` say where an item currently sits, which the live status
      // pill already shows; the four kinds below are things that HAPPENED to it,
      // and the feed is a history of those.
      if (kind) this.record(terminalId, kind, a.item.text, a.item.outcome ?? a.item.evidence);
    }
    // A derived block is the one status change with no transition behind it, so
    // it would otherwise move an item with nothing in the feed explaining why.
    const derived = s.backlog.filter((i) => i.status === "blocked" && !wasBlocked.has(i.id));
    for (const i of derived) {
      const on = (i.dependsOn ?? []).flatMap((id) => {
        const dep = byId.get(id);
        return dep && (dep.status === "blocked" || dep.status === "failed") ? [oneLine(dep.text)] : [];
      });
      this.record(terminalId, "item_blocked", i.text, `waiting on: ${on.join(", ")}`);
    }

    if (result.progressed) this.guard.recordProgress(terminalId);
    if (result.applied.length > 0 || derived.length > 0) this.persist(terminalId, s, true);
  }

  // Auto-disarm once every item has reached a terminal state. A `blocked`
  // item is deliberately not one: it is revivable, and the evaluator can still
  // resolve it as `skipped` or `failed` on evidence — which is the deadlock fix,
  // since "correctly did not happen" is now sayable and an unreachable item no
  // longer holds the session open forever.
  // Called only from the handle/continue branches — never on escalate.
  private maybeWrapUp(terminalId: string, s: ArmedSession): boolean {
    // The backlog gate leads, so the question gate below reads a session whose
    // asks have been reconciled against a FINISHED backlog. Ordering the two the
    // other way is observationally identical on its own — both return false — and
    // leaves nowhere to make that claim true.
    if (!allTerminal(s.backlog)) return false;
    // A question is non-blocking because there was other work its answer did not
    // gate. With every item terminal there is none, so the claim has expired and
    // the row goes back to meaning what an unanswered question has always meant.
    // This is the site the per-event one cannot reach: a session whose backlog is
    // finished has no further event coming to re-check it.
    this.reconcileAsks(terminalId, s);
    // A wrap-up disarms the session. Never do that while a human question is
    // outstanding: an earlier escalate may already have banked the transitions
    // that completed the backlog (absorbTransitions runs on every decision,
    // including escalate), so a later handle/continue could otherwise auto-disarm
    // and silently bury the unanswered escalation. An ask needs no re-scope here
    // — it is `kind: "reply"`, so it already counts, and that is the behaviour
    // wanted: a finished backlog must not disarm over a question the user has
    // been asked and has not answered. A `guard_blocked` report is not such a
    // question — nothing is waiting on it — and holding the wrap-up open for one
    // would leave a finished session armed until somebody tapped Dismiss; the
    // record and the push below carry the reports out instead.
    if (pendingQuestions(s) > 0) return false;
    // Reports, not questions — pendingQuestions above is their complement. They
    // are frozen into the record because they die here: `disarm` drops the session
    // and takes `s.escalations` with it, and nothing can re-derive them afterwards.
    const rec = buildWrapUp({
      wrapUpId: this.id("wrap"),
      terminalId,
      at: this.now(),
      goal: s.goal,
      backlog: s.backlog,
      blockedReports: s.escalations.filter((e) => e.kind === "guard_blocked"),
    });
    this.record(terminalId, "wrapped_up", "every backlog item resolved", wrapUpDetail(rec));
    // Persisted BEFORE the disarm: `disarm` ends in emitStatus, and that emit is
    // what carries this record to the app. A save landing after it waits for an
    // unrelated status frame, which on a project whose last session just ended may
    // not come for hours. Caught rather than thrown for the mirror-image reason —
    // the row above is already written, so a full disk must not leave a finished
    // session armed forever. The report is the nice-to-have; the disarm is the
    // contract.
    try {
      this.saveWrapUps([...this.wrapUps(), rec]);
    } catch (err) {
      log.warn("handler wrap-up persist failed for %s: %s", terminalId, err);
    }
    this.deps.sendPush?.(wrapUpPushBody(rec, { openUndos: this.openUndoCount(terminalId) }), terminalId);
    this.disarm(terminalId);
    return true;
  }

  // The wrap-up push is the last thing the user reads about this session, and the
  // session is disarmed by the time they read it — so it is also the last place
  // the undo can be made discoverable before it is needed. Counted here and
  // stored nowhere: an undo taken afterwards, or a re-arm retiring the offers,
  // makes a frozen count a lie on a card whose whole job is to be read later.
  private openUndoCount(terminalId: string): number {
    return this.snapshots().filter((e) => e.terminalId === terminalId && e.undoneAt === undefined).length;
  }

  /**
   * Raise a question for the USER on a pass that has ALREADY replied to the
   * agent. The work goes on and the row waits; nothing here stops the session.
   *
   * Deliberately NOT routed through `escalate()`. That path derives its
   * `draftReply` from `firstFilled(decision.notify?.draftReply, decision.reply,
   * refused)`, so an ask would arrive carrying the line just typed at the agent
   * as the user's own answer to offer back — and it would inherit
   * `quickChoicesFor`, which an ask must not reach (see below).
   */
  private raiseAsk(terminalId: string, s: ArmedSession, ask: DecisionAsk): void {
    if (s.escalations.filter((e) => e.nonBlocking).length >= MAX_OPEN_ASKS) {
      return this.noteAskRejected(terminalId, s, ask, "a question of yours is still unanswered");
    }
    // The only checkable half of "non-blocking". renderBacklog prints every id, so
    // the judge holds them; an ask that names none still open has described an
    // escalation, whatever it claimed.
    const live = new Set(s.backlog.filter((i) => !isTerminalStatus(i.status)).map((i) => i.id));
    if (!ask.unblocked.some((id) => live.has(id))) {
      return this.noteAskRejected(terminalId, s, ask, "named no backlog item that is still open");
    }
    const question = clip(ask.question, MAX_ASK_CHARS);
    if (s.escalations.some((e) => e.nonBlocking && e.question === question)) {
      return this.noteAskRejected(terminalId, s, ask, "the same question is already standing");
    }
    const esc: OpenEscalation = {
      escalationId: this.id("esc"),
      question,
      reasoning: clip(ask.reasoning, MAX_ASK_CHARS),
      // Empty by construction and never derived from the decision. A composer
      // seeded from a judge-authored draft is the one path that reaches
      // authorizeInstruction with text the user did not write, and the ask shape
      // closes it here rather than at each of the sheets that read this field.
      draftReply: "",
      // Never the `high` band: that band is for a row that unblocks a stopped
      // session in one tap, and this row stops nothing.
      urgency: "normal",
      kind: "reply",
      nonBlocking: true,
      unblocked: ask.unblocked.filter((id) => live.has(id) && id.length <= MAX_UNBLOCKED_ID_CHARS),
      // NOT `quickChoicesFor`, and this is a reversal a reader will look for. All
      // three of its gates screen text that is about to be typed into the agent's
      // terminal, and an ask sends the agent nothing: the `resolve_in_session`
      // clause withholds every chip on the premise that injected text cannot reach
      // a stalled agent, the draft clause derives the whole card from a
      // `draftReply` an ask does not have, and the destructive screen is a
      // per-card `classifyDestructive` whose absolute-path sweep would warn on
      // prose that never reaches a shell. Each of them returns undefined for the
      // WHOLE card, silently, so reusing it here would withhold the options on
      // exactly the sessions most likely to be holding a prompt.
      askOptions: this.mintAskOptions(ask),
      at: this.now(),
    };
    this.deps.sendAb(createMessage("handler:escalation", {
      projectId: this.deps.projectId, terminalId, ...escalationWire(esc),
    }));
    s.escalations.push(esc);
    // The existing `escalate` kind, not a new one: the row IS an escalation being
    // raised, and a new activity value would be a fourth hand-mirrored enum
    // (config.ts, protocol.ts, handler_state.dart) for nothing the feed cannot
    // already say — the pass reads as "handle, then escalate".
    this.record(terminalId, "escalate", ask.reasoning, previewForUser(question));
    s.askRejections = [];
  }

  private noteAskRejected(terminalId: string, s: ArmedSession, ask: DecisionAsk, why: string): void {
    s.askRejections = [...s.askRejections, `"${clip(ask.question, 80)}" — ${why}`].slice(-MAX_ASK_REJECTIONS);
    this.record(terminalId, "escalate", `question not raised: ${why}`, previewForUser(ask.question));
  }

  /**
   * The tap options for an ask, minted from the judge's labels.
   *
   * Every bound is enforced here rather than by handing the finished array to a
   * safeParse, because that failure mode is dropping EVERY option: one over-long
   * label would leave the user a question whose card the judge sized for four.
   * Clipping keeps the option and costs a few characters instead, and the schema
   * check at the end is the backstop for whatever clipping cannot fix — even that
   * costs the options and never the question.
   */
  private mintAskOptions(ask: DecisionAsk): OpenEscalation["askOptions"] {
    if (!ask.options) return undefined;
    const minted: NonNullable<OpenEscalation["askOptions"]> = [];
    for (const o of ask.options) {
      // previewForUser ESCAPES control characters rather than stripping them, so it
      // runs BEFORE the clip — escaping afterwards expands the string back over the
      // bound it was just brought under.
      const label = clipWithin(previewForUser(oneLine(o.label)), MAX_ASK_OPTION_LABEL);
      const cost = clipWithin(previewForUser(oneLine(o.cost)), MAX_ASK_OPTION_COST);
      // A label IS the whole payload of a tap and a cost is what the user checks a
      // recommendation against, so an option missing either is not a choice anybody
      // could make. Dropped rather than defaulted: the engine has nothing truthful
      // to put there.
      if (label.trim() === "" || cost.trim() === "") continue;
      minted.push({
        // Engine-authored by position. An id round-trips through the wire and
        // resolves against this persisted row, so it is identity and never
        // authority — nothing the judge writes may become one.
        choiceId: `opt${minted.length + 1}`,
        label,
        cost,
        // First `true` wins and the rest are cleared: two emphasised rows leave
        // every app arbitrating between them, and none of them can.
        ...(o.recommended && !minted.some((m) => m.recommended) ? { recommended: true as const } : {}),
      });
    }
    // Never a one-chip card: a single option is a button that can only say yes.
    // The ask still raises as a free-text question, which is a complete ask rather
    // than a degraded one.
    if (minted.length < 2) return undefined;
    const parsed = OpenEscalationSchema.shape.askOptions.safeParse(minted);
    return parsed.success ? parsed.data : undefined;
  }

  /**
   * Re-check what every standing ask claimed the work was getting on with.
   *
   * `unblocked` is validated once at raise time, so on its own it is a promise
   * about a moment that has passed: the items it named finish, and what is left
   * is an ordinary question the session is waiting on. Run at the top of every
   * pass AND again inside maybeWrapUp, because the second reaches the session the
   * first cannot — one whose backlog is finished has no further event coming.
   */
  private reconcileAsks(terminalId: string, s: ArmedSession): void {
    let changed = false;
    for (const e of s.escalations) {
      if (!e.nonBlocking) continue;
      const before = e.unblocked ?? [];
      // `blocked` counts as NOT running. TERMINAL is {done, skipped, failed}, so a
      // blocked item is formally still open — but it is work that has not moved,
      // and the whole claim the still-working list makes is one the user can check
      // rather than one the row merely asserts.
      const still = before.filter((id) => {
        const item = s.backlog.find((i) => i.id === id);
        return item !== undefined && !isTerminalStatus(item.status) && item.status !== "blocked";
      });
      if (still.length > 0) {
        if (still.length !== before.length) {
          // Assigned, never spliced: escalationWire hands out `{...e}` shallow
          // copies, so every frame already published shares this array by
          // reference and editing it in place would rewrite history.
          e.unblocked = still;
          changed = true;
        }
        continue;
      }
      if (before.length > 0) e.unblocked = [];
      // Cleared TOGETHER and never one without the other. A promoted row that kept
      // its options renders a card with live buttons that answerAsk then refuses,
      // returning before the app can latch anything — no "Sending…", no error,
      // nothing at all, on exactly the overnight path this feature exists to serve.
      e.nonBlocking = undefined;
      e.askOptions = undefined;
      changed = true;
      // No second push. The user was already woken when the question was raised,
      // and a notification saying the same question now matters more is a second
      // interruption for a fact the row itself carries.
      this.record(terminalId, "escalate", "the work your question did not gate has finished");
    }
    // Emitted here rather than left to the caller: this runs before the branches
    // that return early on a stale or parked event, and a promotion the app never
    // sees leaves live buttons on a row this bridge would now refuse.
    if (changed) {
      this.persist(terminalId, s, true);
      this.emitStatus();
    }
  }

  private escalate(
    terminalId: string, s: ArmedSession, decision: HandlerDecision,
    forcedReason?: string, floorRule?: string, kind?: EscalationKind,
    promptId?: string,
  ): void {
    const reason = forcedReason ?? decision.reason;
    const blocked = kind === "guard_blocked";
    // A guard_blocked row is a report about text a guard refused, and `written` is the
    // only artifact that says which field the judge filled — `notify.draftReply`
    // describes the pause to the user and can be prose about neither field. Recomputed
    // rather than threaded down because it is a pure function of the decision, and
    // escalate is reached from call sites that hold no shape.
    const refused = blocked ? replyShape(decision).written : "";
    // Carries the text a harness guard rejected, so the reply sheet can show what
    // Handler wanted to send and let the user edit it down. Safe to pass raw: the wire
    // leaves `draftReply` unconstrained while `EscalationChoiceWire.text` bans control
    // chars and caps length, so `quickChoicesFor` withholds the one-tap chip on exactly
    // the drafts a guard would have refused. A blocked action fills neither of the
    // first two fields, and an empty draft leaves the reply sheet with nothing to
    // edit; the refused text as the last fallback is safe for the same reason —
    // `quickChoicesFor` withholds every chip on a `guard_blocked` card, so it can
    // never become a one-tap re-send.
    const draftReply = firstFilled(decision.notify?.draftReply, decision.reply, refused) ?? "";
    // The activity row is read, never injected, so the control chars that forced some
    // of these escalations are escaped into view rather than written raw into the feed.
    // A blocked row reports the refused text rather than the user-facing draft: the
    // draft is prose about the pause, so a feed built from it cannot say which field
    // the judge filled or what the guard actually turned down.
    const rowText = blocked ? refused : draftReply;
    const detail = rowText === "" ? undefined : previewForUser(rowText);
    // Nothing retires a report but the user, so an identical repeat would cost
    // them a second Dismiss for a situation the standing row already describes in
    // the same words. The feed still gets its row: that Handler was refused AGAIN
    // is the fact worth keeping, and the feed is where it is durable.
    if (blocked && s.escalations.some((e) => e.kind === "guard_blocked"
      && e.reasoning === reason && e.draftReply === draftReply)) {
      this.record(terminalId, "escalate", reason, detail);
      // The three lines the normal path ends with, minus the push and the row.
      // Every guard_blocked call site is a `return this.escalate(...)` out of the
      // handle branch, which set "handling" before the judge call and resets it
      // nowhere else — so returning early without this leaves the pill reporting
      // work nobody is doing until the next event happens to land.
      s.state = "needs_you";
      this.persist(terminalId, s, true);
      this.emitStatus();
      return;
    }
    const esc: OpenEscalation = {
      escalationId: this.id("esc"),
      question: blocked ? BLOCKED_QUESTION : firstFilled(decision.notify?.body) ?? "Agent needs you",
      reasoning: reason,
      draftReply,
      urgency: decision.notify?.urgency ?? "normal",
      floorRule,
      kind,
      promptId,
      choices: quickChoicesFor({
        kind, floorRule, draftReply, projectPath: this.deps.projectPath(terminalId), open: s.escalations,
      }),
      at: this.now(),
    };
    this.deps.sendAb(createMessage("handler:escalation", {
      projectId: this.deps.projectId, terminalId, ...escalationWire(esc),
    }));
    // Reports accumulate where questions cannot: a judge proposing a refused
    // action again with a different reason raises a fresh row, and only the user
    // takes any of them away. The oldest goes rather than the newest, so the list
    // always describes the situation the session is in now.
    if (blocked) {
      const standing = s.escalations.filter((e) => e.kind === "guard_blocked");
      if (standing.length >= MAX_BLOCKED_REPORTS) {
        const oldest = standing[0]!;
        s.escalations = s.escalations.filter((e) => e !== oldest);
      }
    }
    s.escalations.push(esc);
    s.state = "needs_you";
    this.record(terminalId, "escalate", reason, detail);
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  // A warning is both an audit row the user reads later and context the next
  // decide prompt reads immediately; both come from the same list so the Assistant
  // can never be told less than the user was.
  private noteFloorWarnings(terminalId: string, s: ArmedSession, warnings: FloorWarning[]): void {
    for (const w of warnings) {
      // No detail: `describeWarning` already carries the readable half, and the
      // other one is a regex source — the row a user is meant to act on is the
      // last place to print the floor's own spelling of itself.
      this.record(terminalId, "floor_warning", describeWarning(w));
      this.rememberWarning(s, describeWarning(w));
    }
  }

  private rememberWarning(s: ArmedSession, line: string): void {
    s.floorWarnings.push(line);
    if (s.floorWarnings.length > MAX_REMEMBERED_WARNINGS) {
      s.floorWarnings = s.floorWarnings.slice(-MAX_REMEMBERED_WARNINGS);
    }
  }

  /**
   * Take the snapshots the about-to-be-injected text calls for. Records and
   * advertises nothing: the inject that would justify an undo offer has not
   * happened yet, and a promise about a reply that was never sent is worse than
   * no promise at all.
   */
  private async prepareSnapshots(terminalId: string, text: string): Promise<SnapshotOutcome[]> {
    try {
      return await (this.deps.takeSnapshotsFn ?? takeSnapshots)({
        text, projectPath: this.deps.projectPath(terminalId), sessionId: terminalId, abDir: this.deps.abDir,
      });
    } catch (err) {
      // takeSnapshots reports its own failures as outcomes, so reaching here means
      // it could not even do that. planSnapshots is pure, so the rows can still
      // name which actions went unprotected.
      log.error("handler snapshot pass failed for %s: %s", terminalId, err);
      return planSnapshots(text).map((p): SnapshotOutcome => ({
        status: "failed", action: p.action, trigger: p.trigger, reason: "io_error", detail: String(err),
      }));
    }
  }

  /**
   * Turn the outcomes into what the user can act on. Only a captured snapshot
   * becomes an undo offer; an action that could NOT be protected becomes an
   * unsuppressible advisory row instead, because the one thing worse than a
   * flagged action is being told it can be undone when it cannot.
   *
   * The failure row is written even when authorization suppressed the warning:
   * the user authorized the operation, never the loss of its undo.
   *
   * `flagged` is the floor's own verdict, and it is the backstop for the two
   * parsers disagreeing: a preparable shape the floor recognized but the planner
   * produced no plan for would otherwise pass in complete silence, which reads to
   * the user exactly like an action that was fully snapshotted. A flagged shape no
   * §5.2 action can EVER cover reports that fact rather than passing in silence.
   */
  private recordSnapshots(
    terminalId: string, s: ArmedSession, outcomes: SnapshotOutcome[], flagged: FloorWarning[],
  ): void {
    for (const o of outcomes) {
      if (o.status === "snapshotted") {
        this.storeSnapshot({ terminalId, action: o.action, entry: o.entry });
        continue;
      }
      // "nothing" means nothing was at risk, which needs no row of its own.
      if (o.status !== "failed") continue;
      this.recordUnprotected(terminalId, s, o.trigger, `${o.reason}: ${o.detail}`);
    }

    const covered = new Set(outcomes.map((o) => o.action));
    for (const w of flagged) {
      const action = SNAPSHOT_PATTERNS.get(w.pattern);
      if (!action) {
        if (NO_SNAPSHOT_PATTERNS.has(w.pattern)) this.recordIrreversible(terminalId, w);
        continue;
      }
      if (covered.has(action)) continue;
      this.recordUnprotected(terminalId, s, w.matched, `${action}: the flagged command could not be parsed into a snapshot plan`);
    }
  }

  private recordUnprotected(terminalId: string, s: ArmedSession, trigger: string, detail: string): void {
    const line = `flagged action was not protected: ${trigger}`;
    this.record(terminalId, "floor_warning", line, detail);
    this.rememberWarning(s, line);
  }

  /**
   * The row for a flagged shape §5.2 can never cover, because the state it moves
   * lives outside the project — a remote's default branch, a registry. Fires even
   * when §5.4 authorization suppressed the advisory: the user authorized the
   * operation and never the loss of its undo, the same rule `recordSnapshots`
   * states for a snapshot that could not be taken.
   *
   * The one unprotected-style row that is NOT fed to the next decide prompt, so it
   * takes no `ArmedSession` and calls no `rememberWarning`: the warning already
   * reaches the judge on the unauthorized path, and restating it for a merge the
   * user authorized would turn the lift they granted into a nudge to escalate the
   * same merge every pass.
   */
  private recordIrreversible(terminalId: string, w: FloorWarning): void {
    this.record(
      terminalId, "floor_warning", `no undo exists for this action: ${w.matched}`,
      "it changes state outside the project, so no snapshot could be prepared",
    );
  }

  private storeSnapshot(st: StoredSnapshot): void {
    this.saveSnapshots([...this.snapshots(), st]);
    this.sendSnapshot(st);
  }

  private sendSnapshot(st: StoredSnapshot): void {
    this.deps.sendAb(createMessage("handler:snapshot", {
      projectId: this.deps.projectId, ...snapshotWire(st),
    }));
  }

  // Drops this slot's undo offers and the copies behind them. Called only from a
  // fresh arm (see arm()), never from disarm.
  private retireSnapshots(terminalId: string): void {
    const before = this.snapshots();
    const kept = before.filter((e) => e.terminalId !== terminalId);
    const retired = before.filter((e) => e.terminalId === terminalId);
    if (retired.length) {
      this.saveSnapshots(kept);
      // A backup ref pins its stash commit against `git gc` for as long as it
      // exists, so the git side of a retire needs the same cleanup the trash side
      // has always had.
      this.release(retired);
    }
    void (this.deps.clearTrashFn ?? ((id: string) => clearSessionTrash(id, this.deps.abDir)))(terminalId)
      .catch((err: unknown) => log.warn("handler trash cleanup failed for %s: %s", terminalId, err));
  }

  /**
   * Retire one row the user is done with: a `guard_blocked` report they have
   * read, or an ask they are declining to answer. Both are rows nothing else can
   * take away — a report describes an action Handler never took, so no agent
   * event and no typed line answers it, and an ask survives a submitted line by
   * the clearing rule in onUserReply.
   *
   * Declining is a real move, not the absence of one. Without it the only way out
   * of an ask is answering it, which forces every non-answer through the judge —
   * and a question the user has decided not to engage with would stand until the
   * work it named finished.
   *
   * Still refuses the other two kinds, deliberately. A blocking `reply` row IS
   * retired by the user's own submitted line, so dismissing one would drop a live
   * question more silently than any path that exists today; a `resolve_in_session`
   * row is refused for the reason onUserReply refuses to clear one — the agent
   * stays blocked and no further event re-raises it.
   *
   * Idempotent in every direction the app can get wrong: an id this session no
   * longer holds (a second tap racing the status frame that already dropped the
   * row) resyncs the sender rather than failing.
   */
  dismissEscalation(terminalId: string, escalationId: string): void {
    const s = this.sessions.get(terminalId);
    const esc = s?.escalations.find((e) => e.escalationId === escalationId);
    if (!s || !esc || (esc.kind !== "guard_blocked" && !esc.nonBlocking)) {
      // The sender is holding a row this session no longer has, or one it may not
      // retire this way. A status resync is what removes it from their list.
      log.warn("handler dismiss ignored: %s on %s", escalationId, terminalId);
      this.emitStatus();
      return;
    }
    if (esc.nonBlocking) {
      // Parked as an answer because the judge has to LEARN this, or its next pass
      // re-asks a question the user has already refused — and the refusal is the
      // one outcome no agent event can imply. Deliberately not relayed: the two
      // answer transports start a pass because they carry something the agent may
      // need, and a decline carries nothing the agent could act on.
      this.parkAskAnswer(terminalId, s, esc, "(the user declined to answer)", false);
      this.record(terminalId, "escalate", "you declined Handler's question", previewForUser(esc.question));
      return;
    }
    // No new activity kind: the `escalate` row is the durable trace of the
    // refusal, and a dismissal is the user acknowledging their own read.
    s.escalations = s.escalations.filter((e) => e !== esc);
    // A park is not over because a report was read: the timer is still armed and
    // parkKind/parkedUntil still describe the wait, so resting here would leave
    // the state and the countdown chip describing different sessions.
    if (s.state !== "parked") s.state = restingState(s);
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  /**
   * Perform the undo an advertised snapshot promised.
   *
   * Deliberately NOT gated on instruction-scoped authorization: anyone who can
   * drive this project can already drive its terminal, so a second authorization
   * concept would only make the safety net harder to reach than the action it
   * reverses.
   *
   * Idempotent in every direction the app can get wrong — an id this project no
   * longer has resyncs the sender, an already-undone entry just re-states itself,
   * and a failed attempt leaves the entry spendable so a retry is possible.
   */
  async undo(snapshotId: string): Promise<void> {
    const st = this.snapshots().find((e) => e.entry.id === snapshotId);
    if (!st) {
      // The sender is holding a row this project no longer has (a fresh arm
      // retired it, or the store aged it out). A status resync is what removes it.
      log.warn("handler undo ignored: unknown snapshot %s", snapshotId);
      this.emitStatus();
      return;
    }
    if (st.undoneAt !== undefined) return this.sendSnapshot(st);
    if (this.undoing.has(snapshotId)) return;
    this.undoing.add(snapshotId);

    let result: UndoResult;
    try {
      result = await (this.deps.undoSnapshotFn ?? undoSnapshot)(st.entry, { abDir: this.deps.abDir });
    } catch (err) {
      result = { ok: false, detail: String(err) };
    } finally {
      this.undoing.delete(snapshotId);
    }

    // Re-read rather than mutating the entry found before the await: a snapshot
    // taken while the undo ran has already rewritten the list.
    const entries = this.snapshots().map((e) => e.entry.id !== snapshotId ? e : {
      ...e,
      undoneAt: result.ok ? this.now() : undefined,
      failure: result.ok ? undefined : result.detail,
    });
    // The undo had to discard live state to get back, so that state was stashed on
    // the way past. Recording it is what keeps the undo from being the second
    // destructive act.
    const safety: StoredSnapshot | undefined = result.safety
      ? {
        terminalId: st.terminalId,
        action: result.safety.kind === "pre_push_sha" ? "force_push" : "reset_hard",
        entry: result.safety,
      }
      : undefined;
    this.saveSnapshots(safety ? [...entries, safety] : entries);

    const updated = this.snapshots().find((e) => e.entry.id === snapshotId);
    if (updated) this.sendSnapshot(updated);
    if (safety) this.sendSnapshot(safety);
  }

  private record(terminalId: string, decision: ActivityRecord["decision"], reason: string, detail?: string): void {
    const rec: ActivityRecord = { recordId: this.id("rec"), at: this.now(), terminalId, decision, reason, detail };
    (this.deps.appendActivityFn ?? ((r: ActivityRecord) => appendActivity(this.deps.abDir, this.deps.projectId, r)))(rec);
    this.deps.sendAb(createMessage("handler:activity", {
      projectId: this.deps.projectId, recordId: rec.recordId, at: rec.at, terminalId, decision, reason, detail,
    }));
  }

  /**
   * How much of the Handler this slot can actually get, in its current mode.
   * Two independent facts collapse here: whether the engine can see the slot at
   * all (its tool's integration), and whether the slot's effective judge tool
   * can run headless. Only the first can make an arm futile — the second merely
   * makes it escalate-only, which is a supported mode.
   *
   * The judge tool resolves the same way `plan()` resolves it: the session's
   * stored pick, else the observed session's own tool.
   */
  observabilityFor(terminalId: string): HandlerObservability {
    if (this.deps.observable && !this.deps.observable(terminalId)) return "unsupported";
    const judge = this.storedJudge(terminalId).tool ?? this.deps.tool(terminalId);
    return judgeCapable(judge) ? "full" : "escalate_only";
  }

  // Public: agent-core also emits on every app handshake so a fresh app sees
  // defaultTool before anything is armed. Judge choices are per-session now,
  // carried on each session snapshot, and are never cleared by this emit — only
  // arm() touches them.
  emitStatus(): void {
    const sessions = [...this.sessions.entries()].map(([terminalId, s]) => ({
      terminalId,
      state: s.state,
      pendingEscalations: s.escalations.length,
      armedAt: s.armedAt,
      goal: s.goal,
      // Copied, never the live arrays: handler:status is a REPLAY_TYPE, so the bus
      // holds this frame by reference until the next one — and escalate() pushes onto
      // s.escalations in place, which rewrote a frame already published and left the
      // cached replay's pendingEscalations disagreeing with its own escalation list.
      backlog: [...s.backlog],
      escalations: s.escalations.map(escalationWire),
      judgeTool: s.judgeTool,
      judgeModel: s.judgeModel,
      parkKind: s.parkKind,
      parkedUntil: s.parkedUntil,
      // Re-derived on every emit rather than frozen at arm time: a slot's mode
      // and its judge pick both change under a live arm.
      observability: this.observabilityFor(terminalId),
      // Resolved, never the raw field: the app renders the picker off this, and
      // an absent value would leave it showing nothing while the judge runs
      // under a posture all the same.
      personality: s.personality ?? DEFAULT_PERSONALITY,
      // A constant, because it is a fact about THIS BRIDGE rather than about the
      // session: answerAsk exists here and instruct reads an escalationId, so an
      // app may act on a `nonBlocking` row. It has to be said on the wire because
      // the row cannot say it — a bridge that reads the field off a record a newer
      // one wrote re-emits it faithfully with no verb that answers it — and an app
      // reading only the row would answer through the reply transport, into a PTY
      // the session never stopped.
      askAnswer: true as const,
      // Derived from the parked answer rather than stored beside it: a second flag
      // could say a relay is still owed after the handle branch dropped the answer
      // it named. Omitted when nothing is parked, the way every optional field on
      // this snapshot is — absent and false mean one thing here.
      ...(s.askAnswer ? { askAnswerPending: true } : {}),
    }));
    const wrapUps = this.wrapUps();
    const entitlement = this.entitlementForApp();
    this.deps.sendAb(createMessage("handler:status", {
      projectId: this.deps.projectId,
      // What an absent per-session judge resolves to for PTY slots — lets the
      // app label its picker "Default (claude-code)" instead of a bare Default.
      defaultTool: this.deps.tool(),
      sessions,
      // Project-scoped, not per session: an undo offer outlives the session that
      // took it, and an app that restarted between the advert and the tap has no
      // other way back to it.
      snapshots: this.snapshots().map(snapshotWire),
      // Optional and appended LAST (see HandlerWrapUpWire): absent and [] mean the
      // same thing, so a project that has never wrapped up sends neither.
      ...(wrapUps.length ? { wrapUps: wrapUps.map(wrapUpWire) } : {}),
      // Omitted whenever Handler is available, so the key's presence IS the
      // refusal. Every emit carries it, not just the one arm() raises on its
      // way out: the shield the user has yet to press is the surface that most
      // needs to know, and it is on screen long before any arm.
      ...(entitlement ? { entitlement } : {}),
    }));
  }
}
