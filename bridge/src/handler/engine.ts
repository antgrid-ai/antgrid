// bridge/src/handler/engine.ts
import { createMessage, type AbMessage } from "../protocol";
import { classifyDestructive } from "./destructive-floor";
import { RunawayGuard } from "./runaway-guard";
import { assembleContext } from "./context";
import { runPlan as defaultRunPlan, runDecision as defaultRunDecision } from "./judge";
import {
  loadHandlerConfig, appendActivity,
  type HandlerConfig, type ActivityRecord,
} from "./config";
import {
  loadHandlerSession, saveHandlerSession, renderLedger, remainingThenItems,
  type Brief, type LedgerEntry, type HandlerSessionRecord, type OpenEscalation,
} from "./brief";
import { stripAnsi } from "./context";
import type { SessionAdapter } from "./session-adapter";
import { judgeCapable } from "../agents/registry";
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

function wakeClock(at: number): string {
  const d = new Date(at);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
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
  runPlanFn?: typeof defaultRunPlan;
  runDecisionFn?: typeof defaultRunDecision;
  loadConfigFn?: () => HandlerConfig;
  appendActivityFn?: (rec: ActivityRecord) => void;
  loadSessionFn?: (terminalId: string) => HandlerSessionRecord | null;
  saveSessionFn?: (rec: HandlerSessionRecord) => void;
  now?: () => number;
  schedule?: LifecycleDeps["schedule"];
  guard?: RunawayGuard;
}

interface ArmedSession {
  brief: Brief;
  notifyOnly: boolean;
  armedAt: number;
  doneWhenMet: boolean;
  ledger: LedgerEntry[];
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

export class HandlerEngine {
  private guard: RunawayGuard;
  private sessions = new Map<string, ArmedSession>();
  private cachedConfig: HandlerConfig | null = null;
  private seq = 0;
  // Per-terminal decision chain. handleEvent is fire-and-forget from agent-core
  // (each /handler-event POST is unawaited), so two events for one terminal could
  // otherwise run concurrent judge calls that both pass the disarm recheck and both
  // inject — two conflicting replies from one supervised decision. Serialize them.
  private chains = new Map<string, Promise<void>>();
  // Newest event per terminal, for coalescing: events queued behind a slow judge
  // call are stale by the time they'd run (the agent has already moved on), so
  // only the most recent one gets a judge call. Serialization without coalescing
  // would run one full judge spawn (up to 45s) per queued event, composing
  // replies against context the agent left minutes ago.
  private latest = new Map<string, HandlerEvent>();
  private timers: TimerRegistry;

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
  private persist(terminalId: string, s: ArmedSession, armed: boolean): void {
    this.saveSession({
      version: 1, terminalId, armed, brief: s.brief, notifyOnly: s.notifyOnly,
      armedAt: s.armedAt, doneWhenMet: s.doneWhenMet, ledger: s.ledger,
      escalations: s.escalations, judgeTool: s.judgeTool, judgeModel: s.judgeModel,
      parkKind: s.parkKind, parkedUntil: s.parkedUntil, transientFailures: s.transientFailures,
      parkAwaitingJudge: s.parkAwaitingJudge,
    });
  }

  async plan(terminalId: string, judge?: { judgeTool?: string; judgeModel?: string }): Promise<void> {
    const rec = this.loadSession(terminalId);
    const previous = rec?.brief;
    const stored = this.storedJudge(terminalId, rec);
    // One-shot override for THIS call only ('' = force the session default);
    // fall through to the stored choice, then the session's own tool. Not
    // persisted — arming is what persists a judge choice.
    const tool =
      judge?.judgeTool === "" ? this.deps.tool(terminalId)
      : judge?.judgeTool !== undefined && judgeCapable(judge.judgeTool) ? judge.judgeTool
      : stored.tool ?? this.deps.tool(terminalId);
    const model = judge?.judgeModel !== undefined
      ? (judge.judgeModel.trim() || undefined)
      : stored.model;
    const ctx = await assembleContext({
      // The OBSERVED session's tool decides how its transcript is read — the
      // judge choice only swaps who judges.
      tool: this.deps.tool(terminalId),
      transcriptPath: this.deps.adapter.transcriptPath(terminalId),
      agentSessionId: this.deps.agentSessionId?.(terminalId),
      recentPty: await this.deps.adapter.recentOutput(terminalId),
      recentKind: this.deps.adapter.outputKind(terminalId),
      purpose: "plan",
    });
    const runPlanFn = this.deps.runPlanFn ?? defaultRunPlan;
    const brief = await runPlanFn({
      tool, model, context: ctx.text,
      // ctx.transcriptPath is the file the context actually came from (for codex,
      // a rollout path the adapter never knew); judge.ts still gates the hint by tier.
      transcriptPath: ctx.transcriptPath ?? this.deps.adapter.transcriptPath(terminalId),
      cwd: this.deps.projectPath(terminalId),
    });
    this.deps.sendAb(createMessage("handler:planResult", {
      projectId: this.deps.projectId,
      terminalId,
      fallback: brief === null,
      brief: brief ?? undefined,
      previousBrief: previous,
      // STORED judge, not the override: this echo is how a freshly restarted
      // app seeds the sheet's picker for a disarmed session.
      judgeTool: stored.tool,
      judgeModel: stored.model,
    }));
  }

  arm(p: { terminalId: string; brief: Brief; notifyOnly: boolean; judgeTool?: string; judgeModel?: string }): void {
    const existing = this.sessions.get(p.terminalId);
    if (existing) {
      // Mutate in place, never replace: an in-flight judge call holds a reference
      // to this session and re-checks identity after its await — swapping in a
      // fresh object would silently drop that decision and leave the copied
      // "handling" state with nothing left to reset it. Edited brief keeps the
      // ledger (spec: mid-flight edits preserve it); items no longer in
      // thenItems simply stop rendering as remaining.
      existing.brief = p.brief;
      existing.notifyOnly = p.notifyOnly;
      this.applyJudgeChoice(existing, p);
      this.persist(p.terminalId, existing, true);
      this.record(p.terminalId, "brief_edited", p.brief.taskSummary);
      this.emitStatus();
      return;
    }
    // No in-memory session, but a bridge restart leaves the persisted record
    // behind — rehydrate ledger/escalations/doneWhenMet from it so re-arming
    // doesn't clobber progress the previous process already banked.
    const rec = this.loadSession(p.terminalId);
    const resumed = rec?.armed ? rec : null;
    const stored = this.storedJudge(p.terminalId, rec);
    const s: ArmedSession = {
      brief: p.brief,
      notifyOnly: p.notifyOnly,
      armedAt: resumed?.armedAt ?? this.now(),
      doneWhenMet: resumed?.doneWhenMet ?? false,
      ledger: resumed?.ledger ?? [],
      state: resumed && resumed.escalations.length > 0 ? "needs_you" : "watching",
      escalations: resumed?.escalations ?? [],
      // Seed from the persisted record (armed pre-restart OR the last disarmed
      // pick), then let an explicit choice on this arm override it.
      judgeTool: stored.tool,
      judgeModel: stored.model,
      transientFailures: resumed?.transientFailures ?? 0,
      limitParks: 0,
    };
    this.applyJudgeChoice(s, p);
    this.sessions.set(p.terminalId, s);
    this.persist(p.terminalId, s, true);
    this.record(p.terminalId, resumed ? "brief_edited" : "brief_armed", s.brief.taskSummary);
    this.emitStatus();
    // Rehydrated last, so the arm record still reads as the session's opening
    // line and a deadline already past can resume straight into the new process.
    if (resumed?.parkKind && resumed.parkedUntil !== undefined) {
      this.rehydratePark(p.terminalId, s, resumed.parkKind, resumed.parkedUntil, resumed.parkAwaitingJudge);
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

  disarm(terminalId: string): void {
    const s = this.sessions.get(terminalId);
    if (!s) return;
    this.sessions.delete(terminalId);
    this.latest.delete(terminalId);
    this.unparkIfParked(terminalId, s);
    this.persist(terminalId, s, false);
    this.guard.reset(terminalId);
    this.emitStatus();
  }

  onUserReply(terminalId: string, data: string): void {
    this.guard.reset(terminalId);
    const s = this.sessions.get(terminalId);
    if (!s) return;
    // Called per terminal:input (every keystroke), so the submitted-line test
    // comes first: typing into an armed terminal must not cost one disk write +
    // one encrypted status broadcast per character.
    if (!/[\r\n]/.test(data)) return;
    // A human at the keyboard ends a park — before the escalations-empty
    // early-return below, which a parked session normally satisfies.
    const unparked = this.unparkIfParked(terminalId, s);
    // Pending escalations clear only on a SUBMITTED line — a stray keypress must
    // not silently swallow an unanswered question — and a submit clears ALL of
    // them: once a human line reaches the agent, every earlier pause-question
    // for this terminal is stale (each pause supersedes the last).
    if (!unparked && s.escalations.length === 0) return;
    s.escalations = [];
    // A human line is a fresh attempt, so the failure series that led here is
    // over. Without this the counters stay at their ceiling — only a judged turn
    // clears transientFailures — and the very next failure would page again
    // instead of backing off.
    s.transientFailures = 0;
    s.limitParks = 0;
    s.state = "watching";
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

  // A driver withdrew its pending permission/question (agent:request-retracted):
  // the forced escalation now points at a prompt that no longer exists. Clear
  // pending escalations — same all-at-once semantics as onUserReply, each pause
  // supersedes the last — WITHOUT resetting the runaway guard: retraction is
  // the agent moving on, not a human answering.
  onPromptRetracted(terminalId: string): void {
    // Drop a queued blocking-prompt event, BEFORE the escalations-empty guard: a
    // permission/question event can still be waiting behind an earlier slow judge
    // call (handleEvent's coalescing chain) when the retraction lands, so
    // s.escalations is empty here even though `latest` still points at the
    // not-yet-run event. Leaving it would let the coalescing check in handleEvent
    // (`this.latest.get(id) === evt`) match on dequeue and resurrect an escalation
    // for a prompt the driver already retracted.
    //
    // Scoped to blocking prompts, NOT unconditional: drivers send agent:turn-end
    // and then call retractAllPending() synchronously in the same stack (claude's
    // endActiveTurnOnFailure/onResult, codex's turn-complete handler), so a
    // blanket delete swallows the turn_end queued microseconds earlier — leaving
    // an armed session watching a dead agent on exactly the "stream died mid-turn
    // while a prompt was outstanding" case turn_end-on-error exists to catch.
    if (isBlockingPrompt(this.latest.get(terminalId))) this.latest.delete(terminalId);
    const s = this.sessions.get(terminalId);
    if (!s) return;
    // Also before the escalations-empty return: a parked session normally has
    // none, so an unpark placed after it would be dead code.
    const unparked = this.unparkIfParked(terminalId, s);
    if (!unparked && s.escalations.length === 0) return;
    s.escalations = [];
    s.state = "watching";
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  // Ends a park without recording anything: the caller (human input, a blocking
  // prompt, disarm) is itself the reason the wait is over.
  private unparkIfParked(terminalId: string, s: ArmedSession): boolean {
    if (s.state !== "parked") return false;
    this.timers.cancel(terminalId);
    // An escalation the user never answered outlives the park it was parked
    // through, so the pill must go back to needs_you — "watching" with a
    // pending row is a state the rest of the engine never produces.
    s.state = s.escalations.length > 0 ? "needs_you" : "watching";
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
   * `keepArmed` is for a session:set-mode flip, where the runtime is being
   * swapped underneath a session that itself survives. The supervisor is keyed
   * by session id, so disarming there would answer "I changed how I'm viewing
   * this" with "your supervision is off". It must SUPPRESS the disarm rather
   * than re-arm afterwards: disarm() persists the record as unarmed, and a
   * later arm() rehydrates only from an armed record — so the round trip would
   * quietly reset the ledger, armedAt and any open escalations.
   */
  onTerminalExit(terminalId: string, opts?: { keepArmed?: boolean }): void {
    this.guard.reset(terminalId);
    if (!this.sessions.has(terminalId)) return;
    if (opts?.keepArmed) return;
    this.disarm(terminalId);
  }

  handleEvent(evt: HandlerEvent): Promise<void> {
    // Tack this event onto the terminal's chain; a prior event's rejection must
    // not block later events, so swallow it before running ours. At dequeue
    // time, run only if this is still the newest event for the terminal —
    // anything superseded while waiting is dropped, not judged.
    //
    // Lifecycle events sit outside that rule entirely: a limit_hit and a later
    // turn_end mean different things, so neither may supersede the other. They
    // still ride the chain, so they cannot race a judge call already in flight.
    const lifecycle = isLifecycle(evt);
    if (!lifecycle) this.latest.set(evt.terminalId, evt);
    const prev = this.chains.get(evt.terminalId) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(() =>
      lifecycle || this.latest.get(evt.terminalId) === evt ? this.handleEventInner(evt) : undefined);
    this.chains.set(evt.terminalId, next);
    const done = () => { if (this.chains.get(evt.terminalId) === next) this.chains.delete(evt.terminalId); };
    next.then(done, done);
    return next;
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
      }, undefined, undefined, "resolve_in_session");
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
        tool: s.judgeTool ?? tool, model: s.judgeModel, brief: s.brief,
        ledgerText: renderLedger(s.brief, s.ledger),
        context: ctx.text, transcriptPath: ctx.transcriptPath ?? transcriptPath,
        cwd: this.deps.projectPath(evt.terminalId),
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
      this.absorbLedger(evt.terminalId, s, decision);
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

        const floor = classifyDestructive(probe, this.deps.projectPath(evt.terminalId), reply);
        if (floor.blocked) return this.escalate(evt.terminalId, s, decision, `floor: ${floor.reason}`, floor.reason);

        const guardReason = this.guard.check(evt.terminalId, probe);
        if (guardReason) return this.escalate(evt.terminalId, s, decision, guardReason);

        this.deps.adapter.injectReply(evt.terminalId, written);
        this.guard.recordAutoReply(evt.terminalId, probe);
        this.record(evt.terminalId, "handle", decision.reason, written);
        if (this.maybeWrapUp(evt.terminalId, s)) return;
        s.state = "watching";
        this.persist(evt.terminalId, s, true);
        this.emitStatus();
        return;
      }

      if (decision.decision === "continue") {
        this.record(evt.terminalId, "continue", decision.reason);
        if (this.maybeWrapUp(evt.terminalId, s)) return;
        s.state = "watching";
        this.persist(evt.terminalId, s, true);
        this.emitStatus();
        return;
      }

      // escalate: deliberately no wrap-up check — an escalation with doneWhenMet
      // stays pending for the human; auto-disarming would bury the question.
      this.escalate(evt.terminalId, s, decision);
    } catch (err) {
      // A wrap-up (or a concurrent disarm) may already have dropped this
      // session; resetting its state here would re-persist it as armed.
      if (this.sessions.get(evt.terminalId) === s) {
        s.state = s.escalations.length > 0 ? "needs_you" : "watching";
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
      }
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

  // Record judge-declared satisfied items (dedup by exact item string) and count
  // progress toward the runaway guard: real progress is evidence of non-looping.
  private absorbLedger(terminalId: string, s: ArmedSession, decision: HandlerDecision): void {
    // Only the brief's own follow-ups count as satisfied. The judge is untrusted:
    // if arbitrary item strings were accepted, a looping judge could mint a fresh
    // fake "satisfied" item every turn, and since progress resets the runaway
    // guard's consecutive counter, that would let it drive unbounded auto-replies
    // past the cap. Bounding to thenItems caps total progress at |thenItems| (a
    // user-defined, finite set) — and matches remainingThenItems, which already
    // measures completion by exact-string membership in thenItems.
    const allowed = new Set(s.brief.thenItems);
    let progressed = false;
    for (const it of decision.satisfiedItems ?? []) {
      if (!allowed.has(it.item)) continue;
      if (s.ledger.some((e) => e.item === it.item)) continue;
      s.ledger.push({ item: it.item, evidence: it.evidence, at: this.now() });
      this.record(terminalId, "item_satisfied", it.item, it.evidence);
      progressed = true;
    }
    if (decision.doneWhenMet && s.brief.doneWhen) s.doneWhenMet = true;
    if (progressed) this.guard.recordProgress(terminalId);
    if (progressed || decision.doneWhenMet) this.persist(terminalId, s, true);
  }

  // Auto-disarm only when the brief defines an end: doneWhen (judged met, sticky)
  // and/or thenItems (all satisfied). Neither defined → supervise until disarmed.
  // Called only from the handle/continue branches — never on escalate.
  private maybeWrapUp(terminalId: string, s: ArmedSession): boolean {
    // A wrap-up disarms the session. Never do that while a human question is
    // outstanding: an earlier escalate may have carried doneWhenMet (absorbLedger
    // runs on every decision, including escalate), so a later handle/continue
    // could otherwise auto-disarm and silently bury the unanswered escalation.
    if (s.escalations.length > 0) return false;
    const hasDone = !!s.brief.doneWhen;
    const hasThen = s.brief.thenItems.length > 0;
    if (!hasDone && !hasThen) return false;
    if (hasDone && !s.doneWhenMet) return false;
    if (hasThen && remainingThenItems(s.brief, s.ledger).length > 0) return false;
    this.record(terminalId, "wrapped_up", s.brief.doneWhen ?? "all follow-ups satisfied", s.brief.taskSummary);
    // The push is the morning-after summary (spec: "summarizes the ledger") —
    // name what got done, don't just count it. Capped so a long thenItems list
    // can't blow past OS notification limits.
    const items = s.ledger.map((e) => e.item);
    const shown = items.slice(0, 3).join(", ");
    const more = items.length > 3 ? ` +${items.length - 3} more` : "";
    const summary = items.length > 0 ? `. Done: ${shown}${more}` : "";
    this.deps.sendPush?.(`Handler: done — ${s.brief.taskSummary}${summary}`, terminalId);
    this.disarm(terminalId);
    return true;
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
  ): void {
    const reason = forcedReason ?? decision.reason;
    const esc: OpenEscalation = {
      escalationId: this.id("esc"),
      question: decision.notify?.body ?? "Agent needs you",
      reasoning: reason,
      draftReply: decision.notify?.draftReply ?? decision.reply ?? "",
      urgency: decision.notify?.urgency ?? "normal",
      floorRule,
      kind,
      at: this.now(),
    };
    this.deps.sendAb(createMessage("handler:escalation", {
      projectId: this.deps.projectId, terminalId, ...esc,
    }));
    s.escalations.push(esc);
    s.state = "needs_you";
    this.record(terminalId, "escalate", reason, decision.notify?.draftReply ?? decision.reply);
    this.persist(terminalId, s, true);
    this.emitStatus();
  }

  private record(terminalId: string, decision: ActivityRecord["decision"], reason: string, detail?: string): void {
    const rec: ActivityRecord = { recordId: this.id("rec"), at: this.now(), terminalId, decision, reason, detail };
    (this.deps.appendActivityFn ?? ((r: ActivityRecord) => appendActivity(this.deps.abDir, this.deps.projectId, r)))(rec);
    this.deps.sendAb(createMessage("handler:activity", {
      projectId: this.deps.projectId, recordId: rec.recordId, at: rec.at, terminalId, decision, reason, detail,
    }));
  }

  // Public: agent-core also emits on every app handshake so a fresh app sees
  // defaultNotifyOnly/defaultTool before anything is armed. Judge choices are
  // per-session now, carried on each session snapshot, and are never cleared
  // by this emit — only arm()/plan() touch them.
  emitStatus(): void {
    const sessions = [...this.sessions.entries()].map(([terminalId, s]) => ({
      terminalId,
      notifyOnly: s.notifyOnly,
      state: s.state,
      pendingEscalations: s.escalations.length,
      armedAt: s.armedAt,
      doneWhenMet: s.doneWhenMet,
      brief: s.brief,
      ledger: s.ledger,
      escalations: s.escalations,
      judgeTool: s.judgeTool,
      judgeModel: s.judgeModel,
      parkKind: s.parkKind,
      parkedUntil: s.parkedUntil,
    }));
    this.deps.sendAb(createMessage("handler:status", {
      projectId: this.deps.projectId,
      // What an absent per-session judge resolves to for PTY slots — lets the
      // app label its picker "Default (claude-code)" instead of a bare Default.
      defaultTool: this.deps.tool(),
      defaultNotifyOnly: this.cfg().defaultNotifyOnly,
      sessions,
    }));
  }
}
