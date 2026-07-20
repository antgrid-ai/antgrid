import { createMessage, createTranscriptReplay, type AbMessage } from "../protocol";
import { mapPart, mapPlanEntries, mapTokens, mapOpencodeError } from "./opencode-mapping";
import { opencodeResumeReplay } from "./opencode-resume-replay";
import { resolveConfigPick } from "../structured/set-config";
import { logger } from "../logger";

// `type` is a bare string, not the @opencode-ai/sdk Event union. The binary
// streams every event on one unfiltered /event bus, so the set of names is not
// tied to the SDK generation and grows/shrinks across opencode releases (the
// PATH-resolved binary is unpinned). Going untyped keeps such skew from silently
// dropping events at the type layer. Route skew (the experimental v2 routes the
// seam calls) instead surfaces loudly at call time via unwrap() in spawn-opencode.ts.
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
  // only once that server has exited — see spawn-opencode's dispose.
  dispose(): void | Promise<void>;
}

export interface OpencodeDriverOpts {
  sessionId: string;
  client: OpencodeClientLike;
  sendMessage: (msg: AbMessage) => void;
  title?: string;
  onTitle?: (title: string) => void;
}

export class OpencodeDriver {
  private readonly sessionId: string;
  private readonly client: OpencodeClientLike;
  private readonly send: (msg: AbMessage) => void;
  private readonly title?: string;
  private readonly onTitle?: (title: string) => void;

  private rootSessionId = "";
  private turnCounter = 0;
  private activeTurnId: string | null = null;
  private disposed = false;
  // Set by cancel(): opencode's idle event is bare ({sessionID}), so the driver
  // can't tell a normal completion from a post-abort one without this flag. The
  // next root idle/error closes the turn as 'cancelled' instead of end_turn/error.
  private cancelRequested = false;

  // messageID -> role, so a TextPart inherits its owning message's role.
  private messageRole = new Map<string, "assistant" | "user">();
  // child sessionID -> its subtask anchor itemId; and child -> parent sessionID.
  private subtaskItem = new Map<string, string>();
  private parentSession = new Map<string, string>();
  // partID seen -> first sighting emits item-added, later ones item-updated.
  private seenParts = new Set<string>();
  // permissionId -> owning opencode sessionID (the reply call needs it).
  private permissionSession = new Map<string, string>();
  // questionId -> option labels indexed by the synthetic id we hand the app.
  // opencode answers by label, so an echoed-back id must be translated back.
  private questionOptions = new Map<string, string[]>();
  // Every pending questionId (questionOptions only tracks option-questions;
  // free-text questions must be retractable too).
  private pendingQuestionIds = new Set<string>();
  // last assistant model, for compact -> summarize (which requires an explicit model).
  private model: { providerID: string; modelID: string } | null = null;

  private capModels: Array<{ id: string; name: string; provider?: string; efforts?: string[] }> = [];
  // "providerID/modelID" -> context-window size, from provider.list()'s
  // per-model `limit.context`. opencode never reports this per-turn (unlike
  // codex's modelContextWindow), so it's looked up by the active message's
  // providerID/modelID when emitting agent:usage.
  private modelContextWindows = new Map<string, number>();
  // Last occupancy this driver reported (live message.updated or resume seed).
  // Capacity re-emits (discovery, model switch) carry it forward so a
  // capacity-only frame never wipes the meter's occupancy app-side.
  private lastTokens: ReturnType<typeof mapTokens> | null = null;
  private capModes: Array<{ id: string; name: string; description?: string }> = [];
  private capCommands: Array<{ id: string; name: string; description?: string; argHint?: string }> = [];
  private selModel: { providerID: string; modelID: string } | null = null;
  private selVariant?: string;
  private selAgent?: string;
  // Picks that arrived before discovery populated the lists (a resumed session
  // replays yesterday's pickers to the app instantly, while discovery is still
  // in flight). Queued and validated once discovery lands, instead of being
  // silently rejected against empty lists.
  private capsDiscovered = false;
  private pendingConfig: Array<{ key: string; value: string }> = [];

  constructor(opts: OpencodeDriverOpts) {
    this.sessionId = opts.sessionId;
    this.client = opts.client;
    this.send = opts.sendMessage;
    this.title = opts.title;
    this.onTitle = opts.onTitle;
  }

  async start(resumeId?: string): Promise<string> {
    // Attach the event iterator before createSession so we don't miss the
    // post-create burst. Events for the not-yet-known rootSessionId are still
    // gated out by inTree (benign — opencode emits none before create resolves).
    void this.runEventLoop();
    // Advertise an empty, not-ready catalog immediately so the app shows a
    // loading indicator until discoverCapabilities() emits the real one.
    this.emitCapabilities();
    void this.discoverCapabilities();
    if (resumeId) {
      // Reuse the persisted session — creating a new one would orphan the
      // history the user expects to see. Fetch + replay it as completed transcript.
      this.rootSessionId = resumeId;
      try {
        const history = await this.client.messages(resumeId);
        const replay = createTranscriptReplay(this.sessionId, opencodeResumeReplay(
          this.sessionId,
          history,
          (p, m) => this.modelContextWindows.get(`${p}/${m}`),
        ));
        if (replay) this.send(replay);
        this.syncContextFromHistory(history);
      } catch {
        // History read failed; continue with the live session anyway — the next
        // prompt still runs against rootSessionId.
      }
      return this.rootSessionId;
    }
    this.rootSessionId = await this.client.createSession({ title: this.title });
    return this.rootSessionId;
  }

  // On-demand re-derivation of this session's transcript, for a client attaching
  // to an already-running session (see session.transcriptSnapshot in
  // agent-core.ts). client.messages() is the same non-mutating history read
  // start(resumeId) already uses for cold-start resume-replay. Unlike codex,
  // opencode's history carries no per-turn status to filter by — a turn in
  // flight is indistinguishable from a completed one, so skip the whole snapshot
  // while one is streaming rather than risk replaying it as settled mid-item.
  async getTranscriptSnapshot(): Promise<AbMessage[]> {
    if (!this.rootSessionId) return [];
    if (this.activeTurnId !== null) return [];
    try {
      const history = await this.client.messages(this.rootSessionId);
      return opencodeResumeReplay(
        this.sessionId,
        history,
        (p, m) => this.modelContextWindows.get(`${p}/${m}`),
      );
    } catch (err) {
      logger.warn(
        "opencode messages() failed for session %s (session %s); returning empty transcript snapshot: %s",
        this.sessionId,
        this.rootSessionId,
        err,
      );
      return [];
    }
  }

  setConfig(key: string, value: unknown): void {
    if (typeof value !== "string") return;
    if (!this.capsDiscovered) {
      this.pendingConfig.push({ key, value });
      return;
    }
    if (this.applyConfig(key, value)) this.emitCapabilities();
  }

  // Validate against the advertised lists (see resolveConfigPick) and store.
  // Rejected picks get no echo — the absent capabilities echo is the signal.
  private applyConfig(key: string, value: string): boolean {
    // Effort picks validate against the explicit selection, falling back to
    // the live model captured from the last assistant message.
    const current = this.selModel ?? this.model;
    const pick = resolveConfigPick(key, value, {
      models: this.capModels,
      modes: this.capModes,
      currentModelId: current ? `${current.providerID}/${current.modelID}` : undefined,
      currentEffortId: this.selVariant,
    });
    if (!pick) return false;
    switch (pick.key) {
      case "model": {
        // providerID never contains "/" but modelID may — split at the first.
        const cut = pick.id.indexOf("/");
        if (cut <= 0) return false;
        this.selModel = { providerID: pick.id.slice(0, cut), modelID: pick.id.slice(cut + 1) };
        if (pick.clearEffort) this.selVariant = undefined;
        this.emitContextCapacity();
        break;
      }
      case "effort":
        this.selVariant = pick.id;
        break;
      case "mode":
        this.selAgent = pick.id;
        break;
    }
    return true;
  }

  async prompt(text: string, commandId?: string): Promise<void> {
    if (!this.rootSessionId) this.rootSessionId = await this.client.createSession({ title: this.title });
    // compact drives its own lifecycle (same contract as agent:session-action).
    if (commandId === "builtin:compact") return this.compact();
    this.activeTurnId = `turn-${this.turnCounter++}`;
    // Each new turn starts clean: a cancel() whose idle never arrived must not
    // bleed a stale cancelRequested into this turn.
    this.cancelRequested = false;
    this.send(createMessage("agent:turn-start", { sessionId: this.sessionId, turnId: this.activeTurnId }));
    if (commandId?.startsWith("cmd:")) {
      await this.client.command(this.rootSessionId, {
        command: commandId.slice("cmd:".length),
        ...(text.trim() ? { arguments: text } : {}),
        ...(this.selAgent ? { agent: this.selAgent } : {}),
        // session.command takes the "provider/model" ref string, not the pair.
        ...(this.selModel ? { model: `${this.selModel.providerID}/${this.selModel.modelID}` } : {}),
        ...(this.selVariant ? { variant: this.selVariant } : {}),
      });
      return;
    }
    // Unknown commandId prefixes degrade to a plain prompt of the args text.
    // Reachable when the app holds capabilities from another driver/session
    // (stale replay); log it so the dropped routing is diagnosable.
    if (commandId) logger.warn("opencode: unrecognized commandId %s; sending as plain prompt", commandId);
    await this.client.prompt(this.rootSessionId, text, {
      ...(this.selModel ? { model: this.selModel } : {}),
      ...(this.selAgent ? { agent: this.selAgent } : {}),
      ...(this.selVariant ? { variant: this.selVariant } : {}),
    });
  }

  async cancel(turnId?: string): Promise<boolean> {
    if (!this.rootSessionId) return false;
    // Stale turnId => refuse rather than abort; see the claude driver's cancel
    // for the rationale. It matters most here: abort takes a session, not a
    // turn, so an unaimed cancel would take down whatever is live. Gated on
    // activeTurnId too, so a turnId arriving with nothing running still falls
    // through to the abort-regardless path below.
    if (turnId && this.activeTurnId && turnId !== this.activeTurnId) return false;
    this.cancelRequested = true;
    await this.client.abort(this.rootSessionId);
    // Reported from activeTurnId, not from the abort: the turn-end comes from
    // the resulting idle event, which only arrives if a turn was actually
    // running. Aborting regardless preserves the pre-existing behavior.
    return this.activeTurnId !== null;
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
    this.activeTurnId = null;
    this.cancelRequested = false;
    this.endTurnCleanup();
    this.send(createMessage("agent:session-reset", { sessionId: this.sessionId }));
    const replay = createTranscriptReplay(this.sessionId, opencodeResumeReplay(
      this.sessionId,
      nextHistory,
      (p, m) => this.modelContextWindows.get(`${p}/${m}`),
    ));
    if (replay) this.send(replay);
    this.syncContextFromHistory(nextHistory);
  }

  resolvePermission(permissionId: string, optionId: string): void {
    const sid = this.permissionSession.get(permissionId);
    if (!sid) return;
    this.permissionSession.delete(permissionId);
    const response = optionId === "once" || optionId === "always" ? optionId : "reject";
    void this.client.replyPermission(sid, permissionId, response).catch(() => {});
  }

  resolveQuestion(questionId: string, answer: string | string[]): void {
    const labels = this.questionOptions.get(questionId);
    this.questionOptions.delete(questionId);
    this.pendingQuestionIds.delete(questionId);
    // No stored options = free-form text question: pass the answer through.
    // Otherwise the app echoes back synthetic option ids; translate each to its
    // label (opencode answers by label). A value that isn't a valid index is
    // passed through unchanged — a caller that already sent a label still works.
    const toLabel = (v: string): string => {
      if (!labels) return v;
      const i = Number(v);
      return Number.isInteger(i) && i >= 0 && i < labels.length ? labels[i]! : v;
    };
    const translated = Array.isArray(answer) ? answer.map(toLabel) : toLabel(answer);
    void this.client.replyQuestion(questionId, translated).catch(() => {});
  }

  dispose(): void | Promise<void> {
    // Withdraw any permission/question still on screen so it doesn't wedge after
    // teardown (LRU eviction, focus disposal) — same retraction contract as the
    // codex driver's dispose(). Runs before disposed=true so send() still fires.
    this.endTurnCleanup();
    this.disposed = true;
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
          logger.error("opencode event handler threw for %s: %s", evt?.type, err);
        }
      }
    } catch {
      // Stream closed (server exited/disposed). Payload-bearing failures surface
      // via agent:error from session.error, but a mid-turn close emits no such
      // event — close out any in-flight turn so the app doesn't spin forever.
      if (this.disposed) return;
      const turnId = this.activeTurnId;
      if (turnId) {
        const cancelled = this.cancelRequested;
        this.cancelRequested = false;
        this.send(createMessage("agent:turn-end", {
          sessionId: this.sessionId,
          turnId,
          stopReason: cancelled ? "cancelled" : "error",
          ...(cancelled
            ? {}
            : {
                error: {
                  category: "unknown",
                  message: "opencode session ended unexpectedly",
                  retryable: false,
                },
              }),
        }));
        this.activeTurnId = null;
        this.endTurnCleanup();
      }
    }
  }

  // Fail-soft: each list settles independently; a route the running binary
  // doesn't serve (version skew) only omits its section.
  private async discoverCapabilities(): Promise<void> {
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
    this.capsDiscovered = true;
    const queued = this.pendingConfig;
    this.pendingConfig = [];
    for (const p of queued) this.applyConfig(p.key, p.value);
    this.emitCapabilities();
    this.emitContextCapacity();
  }

  private emitCapabilities(): void {
    // Explicit selection wins; otherwise advertise the live model captured
    // from the last assistant message.
    const current = this.selModel ?? this.model;
    this.send(createMessage("agent:capabilities", {
      sessionId: this.sessionId,
      ready: this.capsDiscovered,
      commands: this.capCommands,
      modes: this.capModes,
      models: this.capModels,
      ...(current ? { currentModelId: `${current.providerID}/${current.modelID}` } : {}),
      ...(this.selVariant ? { currentEffortId: this.selVariant } : {}),
      ...(this.selAgent ? { currentModeId: this.selAgent } : {}),
    }));
  }

  // Capacity-first meter seed lets the app render before the first response.
  // No-op until a current model is known; a fresh session
  // with no explicit pick has none until the first assistant message.
  private emitContextCapacity(): void {
    const current = this.selModel ?? this.model;
    if (!current) return;
    const cw = this.modelContextWindows.get(`${current.providerID}/${current.modelID}`);
    if (cw === undefined) return;
    this.send(createMessage("agent:usage", {
      sessionId: this.sessionId,
      total: this.lastTokens ?? {},
      contextWindow: cw,
    }));
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
    this.send(createMessage("agent:usage", {
      sessionId: this.sessionId,
      total: this.lastTokens,
      ...(contextWindow !== undefined ? { contextWindow } : {}),
    }));
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
      case "session.updated": return this.onSessionUpdated(p);
      case "session.idle": return this.onSessionIdle(p);
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
        this.send(createMessage("agent:usage", {
          sessionId: this.sessionId,
          turnId: this.activeTurnId ?? undefined,
          total: this.lastTokens,
          ...(contextWindow !== undefined ? { contextWindow } : {}),
        }));
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
    const turnId = this.activeTurnId ?? "";
    const first = !this.seenParts.has(part.id);
    this.seenParts.add(part.id);
    this.send(createMessage(first ? "agent:item-added" : "agent:item-updated", {
      sessionId: this.sessionId, turnId, itemId: item.itemId,
      ...(first && parentItemId ? { parentItemId } : {}),
      item,
    }));
  }

  private onPartDelta(p: any): void {
    if (p?.field !== "text") return;
    const owner: string = p?.sessionID ?? this.rootSessionId;
    if (!this.inTree(owner)) return;
    this.send(createMessage("agent:item-delta", {
      sessionId: this.sessionId,
      turnId: this.activeTurnId ?? "",
      itemId: String(p?.partID ?? ""),
      textChunk: String(p?.delta ?? ""),
    }));
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
    const item: any = {
      itemId, kind: "subtask", status: "running",
      title: String(info.title ?? "subagent"), agent: info.agent,
      ...(parentItemId ? { parentItemId } : {}),
    };
    this.send(createMessage("agent:item-added", {
      sessionId: this.sessionId, turnId: this.activeTurnId ?? "", itemId,
      ...(parentItemId ? { parentItemId } : {}),
      item,
    }));
  }

  // opencode's server generates a conversation title and pushes it on
  // session.updated. Forward it to the namer (per-session-safe: this driver ==
  // this chat session). Skip the seed title we set at createSession — echoing it
  // back would auto-name the session to its own project id, burying the default.
  private onSessionUpdated(p: any): void {
    const info = p?.info ?? {};
    if (!this.inTree(info.id)) return;
    const title = typeof info.title === "string" ? info.title.trim() : "";
    if (!title || title === this.title) return;
    this.onTitle?.(title);
  }

  private flipSubtask(sid: string, status: "completed" | "error" | "cancelled", rawError?: any): void {
    const itemId = this.subtaskItem.get(sid);
    if (!itemId) return;
    const parentItemId = this.subtaskItem.get(this.parentSession.get(sid) ?? "");
    const item: any = { itemId, kind: "subtask", status, ...(parentItemId ? { parentItemId } : {}) };
    if (status === "error" && rawError) item.error = mapOpencodeError(rawError);
    this.send(createMessage("agent:item-updated", { sessionId: this.sessionId, turnId: this.activeTurnId ?? "", itemId, item }));
    // Terminal state: the child session won't emit again, so drop its tracking.
    this.subtaskItem.delete(sid);
    this.parentSession.delete(sid);
  }

  private onSessionIdle(p: any): void {
    const sid: string = p?.sessionID ?? "";
    if (sid === this.rootSessionId) {
      if (!this.activeTurnId) return;
      const stopReason = this.cancelRequested ? "cancelled" : "end_turn";
      this.cancelRequested = false;
      this.send(createMessage("agent:turn-end", { sessionId: this.sessionId, turnId: this.activeTurnId, stopReason }));
      this.activeTurnId = null;
      this.endTurnCleanup();
    } else if (this.subtaskItem.has(sid)) {
      this.flipSubtask(sid, "completed");
    }
  }

  // Per-turn part/role state is only meaningful within a turn; clearing it at the
  // turn boundary keeps these maps from growing unbounded across a long session
  // (and lets a part id reused next turn re-emit item-added as a first sighting).
  private endTurnCleanup(): void {
    this.seenParts.clear();
    this.messageRole.clear();
    // A permission/question still pending when the turn ends is unanswerable —
    // tell the app so the prompt doesn't wedge on screen (same contract as the
    // codex driver's retraction).
    for (const permissionId of this.permissionSession.keys()) {
      this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, permissionId }));
    }
    this.permissionSession.clear();
    for (const questionId of this.pendingQuestionIds) {
      this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, questionId }));
    }
    this.pendingQuestionIds.clear();
    this.questionOptions.clear();
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
      this.cancelRequested = false;
      this.send(createMessage("agent:turn-end", {
        sessionId: this.sessionId,
        turnId,
        stopReason: cancelled ? "cancelled" : "error",
        ...(cancelled ? {} : { error }),
      }));
      this.activeTurnId = null;
      this.endTurnCleanup();
    } else if (this.subtaskItem.has(sid)) {
      this.flipSubtask(sid, "error", p?.error);
    } else {
      this.send(createMessage("agent:error", { sessionId: this.sessionId, error }));
    }
  }

  private onPermissionAsked(p: any): void {
    const permissionId: string = p?.id ?? "";
    const sid: string = p?.sessionID ?? this.rootSessionId;
    this.permissionSession.set(permissionId, sid);
    this.send(createMessage("agent:permission-request", {
      sessionId: this.sessionId,
      permissionId,
      // PermissionRequest.permission is the permission key (a string); `tool` is
      // {messageID, callID} with no name. Use the key as the title.
      title: String(p?.permission ?? "Allow action?"),
      options: [
        { optionId: "once", label: "Allow once", kind: "allow_once" },
        { optionId: "always", label: "Always allow", kind: "allow_always" },
        { optionId: "reject", label: "Deny", kind: "reject" },
      ],
    }));
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
    if (opts.length > 0) this.questionOptions.set(questionId, opts.map((o) => String(o?.label ?? "")));
    this.pendingQuestionIds.add(questionId);
    this.send(createMessage("agent:question", {
      sessionId: this.sessionId,
      questionId,
      kind,
      prompt: String(q.question ?? q.header ?? "?"),
      ...(opts.length > 0
        ? { options: opts.map((o, i) => ({ id: String(i), label: String(o?.label ?? ""), description: o?.description })) }
        : {}),
    }));
  }

  private onTodoUpdated(p: any): void {
    const sid: string = p?.sessionID ?? "";
    if (sid !== this.rootSessionId) return; // v1: only the root session's plan
    const turnId = this.activeTurnId ?? "";
    const itemId = `plan:${turnId}`;
    this.send(createMessage("agent:item-updated", {
      sessionId: this.sessionId, turnId, itemId,
      item: { itemId, kind: "plan", entries: mapPlanEntries(p?.todos) },
    }));
  }
}
