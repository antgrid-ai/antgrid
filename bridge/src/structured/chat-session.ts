// The half of a chat driver that is not about any one agent: turns, prompts,
// retraction, capabilities, config picks, item emission and transcript
// containment. Every `agent:*` frame a chat session puts on the wire is built
// here, so the three backends can only disagree about what their provider says,
// never about what the app receives.
//
// A backend subclasses this and fills in the abstract half — boot, prompt
// delivery, interrupt, compact, revert, discovery and transcript re-derivation
// — reaching the shared machinery through the protected members below. It is a
// base class rather than a collaborator object because the two halves share
// state (the live turn id, the current selection, the disposed flag) that a
// message-passing seam would have to re-expose accessor by accessor.

import { createMessage, createTranscriptReplay, type AbMessage, type AgentError, type AgentItem } from "../protocol";
import { resolveConfigPick, type ConfigPick } from "./set-config";
import type { AgentUsageBreakdown } from "./normalize";
import type { StructuredDriver } from "./structured-manager";
import { logger } from "../logger";

const log = logger.child({ component: "chat-session" });

/** Static facts the shared machinery branches on. Each exists because the
 *  backends genuinely disagree about it; none is a preference. */
export interface ChatSessionProfile {
  /**
   * Who names turns. "session" mints `turn-<n>` inside prompt() (claude,
   * opencode); "backend" means the provider names the turn and the backend
   * opens it from its own event (codex's turn/started).
   */
  turnSource: "session" | "backend";
  /**
   * True when an item frame carries only the CHANGED fields and the session
   * must merge it over the cached item (claude's tool_use → tool_result
   * completion). False when the backend's mapper builds the whole item every
   * time (codex, opencode).
   */
  mergeItems: boolean;
  /**
   * False when a transcript snapshot taken mid-turn cannot be trusted, so the
   * session answers [] while a turn is open. opencode's history carries no
   * per-turn status to filter by; codex filters by status and claude reads a
   * settled file, so both are true.
   */
  snapshotDuringTurn: boolean;
  /**
   * What the backend's interrupt actually stops. "turn" backends refuse a
   * cancel with no live turn outright. "session" (opencode) aborts the whole
   * session, so it must still fire when the turn bookkeeping says nothing is
   * running — the abort is the only thing that stops work the session lost
   * track of — and it reports back whether a turn was in fact open.
   */
  interruptScope: "turn" | "session";
}

/** A retraction handle over a set of prompts a backend must withdraw together
 *  (codex answers one RPC for a whole `questions[]` batch, and codex may
 *  withdraw that RPC on its own via serverRequest/resolved). */
export interface PromptGroup {
  retract(): void;
}

class PromptGroupImpl implements PromptGroup {
  readonly ids = new Set<string>();
  done = false;
  constructor(private readonly fire: (g: PromptGroupImpl) => void) {}
  retract(): void {
    this.fire(this);
  }
}

interface Pending<V> {
  answer: (value: V | null) => void;
  group?: PromptGroupImpl;
  /** Option labels indexed by the synthetic id the app echoes back. */
  labels?: readonly string[];
  /** Collapse a multi-value answer to its first element before translating.
   *  Set by backends that never raise a multi_select, so an array arriving from
   *  a client that thinks otherwise degrades to one answer instead of a list the
   *  provider cannot take. */
  single?: boolean;
}

/** What a driver may put in an agent:usage frame: the mapper-shared breakdown
 *  plus the two counters only some providers report. */
type UsageBreakdown = AgentUsageBreakdown & { cacheWriteTokens?: number; costUsd?: number };

export type CapModel = { id: string; name: string; efforts?: string[]; defaultEffort?: string; provider?: string };
export type CapMode = { id: string; name: string; description?: string };
export type CapCommand = { id: string; name: string; description?: string; argHint?: string };

/** The previous selection, handed to `applySelection` so a backend whose
 *  provider REJECTS a pick can roll the optimistic write back per axis — a
 *  single combined undo would clobber an axis the rejection never touched. */
export interface SelectionSnapshot {
  model?: string;
  mode?: string;
  effort?: string;
  modelExplicit: boolean;
  effortExplicit: boolean;
}

export interface ChatSessionOpts {
  sessionId: string;
  sendMessage: (m: AbMessage) => void;
}

/** A permission prompt as a backend describes it. `permissionId` is supplied
 *  only by a backend whose provider names the prompt itself (opencode); every
 *  other backend lets the session mint one. */
export interface PermissionRequest {
  permissionId?: string;
  itemId?: string;
  title: string;
  reason?: string;
  options: ReadonlyArray<{ optionId: string; label: string; kind: "allow_once" | "allow_always" | "reject" }>;
}

export interface QuestionRequest {
  questionId?: string;
  itemId?: string;
  kind: "text" | "single_select" | "multi_select";
  prompt: string;
  isSecret?: boolean;
  options?: ReadonlyArray<{ id: string; label: string; description?: string }>;
}

export abstract class ChatSession implements StructuredDriver {
  protected readonly sessionId: string;
  protected readonly send: (m: AbMessage) => void;
  protected abstract readonly profile: ChatSessionProfile;

  // --- turn lifecycle ---
  protected activeTurnId: string | null = null;
  /** How many turns this session has minted. Protected because claude keys its
   *  compaction marker off it when the SDK's chunk carries no uuid. */
  protected turnCounter = 0;
  /** True once cancel() ran; cleared at every turn boundary so a cancel whose
   *  turn-end never arrived cannot mislabel the next turn. */
  protected cancelRequested = false;
  /** Set by dispose(); every async continuation must check it before emitting. */
  protected disposed = false;

  // --- items ---
  /** itemId first-sighting tracker: first → item-added, later → item-updated. */
  private seenItems = new Set<string>();
  /** Last full item per id, for backends whose frames are partial (mergeItems). */
  private itemCache = new Map<string, Record<string, unknown>>();

  // --- prompts ---
  private pendingApprovals = new Map<string, Pending<string>>();
  private pendingQuestions = new Map<string, Pending<string | string[]>>();
  private approvalCounter = 0;
  private questionCounter = 0;

  // --- capabilities + selection ---
  protected capModels: CapModel[] = [];
  protected capModes: CapMode[] = [];
  protected capCommands: CapCommand[] = [];
  protected selModel?: string;
  protected selMode?: string;
  protected selEffort?: string;
  /** The user pinned this axis — blocks a backend's own default seeding and,
   *  for claude, the system:init reconciliation. */
  protected modelExplicit = false;
  protected effortExplicit = false;
  protected capsDiscovered = false;
  /** Picks that arrived before discovery populated the lists (a resumed session
   *  replays yesterday's pickers to the app instantly, while discovery is still
   *  in flight). Queued and validated once discovery lands, instead of being
   *  silently rejected against empty lists. */
  private pendingConfig: Array<{ key: string; value: string }> = [];
  /** Newest in-flight pick per axis, so a slow rejection can tell whether it
   *  still owns the selection it wants to roll back. */
  private pickSeq = new Map<string, number>();

  constructor(opts: ChatSessionOpts) {
    this.sessionId = opts.sessionId;
    this.send = opts.sendMessage;
  }

  // ==========================================================================
  // The per-agent half.
  // ==========================================================================

  /** Boot the backend; return its native session id, or "" when the id only
   *  arrives asynchronously (claude reports it on system:init). */
  protected abstract startBackend(resumeId?: string): Promise<string>;
  /** Deliver one user turn. For turnSource "session" the turn is already open. */
  protected abstract sendPrompt(text: string, commandId?: string): Promise<void>;
  /** Stop the live turn. The session has already validated the turnId and
   *  recorded the cancel intent. */
  protected abstract interrupt(turnId: string): Promise<void>;
  /** Re-derive the completed-turn transcript. The session owns the mid-turn
   *  guard and the error containment. */
  protected abstract transcriptSnapshot(): Promise<AbMessage[]>;
  protected abstract disposeBackend(): void | Promise<void>;

  abstract compact(): Promise<void>;
  abstract revert(target: { turnId?: string; itemId?: string; messageId?: string; partId?: string }): Promise<void>;

  /** Runs before the compact/turn-open handling of prompt(): claude refuses a
   *  prompt before start(), opencode lazily creates its session. */
  protected preparePrompt(): void | Promise<void> {}
  /** Backend-owned per-turn state to drop at a turn boundary (codex's reasoning
   *  channel claims, opencode's message roles). */
  protected clearTurnState(): void {}
  /** The model to advertise when the user has pinned none — opencode tracks one
   *  off the last assistant message. Absent for backends that don't. */
  protected liveModelId(): string | undefined {
    return undefined;
  }
  /** Veto beyond resolveConfigPick — opencode rejects a model id with no "/". */
  protected validateSelection(_pick: ConfigPick): boolean {
    return true;
  }
  /** Push a validated selection to the provider. The optimistic write has
   *  already happened; `prev` is what to restore if the provider refuses. */
  protected applySelection(_pick: ConfigPick, _prev: SelectionSnapshot): void {}
  /** Answer for a questionId the session has no pending entry for. opencode
   *  replies anyway (its ids are the provider's own, and a retracted prompt the
   *  user still answered is worth forwarding); every other backend drops it. */
  protected resolveUnknownQuestion(_questionId: string, _answer: string | string[]): void {}

  // ==========================================================================
  // StructuredDriver
  // ==========================================================================

  async start(resumeId?: string): Promise<string> {
    // Advertise an empty, not-ready catalog immediately so the app renders a
    // loading state for this session before the backend has booted at all —
    // claude's SDK does not even spawn its subprocess until the first prompt.
    this.emitCapabilities();
    return this.startBackend(resumeId);
  }

  async prompt(text: string, commandId?: string): Promise<void> {
    await this.preparePrompt();
    // compact drives its own lifecycle (same contract as agent:session-action).
    if (commandId === "builtin:compact") return this.compact();
    if (this.profile.turnSource === "session") this.openTurn();
    return this.sendPrompt(text, commandId);
  }

  async cancel(turnId?: string): Promise<boolean> {
    const turnScoped = this.profile.interruptScope === "turn";
    if (turnScoped) {
      if (!this.activeTurnId) return false;
      // A turnId naming anything but the live turn comes from a client whose
      // turn-end was lost: interrupting would stop a turn the user never asked
      // to stop. Refuse, so the manager answers that phantom with its own
      // turn-end (returning true would suppress it and strand the turn open
      // forever). Absent turnId = cancel whatever is live.
      if (turnId && turnId !== this.activeTurnId) return false;
    } else {
      if (!this.interruptReady()) return false;
      // Same refusal, but gated on activeTurnId too: a turnId arriving with
      // nothing running still falls through to the abort-regardless path.
      if (turnId && this.activeTurnId && turnId !== this.activeTurnId) return false;
    }
    this.cancelRequested = true;
    await this.interrupt(this.activeTurnId ?? "");
    // A turn-scoped interrupt proved a live turn in the guard above and its
    // backend closes that turn, so the answer is true even when the backend's
    // own turn-end landed while the interrupt was still in flight — reading
    // activeTurnId here would report false and have the manager answer with a
    // SECOND, synthetic turn-end for a turn already closed. Only the
    // session-scoped abort reports from activeTurnId: it resolves whether or
    // not a turn was running, and its turn-end comes from the provider's
    // resulting idle event, which arrives only if one was.
    return turnScoped || this.activeTurnId !== null;
  }

  setConfig(key: string, value: unknown): void {
    if (typeof value !== "string") return;
    if (!this.capsDiscovered) {
      this.pendingConfig.push({ key, value });
      return;
    }
    if (this.applyConfig(key, value)) this.emitCapabilities();
  }

  async getTranscriptSnapshot(): Promise<AbMessage[]> {
    if (!this.profile.snapshotDuringTurn && this.activeTurnId !== null) return [];
    try {
      return await this.transcriptSnapshot();
    } catch (err) {
      log.warn("transcript snapshot failed for session %s: %s", this.sessionId, err);
      return [];
    }
  }

  resolvePermission(permissionId: string, optionId: string): void {
    const pending = this.pendingApprovals.get(permissionId);
    if (!pending) return;
    this.pendingApprovals.delete(permissionId);
    this.settleGroup(permissionId, pending.group);
    pending.answer(optionId);
  }

  resolveQuestion(questionId: string, answer: string | string[]): void {
    const pending = this.pendingQuestions.get(questionId);
    if (!pending) return this.resolveUnknownQuestion(questionId, answer);
    this.pendingQuestions.delete(questionId);
    this.settleGroup(questionId, pending.group);
    pending.answer(translateAnswer(answer, pending));
  }

  dispose(): void | Promise<void> {
    // Withdraw anything still on screen BEFORE the disposed flag goes up, so a
    // prompt torn down mid-turn (LRU eviction, focus disposal) doesn't wedge.
    this.retractAllPending();
    this.disposed = true;
    return this.disposeBackend();
  }

  // ==========================================================================
  // Turns
  // ==========================================================================

  /** Open a turn and emit agent:turn-start. Pass `turnId` when the provider
   *  named it (turnSource "backend"); omit to mint `turn-<n>`. A backend whose
   *  event carried no id gets a null active turn and a turn-start naming "",
   *  which is what the app already receives today. */
  protected openTurn(turnId?: string | null): void {
    this.activeTurnId = turnId === undefined ? `turn-${this.turnCounter++}` : turnId;
    // Each new turn starts clean: a cancel whose turn-end never arrived must
    // not bleed a stale intent into this one.
    this.cancelRequested = false;
    this.send(createMessage("agent:turn-start", {
      sessionId: this.sessionId,
      turnId: this.activeTurnId ?? "",
    }));
  }

  /** Emit agent:turn-end and run the turn-boundary teardown. `turnId` overrides
   *  the open one (codex's turn/completed carries its own). */
  protected closeTurn(o: { stopReason: "end_turn" | "cancelled" | "error"; error?: AgentError; turnId?: string }): void {
    this.send(createMessage("agent:turn-end", {
      sessionId: this.sessionId,
      turnId: o.turnId ?? this.activeTurnId ?? "",
      stopReason: o.stopReason,
      ...(o.error ? { error: o.error } : {}),
    }));
    this.endTurn();
  }

  /** Turn-boundary teardown without a turn-end frame — for a reset that ends the
   *  turn by discarding it (opencode's revert) rather than by finishing it. */
  protected endTurn(): void {
    this.activeTurnId = null;
    this.cancelRequested = false;
    // Per-turn item state is only meaningful within a turn; clearing it keeps
    // these maps bounded across a long session and lets an item id reused next
    // turn re-emit item-added as a first sighting.
    this.seenItems.clear();
    this.itemCache.clear();
    this.clearTurnState();
    this.retractAllPending();
  }

  /** Whether a session-scoped interrupt can be issued at all (opencode has no
   *  session to abort before start() resolves). */
  protected interruptReady(): boolean {
    return true;
  }

  // ==========================================================================
  // Items and other frames
  // ==========================================================================

  /** Emit agent:item-added / item-updated. `added` overrides the session's
   *  first-sighting set (codex drives added/updated off its own item/started vs
   *  item/completed events). `parentItemId` rides only the ADD frame: the app
   *  anchors a child once, and later updates carry it inside `item`. */
  protected emitItem(
    itemId: string,
    fields: Record<string, unknown>,
    o: { turnId: string; added?: boolean; parentItemId?: string },
  ): void {
    let added = o.added;
    if (added === undefined) {
      added = !this.seenItems.has(itemId);
      this.seenItems.add(itemId);
    }
    let item: Record<string, unknown> = fields;
    if (this.profile.mergeItems) {
      // The app treats each item frame as a full replacement, so a partial
      // update (e.g. tool completion) merges over the cached item.
      item = { ...this.itemCache.get(itemId), ...fields, itemId };
      this.itemCache.set(itemId, item);
    }
    this.send(createMessage(added ? "agent:item-added" : "agent:item-updated", {
      sessionId: this.sessionId,
      turnId: o.turnId,
      itemId,
      ...(added && o.parentItemId ? { parentItemId: o.parentItemId } : {}),
      item: item as AgentItem,
    }));
  }

  protected emitDelta(itemId: string, textChunk: string, turnId: string): void {
    this.send(createMessage("agent:item-delta", {
      sessionId: this.sessionId,
      turnId,
      itemId,
      textChunk,
    }));
  }

  /** The synthetic `plan:<turnId>` item, always as item-updated: a plan is one
   *  row the whole turn long, so first-sighting bookkeeping would only decide
   *  which frame name carries an identical payload. */
  protected emitPlan(turnId: string, entries: ReadonlyArray<{ text: string; status: string }>): void {
    const itemId = `plan:${turnId}`;
    this.send(createMessage("agent:item-updated", {
      sessionId: this.sessionId,
      turnId,
      itemId,
      item: { itemId, kind: "plan", entries } as AgentItem,
    }));
  }

  protected emitUsage(u: {
    turnId?: string;
    total: UsageBreakdown;
    last?: UsageBreakdown;
    contextWindow?: number | null;
  }): void {
    this.send(createMessage("agent:usage", {
      sessionId: this.sessionId,
      ...(u.turnId !== undefined ? { turnId: u.turnId } : {}),
      total: u.total,
      ...(u.last !== undefined ? { last: u.last } : {}),
      ...(u.contextWindow !== undefined ? { contextWindow: u.contextWindow } : {}),
    }));
  }

  protected emitError(error: AgentError): void {
    this.send(createMessage("agent:error", { sessionId: this.sessionId, error }));
  }

  protected emitSessionReset(): void {
    this.send(createMessage("agent:session-reset", { sessionId: this.sessionId }));
  }

  /** Replayed history reaches the app as ONE frame: sent per item, a long
   *  transcript overruns the relay's per-pair rate limit and the dropped tail
   *  takes agent:turn-end with it. */
  protected emitTranscriptReplay(frames: AbMessage[]): void {
    const replay = createTranscriptReplay(this.sessionId, frames);
    if (replay) this.send(replay);
  }

  // ==========================================================================
  // Prompts (permissions + questions)
  // ==========================================================================

  /** Open a retraction group; `retract()` withdraws every still-open prompt in
   *  it (each answered with null) and emits their agent:request-retracted. */
  protected promptGroup(): PromptGroup {
    return new PromptGroupImpl((g) => this.retractGroup(g));
  }

  /** Emit agent:permission-request. `permissionId` is supplied only by a
   *  backend whose provider names the prompt itself (opencode); the rest mint. */
  protected askPermission(
    req: PermissionRequest,
    answer: (optionId: string | null) => void,
    group?: PromptGroup,
  ): string {
    const permissionId = req.permissionId ?? `perm-${this.approvalCounter++}`;
    const g = group as PromptGroupImpl | undefined;
    this.pendingApprovals.set(permissionId, { answer, group: g });
    g?.ids.add(permissionId);
    this.send(createMessage("agent:permission-request", {
      sessionId: this.sessionId,
      permissionId,
      ...(req.itemId !== undefined ? { itemId: req.itemId } : {}),
      title: req.title,
      ...(req.reason !== undefined ? { reason: req.reason } : {}),
      options: req.options as Array<{ optionId: string; label: string; kind: "allow_once" | "allow_always" | "reject" }>,
    }));
    return permissionId;
  }

  /** Emit agent:question. `labels` lets the session translate the synthetic
   *  index id the app echoes back into the label the backend answers by. */
  protected askQuestion(
    req: QuestionRequest,
    answer: (value: string | string[] | null) => void,
    o?: { labels?: readonly string[]; group?: PromptGroup; single?: boolean },
  ): string {
    const questionId = req.questionId ?? `q-${this.questionCounter++}`;
    const g = o?.group as PromptGroupImpl | undefined;
    this.pendingQuestions.set(questionId, {
      answer,
      group: g,
      ...(o?.labels ? { labels: o.labels } : {}),
      ...(o?.single ? { single: true } : {}),
    });
    g?.ids.add(questionId);
    this.send(createMessage("agent:question", {
      sessionId: this.sessionId,
      questionId,
      ...(req.itemId !== undefined ? { itemId: req.itemId } : {}),
      kind: req.kind,
      prompt: req.prompt,
      ...(req.isSecret ? { isSecret: true } : {}),
      ...(req.options ? { options: req.options as Array<{ id: string; label: string; description?: string }> } : {}),
    }));
    return questionId;
  }

  /** Withdraw every prompt still open: emit agent:request-retracted and answer
   *  each with null so the backend can close out whatever it owes its provider. */
  protected retractAllPending(): void {
    // Snapshot then clear before invoking callbacks: an answer callback may
    // synchronously touch the maps, so iterating them live is needlessly
    // fragile. Permissions before questions, which is the order the app has
    // always seen them withdrawn in.
    const approvals = [...this.pendingApprovals];
    this.pendingApprovals.clear();
    for (const [permissionId, p] of approvals) {
      this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, permissionId }));
      this.settleGroup(permissionId, p.group);
      p.answer(null);
    }
    const questions = [...this.pendingQuestions];
    this.pendingQuestions.clear();
    for (const [questionId, p] of questions) {
      this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, questionId }));
      this.settleGroup(questionId, p.group);
      p.answer(null);
    }
  }

  private retractGroup(group: PromptGroupImpl): void {
    if (group.done) return;
    group.done = true;
    for (const id of [...group.ids]) {
      group.ids.delete(id);
      const approval = this.pendingApprovals.get(id);
      if (approval) {
        this.pendingApprovals.delete(id);
        this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, permissionId: id }));
        approval.answer(null);
        continue;
      }
      const question = this.pendingQuestions.get(id);
      if (question) {
        this.pendingQuestions.delete(id);
        this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, questionId: id }));
        question.answer(null);
      }
    }
  }

  private settleGroup(id: string, group: PromptGroupImpl | undefined): void {
    if (!group) return;
    group.ids.delete(id);
    if (group.ids.size === 0) group.done = true;
  }

  // ==========================================================================
  // Capabilities + config
  // ==========================================================================

  /**
   * The three `current*` keys are emitted in one fixed order for every backend,
   * where the drivers used to disagree (claude put mode before effort, codex and
   * opencode the reverse). Nothing downstream reads JSON key order: the relay
   * routes ciphertext, the app field-addresses `AgentCapabilities`, and the
   * MessageBus dedup/replay cache compares payloads it stringified itself, so a
   * consistent new order stays internally consistent.
   */
  protected emitCapabilities(): void {
    const currentModelId = this.selModel ?? this.liveModelId();
    this.send(createMessage("agent:capabilities", {
      sessionId: this.sessionId,
      // Not-ready until a real catalog lands, so the app renders a loading
      // state rather than an empty selector row.
      ready: this.capsDiscovered,
      commands: this.capCommands,
      modes: this.capModes,
      models: this.capModels,
      ...(currentModelId ? { currentModelId } : {}),
      ...(this.selMode ? { currentModeId: this.selMode } : {}),
      ...(this.selEffort ? { currentEffortId: this.selEffort } : {}),
    }));
  }

  /** Open the config gate: flush the picks queued before discovery, then
   *  advertise. A backend whose discovery came back EMPTY must not call this —
   *  the queued picks would flush against nothing and be dropped, with no later
   *  discovery able to recover them. */
  protected capabilitiesReady(): void {
    this.capsDiscovered = true;
    const queued = this.pendingConfig;
    this.pendingConfig = [];
    for (const p of queued) this.applyConfig(p.key, p.value);
    this.emitCapabilities();
  }

  /** Validate one pick against the advertised lists and write it optimistically.
   *  Rejected picks get no echo — the absent capabilities frame is the signal. */
  private applyConfig(key: string, value: string): boolean {
    const pick = resolveConfigPick(key, value, {
      models: this.capModels,
      modes: this.capModes,
      // Effort picks validate against the explicit selection, falling back to
      // whatever model the backend reports as live.
      currentModelId: this.selModel ?? this.liveModelId(),
      currentEffortId: this.selEffort,
    });
    if (!pick) return false;
    if (!this.validateSelection(pick)) return false;
    const prev: SelectionSnapshot = {
      model: this.selModel,
      mode: this.selMode,
      effort: this.selEffort,
      modelExplicit: this.modelExplicit,
      effortExplicit: this.effortExplicit,
    };
    switch (pick.key) {
      case "model":
        this.selModel = pick.id;
        this.modelExplicit = true;
        // A carried-over effort the new model doesn't support would fail the turn.
        if (pick.clearEffort) this.selEffort = undefined;
        break;
      case "effort":
        this.selEffort = pick.id;
        this.effortExplicit = true;
        break;
      case "mode":
        this.selMode = pick.id;
        break;
    }
    this.applySelection(pick, prev);
    return true;
  }

  /**
   * A selection is written optimistically and pushed to the provider
   * fire-and-forget, but that call is fallible: claude's CLI arbitrates picks it
   * never advertised (permission mode "auto" is gated per-model, and no
   * discovery API reports which models allow it) and answers an unsupported one
   * with a rejection. Unguarded, that reaches the host's process-level
   * unhandledRejection hook and takes down every project on the machine. Roll
   * the optimistic write back and re-emit so the app's pills report the state
   * the session is actually in.
   */
  protected guardPick(call: Promise<unknown> | undefined, axis: string, id: string, revert: () => void): void {
    const seq = (this.pickSeq.get(axis) ?? 0) + 1;
    this.pickSeq.set(axis, seq);
    // The trailing catch keeps the handler total: emitCapabilities() writes to
    // the transport, and a throw there would reject this .catch()'s own promise
    // — landing right back on the hook this guard exists to keep clear.
    void call?.catch((err) => {
      if (this.disposed) return;
      log.warn("%s pick \"%s\" rejected for session %s: %s", axis, id, this.sessionId, err);
      // A newer pick on this axis already superseded ours and the provider took
      // it; rolling back now would clobber a selection that actually applied.
      if (this.pickSeq.get(axis) !== seq) return;
      revert();
      this.emitCapabilities();
    }).catch(() => {});
  }
}

function translateAnswer(answer: string | string[], p: Pending<string | string[]>): string | string[] {
  const value = p.single && Array.isArray(answer) ? (answer[0] ?? "") : answer;
  const labels = p.labels;
  if (!labels) return value;
  // The app echoes back synthetic option ids; opencode and codex both answer by
  // LABEL. A value that isn't a valid index passes through unchanged — a caller
  // that already sent a label still works.
  const toLabel = (v: string): string => {
    const i = Number(v);
    return Number.isInteger(i) && i >= 0 && i < labels.length ? labels[i]! : v;
  };
  return Array.isArray(value) ? value.map(toLabel) : toLabel(value);
}
