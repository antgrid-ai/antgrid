import { type AbMessage } from "../../protocol";
import type { DriverLifecycleEvent } from "../types";
import { mapPart, mapPlanEntries, mapTokens, mapOpencodeError } from "./mapping";
import { opencodeResumeReplay } from "./resume-replay";
import { agentError } from "../../structured/agent-error";
import { subtask } from "../../structured/tool-card";
import type { ConfigPick } from "../../structured/set-config";
import { ChatSession, type ChatSessionProfile } from "../../structured/chat-session";
import { logger } from "../../logger";
const log = logger.child({ component: "opencode-driver" });

// `type` is a bare string, not the @opencode-ai/sdk Event union. The binary
// streams every event on one unfiltered /event bus, so the set of names is not
// tied to the SDK generation and grows/shrinks across opencode releases (the
// PATH-resolved binary is unpinned). Going untyped keeps such skew from silently
// dropping events at the type layer. Route skew (the experimental v2 routes the
// seam calls) instead surfaces loudly at call time via unwrap() in spawn.ts.
export interface OpencodeEvent {
  type: string;
  properties: any;
}

export interface OpencodePromptOpts {
  model?: { providerID: string; modelID: string };
  agent?: string;
  variant?: string;
}

// The slice of the opencode SDK the driver needs (injectable for tests).
export interface OpencodeClientLike {
  createSession(opts: { title?: string; parentID?: string }): Promise<string>;
  // Read a session's full message history (each { info, parts }) for resume.
  messages(sessionId: string): Promise<any[]>;
  deleteMessage(sessionId: string, messageId: string): Promise<void>;
  prompt(sessionId: string, text: string, opts?: OpencodePromptOpts): Promise<void>;
  abort(sessionId: string): Promise<void>;
  summarize(sessionId: string, model: { providerID: string; modelID: string }): Promise<void>;
  replyPermission(sessionId: string, permissionId: string, response: "once" | "always" | "reject"): Promise<void>;
  replyQuestion(questionId: string, answer: string | string[]): Promise<void>;
  listCommands(): Promise<any[]>;
  listAgents(): Promise<any[]>;
  listProviders(): Promise<{ all: any[]; default: Record<string, string>; connected: string[] }>;
  command(sessionId: string, opts: { command: string; arguments?: string; agent?: string; model?: string; variant?: string }): Promise<void>;
  events(): AsyncIterable<OpencodeEvent>;
  // May be async: an in-app `opencode upgrade` replaces the on-disk binary that
  // the SDK server (the same binary) is still running, so teardown must resolve
  // only once that server has exited — see spawn.ts's dispose.
  dispose(): void | Promise<void>;
}

export interface OpencodeDriverOpts {
  sessionId: string;
  client: OpencodeClientLike;
  sendMessage: (msg: AbMessage) => void;
  onLifecycle?: (evt: DriverLifecycleEvent) => void;
}

type ModelRef = { providerID: string; modelID: string };

export class OpencodeDriver extends ChatSession {
  // opencode's mappers build whole items and the driver names its own turns.
  // Its history carries no per-turn status to filter by — a turn in flight is
  // indistinguishable from a completed one — so a mid-turn snapshot is refused
  // rather than risk replaying a streaming item as settled. Its interrupt is
  // `abort(session)`, not a turn.
  protected readonly profile: ChatSessionProfile = {
    turnSource: "session",
    mergeItems: false,
    snapshotDuringTurn: false,
    interruptScope: "session",
  };

  private readonly client: OpencodeClientLike;
  private readonly onLifecycle?: (evt: DriverLifecycleEvent) => void;

  private rootSessionId = "";
  // Whether the last session.status was a retry, so only the transition back to
  // busy/idle clears the park — busy fires constantly during a normal turn.
  private retrying = false;

  // messageID -> role, so a TextPart inherits its owning message's role.
  private messageRole = new Map<string, "assistant" | "user">();
  // child sessionID -> its subtask anchor itemId; and child -> parent sessionID.
  private subtaskItem = new Map<string, string>();
  private parentSession = new Map<string, string>();
  // last assistant model, for compact -> summarize (which requires an explicit model).
  private model: ModelRef | null = null;

  // "providerID/modelID" -> context-window size, from provider.list()'s
  // per-model `limit.context`. opencode never reports this per-turn (unlike
  // codex's modelContextWindow), so it's looked up by the active message's
  // providerID/modelID when emitting agent:usage.
  private modelContextWindows = new Map<string, number>();
  // Last occupancy this driver reported (live message.updated or resume seed).
  // Capacity re-emits (discovery, model switch) carry it forward so a
  // capacity-only frame never wipes the meter's occupancy app-side.
  private lastTokens: ReturnType<typeof mapTokens> | null = null;

  constructor(opts: OpencodeDriverOpts) {
    super({ sessionId: opts.sessionId, sendMessage: opts.sendMessage });
    this.client = opts.client;
    this.onLifecycle = opts.onLifecycle;
  }

  protected async startBackend(resumeId?: string): Promise<string> {
    // Attach the event iterator before createSession so we don't miss the
    // post-create burst. Events for the not-yet-known rootSessionId are still
    // gated out by inTree (benign — opencode emits none before create resolves).
    void this.runEventLoop();
    void this.discoverCapabilities();
    if (resumeId) {
      // Reuse the persisted session — creating a new one would orphan the
      // history the user expects to see. Fetch + replay it as completed transcript.
      this.rootSessionId = resumeId;
      try {
        const history = await this.client.messages(resumeId);
        this.emitTranscriptReplay(opencodeResumeReplay(
          this.sessionId,
          history,
          (p, m) => this.modelContextWindows.get(`${p}/${m}`),
        ));
        this.syncContextFromHistory(history);
      } catch {
        // History read failed; continue with the live session anyway — the next
        // prompt still runs against rootSessionId.
      }
      return this.rootSessionId;
    }
    // No title: opencode generates one from the first prompt ONLY if the session
    // doesn't already have one, and pushes it on session.updated. Seeding any
    // title here (we used to seed the projectId) silently turns that generation
    // off for the life of the session, leaving the app stuck on "Session N".
    this.rootSessionId = await this.client.createSession({});
    return this.rootSessionId;
  }

  // On-demand re-derivation of this session's transcript, for a client attaching
  // to an already-running session (see session.transcriptSnapshot in
  // agent-core.ts). client.messages() is the same non-mutating history read
  // start(resumeId) already uses for cold-start resume-replay.
  protected async transcriptSnapshot(): Promise<AbMessage[]> {
    if (!this.rootSessionId) return [];
    const history = await this.client.messages(this.rootSessionId);
    return opencodeResumeReplay(
      this.sessionId,
      history,
      (p, m) => this.modelContextWindows.get(`${p}/${m}`),
    );
  }

  // providerID never contains "/" but modelID may — split at the first.
  protected validateSelection(pick: ConfigPick): boolean {
    return pick.key !== "model" || pick.id.indexOf("/") > 0;
  }

  protected applySelection(pick: ConfigPick): void {
    if (pick.key === "model") this.emitContextCapacity();
  }

  protected liveModelId(): string | undefined {
    return this.model ? `${this.model.providerID}/${this.model.modelID}` : undefined;
  }

  /** The explicit pick as opencode's prompt API wants it (a pair, not a ref
   *  string). validateSelection guarantees the separator is present. */
  private get selModelRef(): ModelRef | null {
    if (!this.selModel) return null;
    const cut = this.selModel.indexOf("/");
    return cut > 0 ? { providerID: this.selModel.slice(0, cut), modelID: this.selModel.slice(cut + 1) } : null;
  }

  protected async preparePrompt(): Promise<void> {
    if (!this.rootSessionId) this.rootSessionId = await this.client.createSession({});
  }

  protected async sendPrompt(text: string, commandId?: string): Promise<void> {
    if (commandId?.startsWith("cmd:")) {
      await this.client.command(this.rootSessionId, {
        command: commandId.slice("cmd:".length),
        ...(text.trim() ? { arguments: text } : {}),
        ...(this.selMode ? { agent: this.selMode } : {}),
        // session.command takes the "provider/model" ref string, not the pair.
        ...(this.selModel ? { model: this.selModel } : {}),
        ...(this.selEffort ? { variant: this.selEffort } : {}),
      });
      return;
    }
    // Unknown commandId prefixes degrade to a plain prompt of the args text.
    // Reachable when the app holds capabilities from another driver/session
    // (stale replay); log it so the dropped routing is diagnosable.
    if (commandId) log.warn("opencode: unrecognized commandId %s; sending as plain prompt", commandId);
    const model = this.selModelRef;
    await this.client.prompt(this.rootSessionId, text, {
      ...(model ? { model } : {}),
      ...(this.selMode ? { agent: this.selMode } : {}),
      ...(this.selEffort ? { variant: this.selEffort } : {}),
    });
  }

  protected interruptReady(): boolean {
    return !!this.rootSessionId;
  }

  protected async interrupt(_turnId: string): Promise<void> {
    await this.client.abort(this.rootSessionId);
  }

  async compact(): Promise<void> {
    // opencode's summarize requires an explicit model; skip until we've seen one.
    if (this.rootSessionId && this.model) await this.client.summarize(this.rootSessionId, this.model);
  }

  async revert(target: { messageId?: string }): Promise<void> {
    if (!this.rootSessionId) return;
    const targetMessageId = target.messageId;
    if (!targetMessageId) throw new Error("revert requires a message id");
    const history = await this.client.messages(this.rootSessionId);
    const idx = history.findIndex((m) => m?.info?.id === targetMessageId);
    if (idx < 0) throw new Error("revert target message not found");
    for (const msg of history.slice(idx)) {
      const id = msg?.info?.id;
      if (typeof id === "string" && id) await this.client.deleteMessage(this.rootSessionId, id);
    }
    const nextHistory = await this.client.messages(this.rootSessionId);
    this.endTurn();
    this.emitSessionReset();
    this.emitTranscriptReplay(opencodeResumeReplay(
      this.sessionId,
      nextHistory,
      (p, m) => this.modelContextWindows.get(`${p}/${m}`),
    ));
    this.syncContextFromHistory(nextHistory);
  }

  // Per-turn message-role state is only meaningful within a turn; the session
  // clears the item and prompt state alongside it.
  protected clearTurnState(): void {
    this.messageRole.clear();
  }

  // opencode is the only backend whose question ids are the PROVIDER's, so an
  // answer for a prompt the session has already withdrawn is still routable —
  // and worth routing, because opencode is still waiting on it. Untranslated:
  // the option labels went with the retraction.
  protected resolveUnknownQuestion(questionId: string, answer: string | string[]): void {
    void this.client.replyQuestion(questionId, answer).catch(() => {});
  }

  protected disposeBackend(): void | Promise<void> {
    // Return the client teardown so StructuredManager.stopChat awaits the server
    // exit before an in-app update touches the binary (mirrors codex's
    // dispose→proc.exited). Void for a client whose dispose is synchronous.
    return this.client.dispose();
  }

  private async runEventLoop(): Promise<void> {
    try {
      for await (const evt of this.client.events()) {
        if (this.disposed) break;
        // Isolate each event: a malformed payload that throws in handleEvent must
        // not tear down the whole stream (which silently freezes the session).
        try {
          this.handleEvent(evt);
        } catch (err) {
          log.error("opencode event handler threw for %s: %s", evt?.type, err);
        }
      }
    } catch {
      // Stream closed (server exited/disposed). Payload-bearing failures surface
      // via agent:error from session.error, but a mid-turn close emits no such
      // event — close out any in-flight turn so the app doesn't spin forever.
      if (this.disposed) return;
      if (!this.activeTurnId) return;
      const cancelled = this.cancelRequested;
      this.closeTurn({
        stopReason: cancelled ? "cancelled" : "error",
        ...(cancelled
          ? {}
          : {
              error: agentError({
                category: "unknown",
                message: "opencode session ended unexpectedly",
                retryable: false,
              }),
            }),
      });
    }
  }

  // start() fire-and-forgets this, so a rejection would escape into the void and
  // reach the host's process-level unhandledRejection hook, which tears down every
  // project on the machine (see index.ts) — not just this session. The inner
  // allSettled covers the RPCs; this covers the post-processing (same containment
  // runEventLoop does for the event stream).
  private async discoverCapabilities(): Promise<void> {
    try {
      await this.discoverCapabilitiesInner();
    } catch (err) {
      log.warn("opencode capability discovery failed for session %s: %s", this.sessionId, err);
    }
  }

  // Fail-soft: each list settles independently; a route the running binary
  // doesn't serve (version skew) only omits its section.
  private async discoverCapabilitiesInner(): Promise<void> {
    const [commands, agents, providers] = await Promise.allSettled([
      this.client.listCommands(),
      this.client.listAgents(),
      this.client.listProviders(),
    ]);
    const cmds: typeof this.capCommands = [];
    if (commands.status === "fulfilled") {
      for (const c of commands.value) {
        if (!c?.name) continue;
        cmds.push({
          id: `cmd:${c.name}`,
          name: String(c.name),
          ...(c?.description ? { description: String(c.description) } : {}),
          ...(Array.isArray(c?.hints) && c.hints.length ? { argHint: c.hints.join(" ") } : {}),
        });
      }
    }
    cmds.push({ id: "builtin:compact", name: "compact", description: "Summarize the conversation to free context" });
    this.capCommands = cmds;
    if (agents.status === "fulfilled") {
      this.capModes = agents.value
        .filter((a: any) => a?.mode !== "subagent" && !a?.hidden && a?.name)
        .map((a: any) => ({
          id: String(a.name),
          name: String(a.name),
          ...(a?.description ? { description: String(a.description) } : {}),
        }));
    }
    if (providers.status === "fulfilled") {
      const { all, connected } = providers.value;
      // Only providers the user has auth for; an empty `connected` (older
      // binary) falls back to everything rather than an empty picker.
      const usable = connected.length ? all.filter((p: any) => connected.includes(p?.id)) : all;
      const models: typeof this.capModels = [];
      const contextWindows = new Map<string, number>();
      for (const p of usable) {
        for (const m of Object.values(p?.models ?? {}) as any[]) {
          if (!m?.id) continue;
          const variants = m?.variants && typeof m.variants === "object" ? Object.keys(m.variants) : [];
          const modelId = `${p.id}/${m.id}`;
          models.push({
            id: modelId,
            name: String(m?.name ?? m.id),
            provider: String(p?.name ?? p?.id ?? ""),
            ...(variants.length ? { efforts: variants } : {}),
          });
          if (typeof m?.limit?.context === "number") contextWindows.set(modelId, m.limit.context);
        }
      }
      this.capModels = models;
      this.modelContextWindows = contextWindows;
    }
    this.capabilitiesReady();
    this.emitContextCapacity();
  }

  // Capacity-first meter seed lets the app render before the first response.
  // No-op until a current model is known; a fresh session
  // with no explicit pick has none until the first assistant message.
  private emitContextCapacity(): void {
    const current = this.selModel ?? this.liveModelId();
    if (!current) return;
    const cw = this.modelContextWindows.get(current);
    if (cw === undefined) return;
    this.emitUsage({ total: this.lastTokens ?? {}, contextWindow: cw });
  }

  // A reset removes the app's live meter state, while item-anchored replay
  // frames intentionally restore footers only. Recompute the unanchored meter
  // seed from the surviving history so deleted messages cannot remain current.
  private syncContextFromHistory(history: any[]): void {
    const previousModel = this.model;
    const lastAssistant = [...history]
      .reverse()
      .find((m: any) => m?.info?.role === "assistant" && m?.info?.tokens);
    const info = lastAssistant?.info;
    this.model = info?.providerID && info?.modelID
      ? { providerID: info.providerID, modelID: info.modelID }
      : null;
    this.lastTokens = info ? mapTokens(info.tokens) : null;

    const modelChanged = previousModel?.providerID !== this.model?.providerID ||
      previousModel?.modelID !== this.model?.modelID;
    if (!this.selModel && this.capsDiscovered && modelChanged) {
      this.emitCapabilities();
    }
    if (!this.lastTokens) {
      // An explicit model still has useful capacity after reverting to empty.
      this.emitContextCapacity();
      return;
    }
    const contextWindow = this.model
      ? this.modelContextWindows.get(`${this.model.providerID}/${this.model.modelID}`)
      : undefined;
    this.emitUsage({
      total: this.lastTokens,
      ...(contextWindow !== undefined ? { contextWindow } : {}),
    });
  }

  private inTree(sid: string): boolean {
    return sid === this.rootSessionId || this.subtaskItem.has(sid);
  }

  // parentItemId for items belonging to session `sid` (undefined for the root).
  private parentItemIdFor(sid: string): string | undefined {
    return sid === this.rootSessionId ? undefined : this.subtaskItem.get(sid);
  }

  private handleEvent(evt: OpencodeEvent): void {
    const p = evt.properties ?? {};
    switch (evt.type) {
      case "message.updated": return this.onMessageUpdated(p);
      case "message.part.updated": return this.onPartUpdated(p);
      case "message.part.delta": return this.onPartDelta(p);
      case "session.created": return this.onSessionCreated(p);
      // session.updated carries only opencode's own generated conversation
      // title, which we deliberately do not apply (see ResolvedTitle) — so the
      // event has nothing left to handle.
      case "session.idle": return this.onSessionIdle(p);
      case "session.status": return this.onSessionStatus(p);
      case "session.error": return this.onSessionError(p);
      case "permission.asked": return this.onPermissionAsked(p);
      case "question.asked": return this.onQuestionAsked(p);
      case "todo.updated": return this.onTodoUpdated(p);
      default: return;
    }
  }

  private onMessageUpdated(p: any): void {
    const info = p?.info ?? {};
    if (info.id && info.role) this.messageRole.set(info.id, info.role);
    if (info.role === "assistant") {
      if (info.providerID && info.modelID) {
        const changed = this.model?.providerID !== info.providerID || this.model?.modelID !== info.modelID;
        this.model = { providerID: info.providerID, modelID: info.modelID };
        // currentModelId tracks the live model until the user picks one; the
        // capModels guard avoids clobbering the app with a pre-discovery
        // (all-empty) frame.
        if (changed && !this.selModel && this.capModels.length) this.emitCapabilities();
      }
      if (info.tokens) {
        this.lastTokens = mapTokens(info.tokens);
        const contextWindow = info.providerID && info.modelID
          ? this.modelContextWindows.get(`${info.providerID}/${info.modelID}`)
          : undefined;
        this.emitUsage({
          turnId: this.activeTurnId ?? undefined,
          total: this.lastTokens,
          ...(contextWindow !== undefined ? { contextWindow } : {}),
        });
      }
    }
  }

  private onPartUpdated(p: any): void {
    const part = p?.part ?? {};
    const owner: string = part.sessionID ?? p?.sessionID ?? this.rootSessionId;
    if (!this.inTree(owner)) return;
    const role = this.messageRole.get(part.messageID) ?? "assistant";
    const mapped = mapPart(part, role);
    if (!mapped) return;
    const parentItemId = this.parentItemIdFor(owner);
    const item = parentItemId ? { ...mapped, parentItemId } : mapped;
    this.emitItem(item.itemId, item as unknown as Record<string, unknown>, {
      turnId: this.activeTurnId ?? "",
      ...(parentItemId ? { parentItemId } : {}),
    });
  }

  private onPartDelta(p: any): void {
    if (p?.field !== "text") return;
    const owner: string = p?.sessionID ?? this.rootSessionId;
    if (!this.inTree(owner)) return;
    this.emitDelta(String(p?.partID ?? ""), String(p?.delta ?? ""), this.activeTurnId ?? "");
  }

  private onSessionCreated(p: any): void {
    const info = p?.info ?? {};
    const parentID: string | undefined = info.parentID;
    if (!parentID || !this.inTree(parentID)) return;
    const childId: string = info.id ?? p?.sessionID ?? "";
    if (!childId) return;
    const itemId = `subtask:${childId}`;
    this.subtaskItem.set(childId, itemId);
    this.parentSession.set(childId, parentID);
    const parentItemId = this.parentItemIdFor(parentID);
    const item = subtask({
      itemId, status: "running",
      title: String(info.title ?? "subagent"), agent: info.agent,
      ...(parentItemId ? { parentItemId } : {}),
    });
    this.emitItem(itemId, item as unknown as Record<string, unknown>, {
      turnId: this.activeTurnId ?? "",
      added: true,
      ...(parentItemId ? { parentItemId } : {}),
    });
  }

  private flipSubtask(sid: string, status: "completed" | "error" | "cancelled", rawError?: any): void {
    const itemId = this.subtaskItem.get(sid);
    if (!itemId) return;
    const parentItemId = this.subtaskItem.get(this.parentSession.get(sid) ?? "");
    const item = subtask({
      itemId, status,
      ...(parentItemId ? { parentItemId } : {}),
      ...(status === "error" && rawError ? { error: mapOpencodeError(rawError) } : {}),
    });
    this.emitItem(itemId, item as unknown as Record<string, unknown>, {
      turnId: this.activeTurnId ?? "",
      added: false,
    });
    // Terminal state: the child session won't emit again, so drop its tracking.
    this.subtaskItem.delete(sid);
    this.parentSession.delete(sid);
  }

  private onSessionIdle(p: any): void {
    const sid: string = p?.sessionID ?? "";
    if (sid === this.rootSessionId) {
      if (!this.activeTurnId) return;
      this.closeTurn({ stopReason: this.cancelRequested ? "cancelled" : "end_turn" });
    } else if (this.subtaskItem.has(sid)) {
      this.flipSubtask(sid, "completed");
    }
  }

  // opencode is the one driver that parks AND wakes itself: it retries a
  // rate-limited request unboundedly, honoring retry-after, so `next` is a wake
  // time we mirror rather than a deadline we act on. Root only — a subtask's
  // status would flap the park against the root's own busy/idle stream.
  private onSessionStatus(p: any): void {
    if ((p?.sessionID ?? "") !== this.rootSessionId) return;
    const status = p?.status ?? {};
    if (status.type === "retry") {
      this.retrying = true;
      const next = typeof status.next === "number" ? status.next : undefined;
      this.onLifecycle?.({
        event: "limit_hit",
        ...(next !== undefined ? { resetsAt: next } : {}),
        selfResuming: true,
        errorClass: "rate_limit",
      });
      return;
    }
    if (!this.retrying) return;
    this.retrying = false;
    this.onLifecycle?.({ event: "limit_cleared" });
  }

  private onSessionError(p: any): void {
    const sid: string = p?.sessionID ?? "";
    const error = mapOpencodeError(p?.error);
    // sessionID is optional on EventSessionError; an unattributed error during an
    // active turn is the root turn's (it isn't a known subtask), so close the turn
    // rather than letting it hang.
    const turnId = this.activeTurnId;
    if (turnId && (sid === this.rootSessionId || !sid)) {
      // A user abort surfaces here as MessageAbortedError; report cancellation,
      // not a turn error (and omit the error payload in that case).
      const cancelled = this.cancelRequested || error.category === "aborted";
      // The retry episode ended here, whichever way the turn went. Leaving the
      // flag set would make the next turn's first busy status report a
      // limit_cleared that cancels this failure's own park before it can wake.
      this.retrying = false;
      // Reported BEFORE the turn-end frame: both reach the handler engine on the
      // same serialized chain, and only a park that is already in place swallows
      // the turn boundary instead of spending a judge call on a failure the
      // provider is refusing anyway.
      if (!cancelled) this.reportTerminalFailure(p?.error, error.category);
      this.closeTurn({
        stopReason: cancelled ? "cancelled" : "error",
        turnId,
        ...(cancelled ? {} : { error }),
      });
    } else if (this.subtaskItem.has(sid)) {
      this.flipSubtask(sid, "error", p?.error);
    } else {
      this.emitError(error);
    }
  }

  // A terminal error means opencode's own unbounded retry loop gave up, so this
  // park is NOT self-resuming — the engine's timer has to nudge. mapOpencodeError
  // recognizes only three names, so everything outside them is the transient
  // bucket: auth and context_overflow are the failures a wait cannot fix, and
  // they keep the ordinary judge-and-escalate path.
  private reportTerminalFailure(raw: any, category: string): void {
    if (raw?.data?.statusCode === 429) {
      this.onLifecycle?.({ event: "limit_hit", errorClass: "rate_limit" });
      return;
    }
    if (category === "auth" || category === "context_overflow") return;
    this.onLifecycle?.({ event: "turn_failed", errorClass: category });
  }

  private onPermissionAsked(p: any): void {
    const permissionId: string = p?.id ?? "";
    const sid: string = p?.sessionID ?? this.rootSessionId;
    this.askPermission({
      permissionId,
      // PermissionRequest.permission is the permission key (a string); `tool` is
      // {messageID, callID} with no name. Use the key as the title.
      title: String(p?.permission ?? "Allow action?"),
      options: [
        { optionId: "once", label: "Allow once", kind: "allow_once" },
        { optionId: "always", label: "Always allow", kind: "allow_always" },
        { optionId: "reject", label: "Deny", kind: "reject" },
      ],
    }, (optionId) => {
      if (optionId === null) return;
      const response = optionId === "once" || optionId === "always" ? optionId : "reject";
      void this.client.replyPermission(sid, permissionId, response).catch(() => {});
    });
  }

  private onQuestionAsked(p: any): void {
    const questionId: string = p?.id ?? "";
    const questions: any[] = Array.isArray(p?.questions) ? p.questions : [];
    const q = questions[0] ?? {};
    const opts: any[] = Array.isArray(q.options) ? q.options : [];
    // opencode Question.Info: { question, header, options:{label,description}[], multiple? }
    // — no id/text/prompt fields. Options are answered by label, so synthesize an
    // id from the index purely for the app's option list.
    const kind = opts.length === 0 ? "text" : q.multiple ? "multi_select" : "single_select";
    this.askQuestion({
      questionId,
      kind,
      prompt: String(q.question ?? q.header ?? "?"),
      ...(opts.length > 0
        ? { options: opts.map((o, i) => ({ id: String(i), label: String(o?.label ?? ""), description: o?.description })) }
        : {}),
    }, (value) => {
      if (value === null) return;
      void this.client.replyQuestion(questionId, value).catch(() => {});
    }, opts.length > 0 ? { labels: opts.map((o) => String(o?.label ?? "")) } : undefined);
  }

  private onTodoUpdated(p: any): void {
    const sid: string = p?.sessionID ?? "";
    if (sid !== this.rootSessionId) return; // v1: only the root session's plan
    this.emitPlan(this.activeTurnId ?? "", mapPlanEntries(p?.todos));
  }
}
