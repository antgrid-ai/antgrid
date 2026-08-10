// bridge/src/handler/engine.ts
import { createMessage, type AbMessage } from "../protocol";
import { classifyDestructive, describeWarning, type FloorWarning } from "./destructive-floor";
import {
  authorizeInstruction, createAuthorization, partitionWarnings,
  type InstructionAuthorization,
} from "./authorization";
import {
  clearSessionTrash, describeSnapshot, planSnapshots, releaseSnapshots, takeSnapshots, undoSnapshot,
  SNAPSHOT_PATTERNS, type SnapshotEntry, type SnapshotOutcome, type UndoResult,
} from "./snapshot";
import { loadSnapshots, pruneSnapshots, saveSnapshots, type StoredSnapshot } from "./snapshot-store";
import { RunawayGuard } from "./runaway-guard";
import { assembleContext } from "./context";
import { runDecision as defaultRunDecision, runExtraction as defaultRunExtraction } from "./judge";
import { MAX_ITEM_CHARS, type ExtractedItem } from "./extract";
import {
  loadHandlerConfig, appendActivity,
  type HandlerConfig, type ActivityRecord,
} from "./config";
import {
  loadHandlerSession, saveHandlerSession, EscalationChoiceSchema,
  type EscalationChoice, type HandlerSessionRecord, type OpenEscalation,
} from "./session-store";
import {
  allTerminal, applyTransitions, propagateBlocked, renderBacklog, summarize,
  type InstructionItem, type ItemStatus,
} from "./backlog";
import { stripAnsi } from "./context";
import type { SessionAdapter } from "./session-adapter";
import { handlerObservable, judgeCapable } from "../agents/registry";
import { type HandlerDecision } from "./decision";
import {
  LIMIT_FALLBACK_MS, LIMIT_PARK_CEILING, MIN_PARK_MS, TRANSIENT_CEILING, transientBackoffMs,
  defaultSchedule, TimerRegistry, type LifecycleDeps,
} from "./lifecycle";
import { logger } from "../logger";

const log = logger.child({ component: "handler-engine" });

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

// How many past floor warnings ride along in the next decide prompt. Enough to
// show a pattern the Assistant keeps repeating, short enough that a long session
// does not spend its context budget re-reading its own history.
const MAX_REMEMBERED_WARNINGS = 5;

// The item outcomes the activity feed carries a kind for. A skip is as
// consequential as a completion (§4.3), so they stay distinguishable without
// parsing the reason text.
const ITEM_DECISION: Partial<Record<ItemStatus, ActivityRecord["decision"]>> = {
  done: "item_done",
  blocked: "item_blocked",
  skipped: "item_skipped",
  failed: "item_failed",
};

type SummaryStatus = keyof ReturnType<typeof summarize>;
const SUMMARY_GROUPS: [SummaryStatus, string][] = [
  ["done", "Done"],
  ["failed", "Failed"],
  ["blocked", "Blocked"],
  ["skipped", "Skipped"],
];

// Item text and the goal are free text the user typed or extraction produced, so
// either can carry newlines that would render a push body as a broken multi-line
// notification.
function oneLine(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

// `??` is the wrong operator against a judge decision: `notify.body`/`notify.draftReply`
// are `z.string()`, not optional, so a judge answering `handle` fills the whole notify
// block with EMPTY strings rather than omitting it. A nullish fallback then never fires
// and the escalation reaches the app with no question and no draft — a card the user
// can read but cannot act on.
function firstFilled(...values: (string | undefined)[]): string | undefined {
  return values.find((v) => v !== undefined && v.trim() !== "");
}

// Renders judge text for a HUMAN to read in an escalation, never for injection. The
// control characters that force some of these escalations are exactly what must stay
// visible here, so they are escaped rather than stripped.
function previewForUser(s: string, max = 300): string {
  const escaped = s.replace(
    /[\x00-\x1f\x7f]/g,
    (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, "0")}`,
  );
  return escaped.length > max ? `${escaped.slice(0, max)}…` : escaped;
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

function wakeClock(at: number): string {
  const d = new Date(at);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// The "don't do it" half of a quick-choice card. Engine-authored and constant, not
// judge output: reject has to mean the same thing on every card, and it is the one
// choice whose text a user is least likely to read before tapping.
const REJECT_CHOICE_TEXT = "Do not proceed. Wait for my instructions.";

/**
 * The §4.6 quick-choice card for an escalation the engine has already built.
 *
 * Minted here rather than asked of the judge: the judge could propose a richer set,
 * but its labels are Assistant output reaching a one-tap control, and §5.4 is
 * emphatic that nothing about authorization may derive from Assistant output. The
 * one thing the judge does contribute is the draft it already composed, which the
 * [Approve] choice sends VERBATIM — so the app must render `text`, not only `label`.
 *
 * A tap carries NO §5.4 authorization lift. It answers through the ordinary reply
 * transport (terminal:input / agent:prompt), never through handler:instruct:
 * - `instruct` is the single feed point for §5.4 and it also queues an extraction,
 *   so a tap would mint a backlog item no terminal status can ever resolve and the
 *   session could never wrap up.
 * - A lift minted by tapping a label the judge wrote is the laundering path §5.4
 *   closes: a compromised agent composes an escalation whose [Approve] chip
 *   silences every later advisory row.
 * The costs are not symmetric — under-lifting costs one advisory activity row per
 * repeat (post-Phase-5 the advisory floor records rather than escalates), while
 * over-lifting costs a session-wide grant the user never read. The real lift stays
 * one control away, in the user's own words, through the PA bar.
 */
export function quickChoicesFor(p: {
  kind?: "reply" | "resolve_in_session";
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
  // Escalations stack per terminal (nothing serializes the blocking-prompt path).
  // An agent blocked on a permission/question reads nothing until that prompt is
  // resolved, so a one-tap offered beside an unanswered one sends text into a
  // stalled session and leaves the pill exactly where it was: an action that looks
  // like it cleared the situation and did not. The free-text sheet costs the user
  // the same send but makes them read first; that is the deliberate half-step this
  // withholds. The app enforces the mirror of this for the order the bridge cannot
  // see (a prompt arriving AFTER a card was already minted).
  if (p.open?.some((e) => e.kind === "resolve_in_session")) return undefined;
  // floorRule is set only by the §5.3 HARD floor, which nothing lifts. Those keep
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
  // §5.2 snapshot/undo, injectable: the real ones shell out to git and copy trees,
  // so a test that could not replace them would need a repo on disk.
  takeSnapshotsFn?: typeof takeSnapshots;
  undoSnapshotFn?: typeof undoSnapshot;
  clearTrashFn?: (sessionId: string) => Promise<void>;
  releaseSnapshotsFn?: (entries: SnapshotEntry[]) => Promise<void>;
  loadSnapshotsFn?: () => StoredSnapshot[];
  saveSnapshotsFn?: (entries: StoredSnapshot[]) => void;
  loadConfigFn?: () => HandlerConfig;
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
  notifyOnly: boolean;
  armedAt: number;
  state: "watching" | "handling" | "needs_you" | "parked";
  // Full payloads, not a count: status snapshots replay these so the app can
  // always render an answerable row for every pending escalation.
  escalations: OpenEscalation[];
  judgeTool?: string;
  judgeModel?: string;
  parkKind?: "limit" | "outage";
  parkedUntil?: number;
  selfResuming?: boolean;
  // Consecutive terminal transient failures. A judged decision clears it.
  transientFailures: number;
  // Advisory floor hits on replies this session already injected (§5.1), fed back
  // into the next decide prompt. Deliberately not persisted: the activity log is
  // the durable audit trail, and this copy exists only to shape the next call.
  floorWarnings: string[];
  // What the user's own instructions authorized for this session (§5.4). Not
  // persisted, unlike the backlog those instructions also produced: rebuilding it
  // after a restart could only come from the stored item text, which extraction
  // wrote — laundering judge output into an authorization is exactly what §5.4
  // exists to prevent. A restart therefore costs one advisory row per operation
  // the user has to name again, which is the cheap side of that trade.
  auth: InstructionAuthorization;
  // Consecutive limit parks that ended with the limit still in force. Not
  // persisted, unlike transientFailures: it bounds one in-process park→nudge
  // cycle, and a restart is itself a break in that cycle.
  limitParks: number;
  // One push per park episode: a re-park is the same wait, not a new one.
  parkPushSent?: boolean;
  // Outage park born of a judge failure: the pause was never judged, so the
  // wake re-runs this event instead of nudging past supervision.
  retryEvent?: HandlerEvent;
  // The persisted shadow of retryEvent. The event itself is too stale to keep
  // across a restart, but the fact that a judge still owes this pause a verdict
  // is not — without it the rehydrated park would wake and nudge, letting the
  // agent carry on from a pause nobody ever assessed.
  parkAwaitingJudge?: boolean;
}

// Where a session lands once whatever it was doing is over — a judged decision,
// a submitted line, the end of a park. An escalation the user never answered
// outranks all three: "watching" with a pending row is a session the app draws
// as quiet over an agent that is still waiting.
function restingState(s: ArmedSession): "watching" | "needs_you" {
  return s.escalations.length > 0 ? "needs_you" : "watching";
}

export class HandlerEngine {
  private guard: RunawayGuard;
  private sessions = new Map<string, ArmedSession>();
  private cachedConfig: HandlerConfig | null = null;
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
  // Undos in flight, by snapshot id. Two taps on one row must not run two undos:
  // the second would be acting on a tree the first already moved.
  private undoing = new Set<string>();

  constructor(private deps: HandlerEngineDeps) {
    this.guard = deps.guard ?? new RunawayGuard();
    this.timers = new TimerRegistry({
      now: () => this.now(),
      schedule: deps.schedule ?? defaultSchedule,
    });
  }

  private cfg(): HandlerConfig {
    if (this.cachedConfig) return this.cachedConfig;
    this.cachedConfig = this.deps.loadConfigFn
      ? this.deps.loadConfigFn()
      : loadHandlerConfig(this.deps.abDir, this.deps.projectId);
    return this.cachedConfig;
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

  // Fire-and-forget: the entries are already unreachable through the store, so
  // nothing the user can still act on waits on the cleanup.
  private release(entries: StoredSnapshot[]): void {
    void (this.deps.releaseSnapshotsFn ?? ((e: SnapshotEntry[]) =>
      releaseSnapshots(e, { abDir: this.deps.abDir })))(entries.map((e) => e.entry))
      .catch((err: unknown) => log.warn("handler snapshot cleanup failed: %s", err));
  }

  private persist(terminalId: string, s: ArmedSession, armed: boolean, suspended?: boolean): void {
    this.saveSession({
      version: 2, terminalId, armed, suspended, goal: s.goal, backlog: s.backlog,
      notifyOnly: s.notifyOnly, armedAt: s.armedAt,
      escalations: s.escalations, judgeTool: s.judgeTool, judgeModel: s.judgeModel,
      parkKind: s.parkKind, parkedUntil: s.parkedUntil, transientFailures: s.transientFailures,
      parkAwaitingJudge: s.parkAwaitingJudge,
    });
  }

  arm(p: {
    terminalId: string; goal?: string; backlog?: InstructionItem[];
    notifyOnly: boolean; judgeTool?: string; judgeModel?: string;
  }): void {
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
      // as []): a re-arm or a notify-only toggle carries no backlog, and the
      // bridge's copy is the one holding the statuses this session has banked.
      const goalChanged = p.goal !== undefined && p.goal.trim() !== existing.goal.trim();
      if (p.goal !== undefined) existing.goal = p.goal;
      if (backlog !== undefined) existing.backlog = backlog;
      existing.notifyOnly = p.notifyOnly;
      this.applyJudgeChoice(existing, p);
      this.persist(p.terminalId, existing, true);
      // Only when the goal actually moved: `handler:configure` is also the
      // backlog-edit and notify-only path (see updateBacklog in the app), and a
      // "Goal edited" row over an unchanged goal is a feed that misreports what
      // happened on every reorder and every toggle.
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
    // never fires, a notify-only session goes silent, and the park nudge stops.
    const carried = (resumed?.escalations ?? []).filter((e) => e.kind !== "resolve_in_session");
    const s: ArmedSession = {
      goal: p.goal ?? resumed?.goal ?? "",
      backlog: backlog ?? resumed?.backlog ?? [],
      notifyOnly: p.notifyOnly,
      armedAt: resumed?.armedAt ?? this.now(),
      state: carried.length > 0 ? "needs_you" : "watching",
      escalations: carried,
      // Seed from the persisted record (armed pre-restart OR the last disarmed
      // pick), then let an explicit choice on this arm override it.
      judgeTool: stored.tool,
      judgeModel: stored.model,
      transientFailures: resumed?.transientFailures ?? 0,
      limitParks: 0,
      floorWarnings: [],
      auth: createAuthorization(),
    };
    this.applyJudgeChoice(s, p);
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
    // §3.2: the user types one sentence and the session arms immediately, with
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
   * Stack more instructions onto a live session (§3.2). Returns without waiting
   * on the extraction spawn: arming and stacking are one tap, and a supervisor
   * that made the user watch a 20s CLI run before their sentence appeared would
   * be a worse product than one that fills the list a moment later.
   *
   * Instructing never arms — `handler:configure` is the only thing that does.
   *
   * This is also the ONE feed point for §5.4 authorization. The arm-time goal is
   * deliberately not one: it is a statement of what the session is for, and a lift
   * has to be traceable to a sentence the user wrote to authorize an action.
   */
  instruct(p: { terminalId: string; text: string }): void {
    const s = this.sessions.get(p.terminalId);
    if (!s) {
      log.warn("handler instruct ignored: no armed session for %s", p.terminalId);
      return;
    }
    const text = p.text.trim();
    if (!text) return;
    // Taken from the raw payload and BEFORE the extraction spawn: extraction output is
    // judge-authored, so deriving a lift from it would let a compromised agent widen
    // its own permissions through the extractor.
    authorizeInstruction(s.auth, text, this.deps.projectPath(p.terminalId));
    this.queueExtraction(p.terminalId, text);
  }

  // `onlyIfEmpty` is for the arm-time pass (§3.2): the goal is extracted once,
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

    let items: ExtractedItem[] | null = null;
    if (judgeCapable(tool)) {
      const runExtractionFn = this.deps.runExtractionFn ?? defaultRunExtraction;
      try {
        items = await runExtractionFn({ tool, model: s.judgeModel, text, cwd: this.deps.projectPath(terminalId) });
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
      this.appendItems(terminalId, s, items?.length ? items : raw);
    } catch (err) {
      log.error("handler instruct append failed for %s: %s", terminalId, err);
    }
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
    // Nothing appended means nothing to persist and no snapshot worth
    // broadcasting; the record above is the whole outcome.
    if (kept.length === 0) return;

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
    this.guard.reset(terminalId);
    const s = this.sessions.get(terminalId);
    if (!s) return;
    // Called per terminal:input (every keystroke), so the submitted-line test
    // comes first: typing into an armed terminal must not cost one disk write +
    // one encrypted status broadcast per character.
    if (!/[\r\n]/.test(data)) return;
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
    // A resolve retires the row for the prompt it names, plus any row too old to
    // carry an id at all. Never every row: drivers hold a MAP of pending prompts
    // (parallel tool calls open two at once), and dropping the sibling's row would
    // be the same silently-blocked session by another route.
    const resolved = opts?.resolvedPromptId;
    const kept = s.escalations.filter((e) => e.kind === "resolve_in_session"
      && (resolved === undefined || (e.promptId !== undefined && e.promptId !== resolved)));
    const cleared = kept.length < s.escalations.length;
    if (!unparked && !cleared) return;
    s.escalations = kept;
    // A human line is a fresh attempt, so the failure series that led here is
    // over. Without this the counters stay at their ceiling — only a judged turn
    // clears transientFailures — and the very next failure would page again
    // instead of backing off.
    s.transientFailures = 0;
    s.limitParks = 0;
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
    const kept = promptId === undefined
      ? []
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

    // Notify-only: escalate without spending a judge call. One unanswered
    // escalation at a time — while the user hasn't responded, every further
    // pause says the same thing ("agent is waiting"), so re-escalating each
    // one would only pile up pushes and pending rows.
    if (s.notifyOnly) {
      if (s.escalations.length > 0) return;
      const body = await this.outputSnippet(evt.terminalId);
      // The await yields the event loop: a concurrent disarm/exit may have
      // dropped this session, and escalating would re-persist it as armed.
      if (this.sessions.get(evt.terminalId) !== s) return;
      this.escalate(evt.terminalId, s, {
        decision: "escalate", confidence: 0, reason: "notify-only: escalating all events",
        notify: { title: "Handler", body, draftReply: "", urgency: "normal" },
      });
      return;
    }

    s.state = "handling";
    this.emitStatus();

    // Scoped to the judge itself: a judge that could not run is a transient
    // outage, not a verdict, so it parks and re-judges this same event later.
    // The act-on-decision body below keeps its own catch — parking there would
    // re-judge a decision that was already made and acted on.
    let decision: HandlerDecision | null;
    try {
      const tool = this.deps.tool(evt.terminalId);
      const transcriptPath = evt.transcriptPath ?? this.deps.adapter.transcriptPath(evt.terminalId);
      const ctx = await assembleContext({
        tool, transcriptPath,
        agentSessionId: this.deps.agentSessionId?.(evt.terminalId),
        recentPty: await this.deps.adapter.recentOutput(evt.terminalId),
        recentKind: this.deps.adapter.outputKind(evt.terminalId),
        purpose: "decide",
      });
      const runDecisionFn = this.deps.runDecisionFn ?? defaultRunDecision;
      decision = await runDecisionFn({
        tool: s.judgeTool ?? tool, model: s.judgeModel, goal: s.goal,
        backlogText: renderBacklog(s.backlog),
        context: ctx.text, transcriptPath: ctx.transcriptPath ?? transcriptPath,
        cwd: this.deps.projectPath(evt.terminalId),
        floorWarnings: s.floorWarnings,
      });
    } catch {
      if (this.sessions.get(evt.terminalId) === s) this.onJudgeUnavailable(evt, s);
      return;
    }

    // The judge await yields the event loop; a concurrent disarm/terminal-exit may
    // have dropped or replaced this session. Never inject into a session the user
    // stopped mid-judge — supervise-safely boundary.
    if (this.sessions.get(evt.terminalId) !== s) return;

    if (!decision) return this.onJudgeUnavailable(evt, s);

    // A judge that answered proves the provider is serving us again.
    s.transientFailures = 0;
    s.limitParks = 0;

    // A rejection must not strand state in "handling" — reset before rethrowing so
    // the next event isn't ignored and the app's status pill reflects reality.
    try {
      this.absorbTransitions(evt.terminalId, s, decision);
      // Wrap-up is checked AFTER acting on the decision (see each branch below):
      // a final `handle` reply must reach the agent before disarm, and an
      // escalation never wraps up — wake-rules trump completion.

      if (decision.decision === "handle") {
        const reply = (decision.reply ?? "").trim();
        const actionText = decision.action?.kind === "slash_command" ? decision.action.value : "";
        const probe = `${reply}\n${actionText}`;
        if (!reply && !actionText) return this.escalate(evt.terminalId, s, decision, "empty reply");

        // Harness guards on the gate-bypassing inject channel (alongside the floor): a
        // compromised/hallucinating judge must not inject an unbounded blob or smuggle
        // multiple commands via embedded newlines/control chars in one "handle".
        const MAX_REPLY_CHARS = 4096;
        const written = actionText || reply;
        if (written.length > MAX_REPLY_CHARS) {
          return this.escalate(evt.terminalId, s, decision, `reply too long (${written.length} > ${MAX_REPLY_CHARS})`);
        }
        if (/[\x00-\x1f\x7f]/.test(written)) {
          return this.escalate(evt.terminalId, s, decision, "reply contains control characters");
        }
        // action.value is judge-generated free text (decision.ts has no allowlist), so a
        // hallucinating judge could shape it like a filesystem path rather than a command
        // verb. Require a single "/"-free, whitespace-free token so classifyDestructive's
        // path check — scoped to `reply` only, not this value — never needs to reconsider it.
        if (actionText && !/^\/[^\s/\\]+$/.test(actionText)) {
          return this.escalate(evt.terminalId, s, decision, "slash command value is not a simple verb");
        }

        // Chat adapters can't inject a slash command (drivers need a commandId
        // the judge doesn't have); surfacing it beats silently sending "/x" as
        // literal prompt text the agent would misread.
        if (actionText && !this.deps.adapter.supportsSlashCommands(evt.terminalId)) {
          return this.escalate(evt.terminalId, s, decision, "slash commands are not supported in chat sessions");
        }

        // The floor's ONE call site (spec §5). It inspects the text Handler is
        // about to inject, never the commands the agent goes on to run.
        const floor = classifyDestructive(probe, this.deps.projectPath(evt.terminalId), reply);
        // Checked before the partition, and never against it: §5.3 is liftable by
        // nothing, so no instruction can reach this branch.
        if (floor.hard.length > 0) {
          const reason = describeWarning(floor.hard[0]!);
          return this.escalate(evt.terminalId, s, decision, `floor: ${reason}`, reason);
        }
        // §5.4: what the user's own instructions already authorized drops out of the
        // warning stream. It stays a separate list rather than being filtered away
        // because an authorized action is still snapshotted (§5.2) — the snapshot pass
        // reads `authorized` here, alongside `warn`.
        const { warn, authorized } = partitionWarnings(s.auth, floor.warnings, probe);

        const guardReason = this.guard.check(evt.terminalId, probe);
        if (guardReason) return this.escalate(evt.terminalId, s, decision, guardReason);

        if (authorized.length > 0) {
          log.info("handler floor: %d warning(s) authorized by instruction for %s",
            authorized.length, evt.terminalId);
        }
        // §5.2, and the reason the floor can afford to be advisory: prepare the undo
        // BEFORE the agent is told to do the thing. Authorized warnings count here —
        // §5.4 drops the warning, never the safety net ("I asked for it" is not the
        // same as "I wanted that exact result").
        const snapshots = warn.length + authorized.length > 0
          ? await this.prepareSnapshots(evt.terminalId, written)
          : [];
        // The snapshot pass awaits git and the filesystem; a concurrent disarm may
        // have dropped this session, and injecting into one the user stopped is the
        // boundary this whole file is built around. Whatever was captured is left in
        // the store unadvertised — a reply that was never sent has nothing to undo —
        // and the next fresh arm on this slot reclaims it.
        if (this.sessions.get(evt.terminalId) !== s) return;

        this.deps.adapter.injectReply(evt.terminalId, written);
        this.guard.recordAutoReply(evt.terminalId, probe);
        // Both recorded after the inject and before the handle row, so the feed reads
        // as "what was saved, what was flagged, then what was sent". Auditability is
        // what prevention was traded for (§5.1), so nothing here is conditional on the
        // Assistant's own view of the risk.
        this.recordSnapshots(evt.terminalId, s, snapshots, [...warn, ...authorized]);
        this.noteFloorWarnings(evt.terminalId, s, warn);
        this.record(evt.terminalId, "handle", decision.reason, written);
        if (this.maybeWrapUp(evt.terminalId, s)) return;
        s.state = restingState(s);
        this.persist(evt.terminalId, s, true);
        this.emitStatus();
        return;
      }

      if (decision.decision === "continue") {
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
        // One unanswered escalation is enough: until the user responds, every
        // further limit says the same thing.
        if (s.escalations.length === 0) {
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
      // judged turn or a human line clears it — so escalate only while nothing
      // is already pending, or a stuck judge would append an identical row (and
      // a push) on every single failure from here on.
      if (s.escalations.length === 0) {
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
  private onJudgeUnavailable(evt: HandlerEvent, s: ArmedSession): void {
    this.registerTransientFailure({ ...evt, errorClass: evt.errorClass ?? "judge unavailable" }, s, evt);
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
    // either way — the human is the resume path now.
    if (s.escalations.length > 0) return;
    // Notify-only means "tell me, never act" — so the wake is a notification,
    // not a nudge. Lifecycle events route ahead of the notify-only branch in
    // handleEventInner (a park is a fact, not a verdict), which is what lets a
    // notify-only session reach this timer at all; without this the wait would
    // end by typing into a terminal the user opted out of auto-driving.
    if (s.notifyOnly) {
      this.escalate(terminalId, s, {
        decision: "escalate", confidence: 0, reason: "notify-only: the wait is over",
        notify: {
          title: "Handler", body: "Agent is ready to resume — it is waiting on you",
          draftReply: "", urgency: "normal",
        },
      });
      return;
    }
    // Straight to the adapter, never through the auto-reply path: the nudge is
    // the supervisor's own recovery action, so it must neither advance the
    // runaway counter nor enter the circular-exchange window — a second park
    // would otherwise write an identical "continue" and false-escalate.
    this.deps.adapter.injectReply(terminalId, "continue");
  }

  // Move backlog items on the evaluator's word — inside the bounds
  // applyTransitions enforces — and count real progress toward the runaway guard:
  // progress is evidence of non-looping.
  private absorbTransitions(terminalId: string, s: ArmedSession, decision: HandlerDecision): void {
    const result = applyTransitions(s.backlog, decision.transitions ?? [], this.now());
    // A rejection is an attempted invariant violation — a minted id, a terminal
    // move with no evidence, a completed item walked back — and this log is the
    // only place it can surface: the item simply does not move, so no downstream
    // state ever looks wrong. Dropping these silently is how a judge quietly
    // fishing for progress stays invisible.
    for (const r of result.rejected) {
      log.warn("handler transition rejected for %s: %s (id=%s status=%s)",
        terminalId, r.reason, r.transition.id, r.transition.status);
    }
    // Blocking is derived, never judged (§3.3): an item is blocked because
    // something it depends on is, which is why it carries no evidence and why the
    // evaluator is not asked for it. Without this call `dependsOn` would be
    // decorative — extracted, rendered, and never acted on.
    const wasBlocked = new Set(result.backlog.filter((i) => i.status === "blocked").map((i) => i.id));
    s.backlog = propagateBlocked(result.backlog);
    const byId = new Map(s.backlog.map((i) => [i.id, i]));

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

  // Auto-disarm once every item has reached a terminal state (§2.2). A `blocked`
  // item is deliberately not one: it is revivable, and the evaluator can still
  // resolve it as `skipped` or `failed` on evidence — which is the deadlock fix,
  // since "correctly did not happen" is now sayable and an unreachable item no
  // longer holds the session open forever.
  // Called only from the handle/continue branches — never on escalate.
  private maybeWrapUp(terminalId: string, s: ArmedSession): boolean {
    // A wrap-up disarms the session. Never do that while a human question is
    // outstanding: an earlier escalate may already have banked the transitions
    // that completed the backlog (absorbTransitions runs on every decision,
    // including escalate), so a later handle/continue could otherwise auto-disarm
    // and silently bury the unanswered escalation.
    if (s.escalations.length > 0) return false;
    if (!allTerminal(s.backlog)) return false;
    this.record(terminalId, "wrapped_up", "every backlog item resolved", s.goal || NO_GOAL);
    this.deps.sendPush?.(
      `Handler: done — ${oneLine(s.goal) || "session complete"}${this.wrapUpSummary(s.backlog)}${this.undoNote(terminalId)}`,
      terminalId,
    );
    this.disarm(terminalId);
    return true;
  }

  // The morning-after summary. §2.2 puts the non-`done` outcomes at the centre of
  // it — an item nobody could reach is the one thing the user has to act on — and
  // a bare count reads the same whether the work was moot or the assistant gave
  // up, so each group names its items. Capped so a long backlog can't blow past
  // OS notification limits.
  private wrapUpSummary(backlog: InstructionItem[]): string {
    const counts = summarize(backlog);
    const parts: string[] = [];
    for (const [status, label] of SUMMARY_GROUPS) {
      const total = counts[status];
      if (total === 0) continue;
      const shown = backlog.filter((i) => i.status === status).slice(0, 3).map((i) => oneLine(i.text));
      const more = total > shown.length ? ` +${total - shown.length} more` : "";
      parts.push(`${label}: ${shown.join(", ")}${more}`);
    }
    return parts.length > 0 ? `. ${parts.join(". ")}` : "";
  }

  // The wrap-up push is the last thing the user reads about this session, and the
  // session is disarmed by the time they read it — so it is also the last place
  // the undo can be made discoverable before it is needed (§5.5).
  private undoNote(terminalId: string): string {
    const open = this.snapshots().filter((e) => e.terminalId === terminalId && e.undoneAt === undefined);
    return open.length > 0 ? `. ${open.length} flagged action(s) can still be undone` : "";
  }

  // Last non-empty output lines (PTY scrollback or rendered chat snapshot),
  // ANSI-stripped and capped — gives a notify-only escalation enough context
  // to act on from the lock screen.
  private async outputSnippet(terminalId: string): Promise<string> {
    const raw = stripAnsi(await this.deps.adapter.recentOutput(terminalId));
    const lines = raw.split("\n").map((l) => l.trim()).filter(Boolean);
    const tail = lines.slice(-3).join(" · ");
    return tail ? tail.slice(-200) : "Agent needs you";
  }

  private escalate(
    terminalId: string, s: ArmedSession, decision: HandlerDecision,
    forcedReason?: string, floorRule?: string, kind?: "reply" | "resolve_in_session",
    promptId?: string,
  ): void {
    const reason = forcedReason ?? decision.reason;
    // Carries the text a harness guard rejected, so the reply sheet can show what
    // Handler wanted to send and let the user edit it down. Safe to pass raw: the wire
    // leaves `draftReply` unconstrained while `EscalationChoiceWire.text` bans control
    // chars and caps length, so `quickChoicesFor` withholds the one-tap chip on exactly
    // the drafts a guard would have refused.
    const draftReply = firstFilled(decision.notify?.draftReply, decision.reply) ?? "";
    const esc: OpenEscalation = {
      escalationId: this.id("esc"),
      question: firstFilled(decision.notify?.body) ?? "Agent needs you",
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
      projectId: this.deps.projectId, terminalId, ...esc,
    }));
    s.escalations.push(esc);
    s.state = "needs_you";
    // The activity row is read, never injected, so the control chars that forced some
    // of these escalations are escaped into view rather than written raw into the feed.
    this.record(terminalId, "escalate", reason, draftReply === "" ? undefined : previewForUser(draftReply));
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  // A warning is both an audit row the user reads later and context the next
  // decide prompt reads immediately; both come from the same list so the Assistant
  // can never be told less than the user was.
  private noteFloorWarnings(terminalId: string, s: ArmedSession, warnings: FloorWarning[]): void {
    for (const w of warnings) {
      this.record(terminalId, "floor_warning", describeWarning(w), w.pattern);
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
   * Take the §5.2 snapshots the about-to-be-injected text calls for. Records and
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
   * parsers disagreeing: a §5.2 shape the floor recognized but the planner
   * produced no plan for would otherwise pass in complete silence, which reads to
   * the user exactly like an action that was fully snapshotted.
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
      if (!action || covered.has(action)) continue;
      this.recordUnprotected(terminalId, s, w.matched, `${action}: the flagged command could not be parsed into a snapshot plan`);
    }
  }

  private recordUnprotected(terminalId: string, s: ArmedSession, trigger: string, detail: string): void {
    const line = `flagged action was not protected: ${trigger}`;
    this.record(terminalId, "floor_warning", line, detail);
    this.rememberWarning(s, line);
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
   * Perform the undo an advertised snapshot promised (§5.2).
   *
   * Deliberately NOT gated on §5.4 authorization: anyone who can drive this
   * project can already drive its terminal, so a second authorization concept
   * would only make the safety net harder to reach than the action it reverses.
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
  // defaultNotifyOnly/defaultTool before anything is armed. Judge choices are
  // per-session now, carried on each session snapshot, and are never cleared
  // by this emit — only arm() touches them.
  emitStatus(): void {
    const sessions = [...this.sessions.entries()].map(([terminalId, s]) => ({
      terminalId,
      notifyOnly: s.notifyOnly,
      state: s.state,
      pendingEscalations: s.escalations.length,
      armedAt: s.armedAt,
      goal: s.goal,
      backlog: s.backlog,
      escalations: s.escalations,
      judgeTool: s.judgeTool,
      judgeModel: s.judgeModel,
      parkKind: s.parkKind,
      parkedUntil: s.parkedUntil,
      // Re-derived on every emit rather than frozen at arm time: a slot's mode
      // and its judge pick both change under a live arm.
      observability: this.observabilityFor(terminalId),
    }));
    this.deps.sendAb(createMessage("handler:status", {
      projectId: this.deps.projectId,
      // What an absent per-session judge resolves to for PTY slots — lets the
      // app label its picker "Default (claude-code)" instead of a bare Default.
      defaultTool: this.deps.tool(),
      defaultNotifyOnly: this.cfg().defaultNotifyOnly,
      sessions,
      // Project-scoped, not per session: an undo offer outlives the session that
      // took it, and an app that restarted between the advert and the tap has no
      // other way back to it.
      snapshots: this.snapshots().map(snapshotWire),
    }));
  }
}
