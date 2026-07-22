import { createMessage, createTranscriptReplay, type AbMessage } from "../protocol";
import {
  mapThreadItem,
  mapCodexError,
  mapTurnStatusToStopReason,
  mapPlanStepStatus,
  mapTokenBreakdown,
} from "./codex-mapping";
import { codexResumeReplay } from "./codex-resume-replay";
import { planElicitation, type FlatQuestion } from "./codex-elicitation";
import { resolveConfigPick } from "../structured/set-config";
import { logger } from "../logger";

// The slice of JsonRpcEndpoint the driver needs (injectable for tests).
export interface CodexEndpoint {
  request(method: string, params?: unknown): Promise<unknown>;
  notify(method: string, params?: unknown): void;
  onNotification(method: string, handler: (params: any) => void): void;
  onRequest(
    method: string,
    handler: (params: any, rpcId: number | string) => Promise<unknown> | unknown,
  ): void;
  // Fires once on an unexpected peer close (codex crashed/exited), not on dispose.
  onClose(handler: () => void): void;
  dispose(): void;
}

export interface CodexDriverOpts {
  sessionId: string;
  endpoint: CodexEndpoint;
  sendMessage: (msg: AbMessage) => void;
  cwd: string;
  model?: string;
  // Consulted when start() fails: a non-null result replaces the (generic)
  // RPC failure — e.g. "endpoint disposed" after codex died at spawn — with a
  // user-facing explanation from the process's captured stderr. The callback
  // must settle promptly (the caller bounds it; see agent-core's factory).
  diagnoseStartFailure?: () => Promise<string | null>;
}

type PendingApproval = { answer: (optionId: string | null) => void };
type PendingQuestion = { answer: (value: string) => void };

export class CodexDriver {
  private readonly sessionId: string;
  private readonly ep: CodexEndpoint;
  private readonly send: (msg: AbMessage) => void;
  private readonly cwd: string;

  // Capability discovery + per-session selection (agent:capabilities /
  // agent:set-config). Selections apply on the next turn/start — codex
  // persists per-turn overrides for subsequent turns.
  private capModels: Array<{ id: string; name: string; efforts?: string[]; defaultEffort?: string }> = [];
  private capModes: Array<{ id: string; name: string; description?: string }> = [];
  private capCommands: Array<{ id: string; name: string; description?: string; argHint?: string }> = [];
  private skillPaths = new Map<string, string>(); // command id -> skill path (UserInput::Skill needs it)
  private selModel?: string;
  private selEffort?: string;
  private selProfile?: string;
  // Picks that arrived before discovery populated the lists (a resumed session
  // replays yesterday's pickers to the app instantly, while discovery is still
  // in flight). Queued and validated once discovery lands, instead of being
  // silently rejected against empty lists.
  private capsDiscovered = false;
  private pendingConfig: Array<{ key: string; value: string }> = [];

  private threadId = "";
  private activeTurnId: string | null = null;
  private turnOrder: string[] = [];
  private pendingApprovals = new Map<string, PendingApproval>();
  private pendingQuestions = new Map<string, PendingQuestion>();
  private questionCounter = 0;
  // itemId -> changed file paths, cached from the fileChange item/started
  // notification so the approval prompt can name the touched files. codex
  // currently requests approval BEFORE starting the item (approval → run), so
  // this is empty at approval time and the title falls back — kept because the
  // approval params carry no paths and the ordering is codex's to change.
  private fileChangePaths = new Map<string, string[]>();
  private approvalCounter = 0;
  // Turns for which the structured turn/plan/updated stream has arrived; once
  // set, the text-blob plan item for that turn is ignored (structured wins).
  private structuredPlanTurns = new Set<string>();
  // String(inbound rpc id) -> retract closure. Every pending server->client
  // request registers one so serverRequest/resolved, turn end, and dispose can
  // answer codex locally AND tell the app the prompt is gone. A synthetic key
  // is used when the endpoint supplied no id (tests, defensive).
  private retractors = new Map<string, () => void>();
  private retractorSeq = 0;
  // Per reasoning item, the first channel to stream claims it for the rest of the
  // turn; deltas from the other channel are dropped so the raw-CoT and summary
  // text never interleave (codex normally emits only ONE channel per item, but
  // the order isn't guaranteed either way). The completed-item snapshot
  // reconciles the final text. reasoningSummaryIndex tracks the last summary
  // paragraph forwarded per item so paragraph breaks come from summaryIndex, not
  // from a summaryPartAdded event that codex may not emit.
  private reasoningChannel = new Map<string, "content" | "summary">();
  private reasoningSummaryIndex = new Map<string, number>();

  private retractorKey(rpcId: number | string | undefined): string {
    return rpcId === undefined ? `synth-${this.retractorSeq++}` : String(rpcId);
  }

  // Returns true if `channel` may stream for `itemId`: the first channel seen
  // claims the item; the loser is muted until the maps clear at turn end.
  private claimReasoning(itemId: string, channel: "content" | "summary"): boolean {
    const owner = this.reasoningChannel.get(itemId);
    if (owner === undefined) { this.reasoningChannel.set(itemId, channel); return true; }
    return owner === channel;
  }

  private readonly diagnoseStartFailure?: () => Promise<string | null>;

  constructor(opts: CodexDriverOpts) {
    this.sessionId = opts.sessionId;
    this.ep = opts.endpoint;
    this.send = opts.sendMessage;
    this.cwd = opts.cwd;
    this.selModel = opts.model;
    this.diagnoseStartFailure = opts.diagnoseStartFailure;
    this.registerHandlers();
  }

  async start(resumeId?: string): Promise<string> {
    // Advertise an empty, not-ready catalog immediately so the app shows a
    // loading indicator until discoverCapabilities() emits the real one.
    this.emitCapabilities();
    try {
      return await this.startInner(resumeId);
    } catch (err) {
      const diag = await this.diagnoseStartFailure?.().catch(() => null);
      if (diag) throw new Error(diag, { cause: err });
      throw err;
    }
  }

  private async startInner(resumeId?: string): Promise<string> {
    await this.ep.request("initialize", {
      clientInfo: { name: "antgrid-bridge", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    if (resumeId) {
      try {
        const res = (await this.ep.request("thread/resume", { threadId: resumeId })) as any;
        this.threadId = res?.thread?.id ?? resumeId;
        this.seedFromThreadResponse(res);
        const replay = createTranscriptReplay(this.sessionId, codexResumeReplay(this.sessionId, res?.thread));
        if (replay) this.send(replay);
        void this.discoverCapabilities();
        return this.threadId;
      } catch (err) {
        // Resume failed (thread deleted via codex's own tools, or a store
        // migration). Fall through to a fresh thread rather than a dead session;
        // the app clears the stale agentSessionId (see manager onAgentSession).
        logger.warn(
          "codex thread/resume failed for session %s (thread %s); starting a fresh thread: %s",
          this.sessionId,
          resumeId,
          err,
        );
      }
    }
    const res = (await this.ep.request("thread/start", { cwd: this.cwd, ...(this.selModel ? { model: this.selModel } : {}) })) as any;
    this.threadId = res?.thread?.id ?? "";
    this.seedFromThreadResponse(res);
    void this.discoverCapabilities();
    return this.threadId;
  }

  // On-demand re-derivation of this thread's completed-turn transcript, for a
  // client attaching to an already-running session (see session.transcriptSnapshot
  // in agent-core.ts). Unlike start(resumeId)'s thread/resume, thread/read does
  // NOT load/subscribe the thread as active — safe to call against a live thread
  // without disturbing it. The in-progress turn (if any) is excluded by status,
  // not by comparing to activeTurnId, so it stays correct even if the turn
  // completes in the gap between the request and the response.
  async getTranscriptSnapshot(): Promise<AbMessage[]> {
    if (!this.threadId) return [];
    try {
      const res = (await this.ep.request("thread/read", {
        threadId: this.threadId,
        includeTurns: true,
      })) as any;
      const turns: any[] = Array.isArray(res?.thread?.turns) ? res.thread.turns : [];
      const completed = turns.filter((t) => t?.status === "completed");
      return codexResumeReplay(this.sessionId, { ...res?.thread, turns: completed });
    } catch (err) {
      logger.warn(
        "codex thread/read failed for session %s (thread %s); returning empty transcript snapshot: %s",
        this.sessionId,
        this.threadId,
        err,
      );
      return [];
    }
  }

  async prompt(text: string, commandId?: string): Promise<void> {
    if (commandId === "builtin:compact") return this.compact();
    if (commandId === "builtin:review") {
      const instructions = text.trim();
      await this.ep.request("review/start", {
        threadId: this.threadId,
        target: instructions ? { type: "custom", instructions } : { type: "uncommittedChanges" },
        delivery: "inline",
      });
      return;
    }
    const input: unknown[] = [];
    if (commandId?.startsWith("skill:")) {
      const name = commandId.slice("skill:".length);
      const path = this.skillPaths.get(commandId);
      if (path) {
        input.push({ type: "skill", name, path });
        if (text.trim()) input.push({ type: "text", text });
      } else {
        // Path unknown (discovery raced/failed): degrade to the literal slash
        // form rather than dropping the invocation.
        input.push({ type: "text", text: text.trim() ? `/${name} ${text}` : `/${name}` });
      }
    } else {
      // Reachable when the app holds capabilities from another driver/session
      // (stale replay); the prompt still goes out, just without command routing.
      if (commandId) logger.warn("codex: unrecognized commandId %s; sending as plain prompt", commandId);
      input.push({ type: "text", text });
    }
    await this.ep.request("turn/start", {
      threadId: this.threadId,
      input,
      ...(this.selModel ? { model: this.selModel } : {}),
      ...(this.selEffort ? { effort: this.selEffort } : {}),
      ...(this.selProfile ? { permissions: this.selProfile } : {}),
    });
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
    const pick = resolveConfigPick(key, value, {
      models: this.capModels,
      modes: this.capModes,
      currentModelId: this.selModel,
      currentEffortId: this.selEffort,
    });
    if (!pick) return false;
    switch (pick.key) {
      case "model":
        this.selModel = pick.id;
        if (pick.clearEffort) this.selEffort = undefined;
        break;
      case "effort":
        this.selEffort = pick.id;
        break;
      case "mode":
        this.selProfile = pick.id;
        break;
    }
    return true;
  }

  private seedFromThreadResponse(res: any): void {
    if (!this.selModel && typeof res?.model === "string") this.selModel = res.model;
    if (!this.selEffort && typeof res?.reasoningEffort === "string") this.selEffort = res.reasoningEffort;
    const profile = res?.activePermissionProfile?.id;
    if (!this.selProfile && typeof profile === "string") this.selProfile = profile;
    this.seedTurnsFromThread(res?.thread);
  }

  private seedTurnsFromThread(thread: any): void {
    const turns: any[] = Array.isArray(thread?.turns) ? thread.turns : [];
    this.turnOrder = turns.map((t) => String(t?.id ?? "")).filter(Boolean);
  }

  // Every caller fire-and-forgets this, so a rejection would escape into the void
  // and reach the host's process-level unhandledRejection hook, which tears down
  // every project on the machine (see index.ts) — not just this session. The
  // inner allSettled covers the RPCs; this covers the post-processing, and keeps
  // each call site safe by construction.
  private async discoverCapabilities(): Promise<void> {
    try {
      await this.discoverCapabilitiesInner();
    } catch (err) {
      logger.warn("codex capability discovery failed for session %s: %s", this.sessionId, err);
    }
  }

  // Fail-soft: each query settles independently, so a codex build lacking one
  // RPC omits that section instead of suppressing the whole advertisement.
  private async discoverCapabilitiesInner(): Promise<void> {
    const [models, profiles, skills] = await Promise.allSettled([
      this.ep.request("model/list", {}),
      this.ep.request("permissionProfile/list", {}),
      this.ep.request("skills/list", { cwds: [this.cwd] }),
    ]);
    if (models.status === "fulfilled") {
      const data: any[] = Array.isArray((models.value as any)?.data) ? (models.value as any).data : [];
      this.capModels = data
        .filter((m) => !m?.hidden && m?.id)
        .map((m) => {
          const efforts = Array.isArray(m?.supportedReasoningEfforts)
            ? m.supportedReasoningEfforts.map((e: any) => String(e?.reasoningEffort ?? "")).filter(Boolean)
            : [];
          return {
            id: String(m.id),
            name: String(m?.displayName ?? m?.model ?? m.id),
            ...(efforts.length ? { efforts } : {}),
            ...(typeof m?.defaultReasoningEffort === "string" ? { defaultEffort: m.defaultReasoningEffort } : {}),
          };
        });
      if (!this.selModel) {
        const def = data.find((m) => m?.isDefault && m?.id);
        if (def) this.selModel = String(def.id);
      }
    }
    if (profiles.status === "fulfilled") {
      const data: any[] = Array.isArray((profiles.value as any)?.data) ? (profiles.value as any).data : [];
      this.capModes = data
        .filter((p) => p?.allowed !== false && p?.id)
        .map((p) => ({
          id: String(p.id),
          name: String(p.id),
          ...(p?.description ? { description: String(p.description) } : {}),
        }));
    }
    const commands: typeof this.capCommands = [];
    if (skills.status === "fulfilled") {
      const entries: any[] = Array.isArray((skills.value as any)?.data) ? (skills.value as any).data : [];
      for (const entry of entries) {
        for (const s of Array.isArray(entry?.skills) ? entry.skills : []) {
          if (s?.enabled === false || !s?.name) continue;
          const id = `skill:${s.name}`;
          commands.push({ id, name: String(s.name), ...(s?.description ? { description: String(s.description) } : {}) });
          if (typeof s?.path === "string") this.skillPaths.set(id, s.path);
        }
      }
    }
    commands.push(
      { id: "builtin:compact", name: "compact", description: "Summarize the conversation to free context" },
      { id: "builtin:review", name: "review", description: "Review changes", argHint: "[instructions]" },
    );
    this.capCommands = commands;
    this.capsDiscovered = true;
    const queued = this.pendingConfig;
    this.pendingConfig = [];
    for (const p of queued) this.applyConfig(p.key, p.value);
    this.emitCapabilities();
  }

  private emitCapabilities(): void {
    this.send(createMessage("agent:capabilities", {
      sessionId: this.sessionId,
      ready: this.capsDiscovered,
      commands: this.capCommands,
      modes: this.capModes,
      models: this.capModels,
      ...(this.selModel ? { currentModelId: this.selModel } : {}),
      ...(this.selEffort ? { currentEffortId: this.selEffort } : {}),
      ...(this.selProfile ? { currentModeId: this.selProfile } : {}),
    }));
  }

  async cancel(turnId?: string): Promise<boolean> {
    if (!this.activeTurnId) return false;
    // Stale turnId => refuse rather than interrupt the live turn; see the
    // claude driver's cancel for the full rationale. Absent => cancel the live one.
    if (turnId && turnId !== this.activeTurnId) return false;
    await this.ep.request("turn/interrupt", { threadId: this.threadId, turnId: this.activeTurnId });
    return true;
  }

  async compact(): Promise<void> {
    await this.ep.request("thread/compact/start", { threadId: this.threadId });
  }

  async revert(target: { turnId?: string }): Promise<void> {
    if (!target.turnId) throw new Error("revert requires a turn id");
    const idx = this.turnOrder.indexOf(target.turnId);
    if (idx < 0) throw new Error("revert target turn not found");
    const numTurns = this.turnOrder.length - idx;
    const res = await this.ep.request("thread/rollback", {
      threadId: this.threadId,
      numTurns,
    });
    this.seedTurnsFromThread((res as any)?.thread);
    this.send(createMessage("agent:session-reset", { sessionId: this.sessionId }));
    const replay = createTranscriptReplay(this.sessionId, codexResumeReplay(this.sessionId, (res as any)?.thread));
    if (replay) this.send(replay);
  }

  resolvePermission(permissionId: string, optionId: string): void {
    const pending = this.pendingApprovals.get(permissionId);
    if (!pending) return;
    this.pendingApprovals.delete(permissionId);
    pending.answer(optionId);
  }

  resolveQuestion(questionId: string, answer: string | string[]): void {
    const pending = this.pendingQuestions.get(questionId);
    if (!pending) return;
    this.pendingQuestions.delete(questionId);
    // This driver only emits text/single_select questions (v1), so a
    // multi_select array is collapsed defensively to its first element.
    pending.answer(Array.isArray(answer) ? (answer[0] ?? "") : answer);
  }

  // Widened to `void | Promise<void>` because agent-core wraps this to also await
  // the codex process's exit (see the factory in agent-core.ts).
  dispose(): void | Promise<void> {
    this.retractAllPending();
    this.pendingApprovals.clear();
    this.pendingQuestions.clear();
    this.ep.dispose();
  }

  private retractAllPending(): void {
    const pending = [...this.retractors.values()];
    this.retractors.clear();
    for (const retract of pending) retract();
  }

  // codex died mid-turn (stdout closed before turn/completed): emit a terminal
  // turn-end so the app's active turn resolves instead of spinning. No-op when
  // idle. Runs only on an UNEXPECTED close — dispose() suppresses the endpoint's
  // onClose (see jsonrpc-stdio.ts).
  private endActiveTurnOnClose(): void {
    const turnId = this.activeTurnId;
    if (!turnId) return;
    this.send(createMessage("agent:turn-end", {
      sessionId: this.sessionId,
      turnId,
      stopReason: "error",
      error: {
        category: "unknown",
        message: "codex session ended unexpectedly",
        retryable: false,
      },
    }));
    this.fileChangePaths.clear();
    this.reasoningChannel.clear();
    this.reasoningSummaryIndex.clear();
    this.structuredPlanTurns.clear();
    this.retractAllPending();
    this.activeTurnId = null;
  }

  private registerHandlers(): void {
    this.ep.onClose(() => this.endActiveTurnOnClose());

    this.ep.onNotification("turn/started", (p) => {
      this.activeTurnId = p?.turn?.id ?? null;
      if (this.activeTurnId && !this.turnOrder.includes(this.activeTurnId)) {
        this.turnOrder.push(this.activeTurnId);
      }
      this.send(createMessage("agent:turn-start", {
        sessionId: this.sessionId,
        turnId: this.activeTurnId ?? "",
      }));
    });

    this.ep.onNotification("turn/completed", (p) => {
      const turn = p?.turn ?? {};
      const turnId: string = turn.id ?? this.activeTurnId ?? "";
      if (turnId && !this.turnOrder.includes(turnId)) this.turnOrder.push(turnId);
      const stopReason = mapTurnStatusToStopReason(turn.status ?? "completed");
      if (turn.error) {
        const error = mapCodexError(turn.error.codexErrorInfo ?? turn.error, turn.error.message ?? "turn failed");
        this.send(createMessage("agent:turn-end", { sessionId: this.sessionId, turnId, stopReason, error }));
      } else {
        this.send(createMessage("agent:turn-end", { sessionId: this.sessionId, turnId, stopReason }));
      }
      this.fileChangePaths.clear();
      this.reasoningChannel.clear();
      this.reasoningSummaryIndex.clear();
      this.structuredPlanTurns.clear();
      this.retractAllPending();
      this.activeTurnId = null;
    });

    this.ep.onNotification("item/started", (p) => {
      if (p?.item?.type === "fileChange") {
        const changes: any[] = Array.isArray(p.item.changes) ? p.item.changes : [];
        this.fileChangePaths.set(String(p.item.id ?? ""), changes.map((c) => String(c?.path ?? "")));
      }
      if (p?.item?.type === "plan") return this.handleTextPlan(p);
      const item = mapThreadItem(p?.item);
      if (!item) return;
      this.send(createMessage("agent:item-added", {
        sessionId: this.sessionId,
        turnId: p?.turnId ?? this.activeTurnId ?? "",
        itemId: item.itemId,
        parentItemId: item.parentItemId,
        item,
      }));
    });

    this.ep.onNotification("item/completed", (p) => {
      if (p?.item?.type === "fileChange") this.fileChangePaths.delete(String(p.item.id ?? ""));
      if (p?.item?.type === "plan") return this.handleTextPlan(p);
      const item = mapThreadItem(p?.item);
      if (!item) return;
      this.send(createMessage("agent:item-updated", {
        sessionId: this.sessionId,
        turnId: p?.turnId ?? this.activeTurnId ?? "",
        itemId: item.itemId,
        item,
      }));
    });

    // Structured plan: replaces any text-blob plan for the turn (codex's own
    // doc favors the step list). Both feed one synthetic plan:<turnId> item.
    this.ep.onNotification("turn/plan/updated", (p) => {
      const turnId: string = p?.turnId ?? this.activeTurnId ?? "";
      this.structuredPlanTurns.add(turnId);
      const steps: any[] = Array.isArray(p?.plan) ? p.plan : [];
      this.emitPlan(turnId, steps.map((s) => ({
        text: String(s?.step ?? ""),
        status: mapPlanStepStatus(s?.status),
      })));
    });

    this.ep.onNotification("thread/tokenUsage/updated", (p) => {
      const u = p?.tokenUsage ?? {};
      this.send(createMessage("agent:usage", {
        sessionId: this.sessionId,
        turnId: p?.turnId ?? this.activeTurnId ?? undefined,
        total: mapTokenBreakdown(u.total),
        last: mapTokenBreakdown(u.last),
        contextWindow: typeof u.modelContextWindow === "number" ? u.modelContextWindow : null,
      }));
    });

    // One wire frame (agent:item-delta) for every streamable chunk; the app
    // routes each by the target item's kind (message/reasoning → text,
    // tool_call → terminal output). agentMessage + commandExecution output are
    // both plain text on the codex side (the base64 command/exec/outputDelta is
    // a different, unused connection-scoped API).
    const onTextDelta = (p: any): void => {
      this.send(createMessage("agent:item-delta", {
        sessionId: this.sessionId,
        turnId: p?.turnId ?? this.activeTurnId ?? "",
        itemId: p?.itemId ?? "",
        textChunk: String(p?.delta ?? ""),
      }));
    };
    this.ep.onNotification("item/agentMessage/delta", onTextDelta);
    this.ep.onNotification("item/commandExecution/outputDelta", onTextDelta);
    this.ep.onNotification("item/reasoning/textDelta", (p) => {
      if (!this.claimReasoning(String(p?.itemId ?? ""), "content")) return;
      onTextDelta(p);
    });
    // codex commonly emits ONLY the summary channel; forwarding it is what makes
    // thinking stream at all for most turns. mapThreadItem's snapshot joins
    // summary parts with "\n\n"; inject that break when summaryIndex advances so
    // the streamed text matches the snapshot even if summaryPartAdded is skipped.
    this.ep.onNotification("item/reasoning/summaryTextDelta", (p) => {
      const itemId = String(p?.itemId ?? "");
      if (!this.claimReasoning(itemId, "summary")) return;
      const idx = Number(p?.summaryIndex ?? 0);
      const prev = this.reasoningSummaryIndex.get(itemId);
      if (prev !== undefined && idx > prev) {
        this.send(createMessage("agent:item-delta", {
          sessionId: this.sessionId,
          turnId: p?.turnId ?? this.activeTurnId ?? "",
          itemId,
          textChunk: "\n\n",
        }));
      }
      this.reasoningSummaryIndex.set(itemId, idx);
      onTextDelta(p);
    });
    // item/plan/delta is intentionally NOT forwarded: codex marks it EXPERIMENTAL
    // and warns concatenated deltas need not match the completed plan. The
    // structured turn/plan/updated stream is the authoritative plan source.

    // codex withdrew a pending server->client request (e.g. turn aborted). The
    // requestId matches the original request's inbound rpc id; fire its retractor
    // to answer codex locally and drop the app-side prompt.
    this.ep.onNotification("serverRequest/resolved", (p) => {
      // No id means nothing to correlate; bail rather than let a missing id
      // collapse to the "" key and fire an unrelated retractor.
      if (p?.requestId == null) return;
      const key = String(p.requestId);
      const retract = this.retractors.get(key);
      if (!retract) return;
      this.retractors.delete(key);
      retract();
    });

    this.ep.onRequest("item/commandExecution/requestApproval", (p, rpcId) =>
      this.handleApproval(p, rpcId, {
        title: p?.command ?? "Run command?",
        options: [
          { optionId: "ok", label: "Allow", kind: "allow_once" },
          { optionId: "always", label: "Allow for session", kind: "allow_always" },
          { optionId: "no", label: "Deny", kind: "reject" },
        ],
        // codex CommandExecutionApprovalDecision; null = retracted -> cancel.
        reply: (o) => ({
          decision: o === "ok" ? "accept" : o === "always" ? "acceptForSession" : o === null ? "cancel" : "decline",
        }),
      }));
    this.ep.onRequest("item/fileChange/requestApproval", (p, rpcId) =>
      this.handleApproval(p, rpcId, {
        title: this.fileChangeTitle(p?.itemId),
        options: [
          { optionId: "ok", label: "Allow", kind: "allow_once" },
          { optionId: "no", label: "Deny", kind: "reject" },
        ],
        // codex FileChangeApprovalDecision: accept|acceptForSession|decline|cancel
        // (v2/item.rs). null = retracted -> cancel (interrupts the turn).
        reply: (o) => ({ decision: o === "ok" ? "accept" : o === null ? "cancel" : "decline" }),
      }));
    // Reply shape verified against codex-rs/app-server-protocol/src/protocol/v2/permissions.rs:
    // GrantedPermissionProfile {network?, fileSystem?} + scope "turn"|"session".
    // There is no deny sentinel — deny = empty grant with turn scope; the granted
    // profile echoes the request (same field shapes on both sides).
    this.ep.onRequest("item/permissions/requestApproval", (p, rpcId) =>
      this.handleApproval(p, rpcId, {
        title: permissionsTitle(p?.permissions),
        options: [
          { optionId: "ok", label: "Allow", kind: "allow_once" },
          { optionId: "always", label: "Allow for session", kind: "allow_always" },
          { optionId: "no", label: "Deny", kind: "reject" },
        ],
        reply: (o) => ({
          permissions: o === "ok" || o === "always" ? (p?.permissions ?? {}) : {},
          scope: o === "always" ? "session" : "turn",
        }),
      }));

    this.ep.onRequest("item/tool/requestUserInput", (p, rpcId) => this.handleUserInput(p, rpcId));

    this.ep.onRequest("mcpServer/elicitation/request", (p, rpcId) => this.handleElicitation(p, rpcId));
  }

  // Fan a set of prompts out as agent:question, collect one answer each, and
  // reply to codex exactly once — when every prompt is answered (finishComplete)
  // or when the turn dies and the still-pending prompts are retracted
  // (finishRetracted). Shared by requestUserInput and the elicitation form path,
  // which differ only in how they build each prompt and assemble their reply. A
  // single retractor is keyed by the inbound rpc id; the per-prompt answer path
  // is guarded so a prompt is counted at most once. Callers guarantee items ≥ 1.
  private collectAnswers<T>(
    rpcId: number | string | undefined,
    items: T[],
    spec: {
      send: (item: T, questionId: string) => void;
      onAnswer: (item: T, value: string) => void;
      finishComplete: () => void;
      finishRetracted: (retracted: T[]) => void;
    },
  ): void {
    const key = this.retractorKey(rpcId);
    const open = new Map<string, T>();
    let remaining = items.length;
    this.retractors.set(key, () => {
      const retracted: T[] = [];
      for (const [questionId, item] of open) {
        if (this.pendingQuestions.delete(questionId)) {
          retracted.push(item);
          this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, questionId }));
        }
      }
      open.clear();
      spec.finishRetracted(retracted);
    });
    for (const item of items) {
      const questionId = `q-${this.questionCounter++}`;
      open.set(questionId, item);
      spec.send(item, questionId);
      this.pendingQuestions.set(questionId, {
        answer: (value) => {
          if (!open.delete(questionId)) return;
          spec.onAnswer(item, value);
          if (--remaining === 0) {
            this.retractors.delete(key);
            spec.finishComplete();
          }
        },
      });
    }
  }

  // One agent:question per codex questions[] entry; the RPC reply is sent once,
  // after ALL entries are answered: {answers: {<codexId>: {answers: [text]}}}.
  // codex options carry only label+description (no id) — synthesize index ids
  // for the app and translate the echoed index back to the label, mirroring
  // opencode-driver's questionOptions pattern.
  private handleUserInput(p: any, rpcId?: number | string): Promise<unknown> {
    const rawQuestions: any[] = Array.isArray(p?.questions) ? p.questions : [];
    const prepared = rawQuestions.map((q) => {
      const opts: any[] = Array.isArray(q?.options) ? q.options : [];
      return {
        codexId: String(q?.id ?? ""),
        prompt: String(q?.question ?? q?.header ?? "?"),
        isSecret: !!q?.isSecret,
        hasOptions: opts.length > 0 && !q?.isOther,
        labels: opts.map((o) => String(o?.label ?? "")),
        options: opts.map((o, i) => ({
          id: String(i),
          label: String(o?.label ?? ""),
          ...(o?.description ? { description: String(o.description) } : {}),
        })),
      };
    });
    return new Promise((resolve) => {
      const answers: Record<string, { answers: string[] }> = {};
      if (prepared.length === 0) return resolve({ answers });
      this.collectAnswers(rpcId, prepared, {
        send: (q, questionId) => this.send(createMessage("agent:question", {
          sessionId: this.sessionId,
          questionId,
          itemId: p?.itemId,
          kind: q.hasOptions ? "single_select" : "text",
          prompt: q.prompt,
          ...(q.isSecret ? { isSecret: true } : {}),
          ...(q.hasOptions ? { options: q.options } : {}),
        })),
        onAnswer: (q, value) => {
          const i = Number(value);
          const text = q.hasOptions && Number.isInteger(i) && i >= 0 && i < q.labels.length ? q.labels[i]! : value;
          answers[q.codexId] = { answers: [text] };
        },
        // Partial sets still reply — collected answers stand, retracted entries
        // fill an empty array — then the app-side prompts are withdrawn.
        finishComplete: () => resolve({ answers }),
        finishRetracted: (retracted) => {
          for (const q of retracted) answers[q.codexId] ??= { answers: [] };
          resolve({ answers });
        },
      });
    });
  }

  // An MCP server behind codex asks the user for structured input. Flatten it
  // (codex-elicitation) onto agent:question primitives and reassemble the reply.
  private handleElicitation(p: any, rpcId?: number | string): Promise<unknown> {
    const plan = planElicitation(p);
    return new Promise((resolve) => {
      // Single-prompt paths (url / json-fallback) manage their own retractor
      // because the answer value itself decides accept vs decline; the multi-
      // field form path below uses the shared collectAnswers helper instead.
      if (plan.mode === "url" || plan.mode === "json-fallback") {
        const key = this.retractorKey(rpcId);
        const questionId = `q-${this.questionCounter++}`;
        this.sendQuestion(questionId, plan.question);
        this.retractors.set(key, () => {
          if (this.pendingQuestions.delete(questionId)) {
            this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, questionId }));
          }
          resolve({ action: "cancel" });
        });
        this.pendingQuestions.set(questionId, {
          answer: (v) => {
            this.retractors.delete(key);
            if (plan.mode === "url") {
              resolve(v === "done" ? { action: "accept" } : { action: "decline" });
              return;
            }
            try {
              resolve({ action: "accept", content: JSON.parse(v) });
            } catch {
              // Never leave the server request hanging on a bad answer; decline
              // and tell the user why the prompt vanished.
              resolve({ action: "decline" });
              this.send(createMessage("agent:error", {
                sessionId: this.sessionId,
                error: {
                  category: "unknown",
                  message: "elicitation answer was not valid JSON; request declined",
                  retryable: false,
                },
              }));
            }
          },
        });
        return;
      }
      const content: Record<string, unknown> = {};
      // planElicitation never yields an empty form (it falls through to the JSON
      // prompt), so this is a defensive cancel, not a silent auto-accept.
      if (plan.questions.length === 0) return resolve({ action: "cancel" });
      this.collectAnswers(rpcId, plan.questions, {
        send: (fq, questionId) => this.sendQuestion(questionId, fq),
        onAnswer: (fq, v) => { content[fq.name] = fq.coerce(v); },
        finishComplete: () => resolve({ action: "accept", content }),
        finishRetracted: () => resolve({ action: "cancel" }),
      });
    });
  }

  private sendQuestion(questionId: string, q: FlatQuestion): void {
    this.send(createMessage("agent:question", {
      sessionId: this.sessionId,
      questionId,
      kind: q.kind,
      prompt: q.prompt,
      ...(q.options ? { options: q.options } : {}),
    }));
  }

  private handleApproval(p: any, rpcId: number | string | undefined, opts: {
    title: string;
    options: Array<{ optionId: string; label: string; kind: "allow_once" | "allow_always" | "reject" }>;
    reply: (optionId: string | null) => unknown;
  }): Promise<unknown> {
    const permissionId = `perm-${this.approvalCounter++}`;
    this.send(createMessage("agent:permission-request", {
      sessionId: this.sessionId,
      permissionId,
      itemId: p?.itemId,
      title: opts.title,
      reason: p?.reason ?? undefined,
      options: opts.options,
    }));
    return new Promise((resolve) => {
      const key = this.retractorKey(rpcId);
      this.pendingApprovals.set(permissionId, {
        answer: (o) => {
          this.retractors.delete(key);
          resolve(opts.reply(o));
        },
      });
      this.retractors.set(key, () => {
        if (!this.pendingApprovals.delete(permissionId)) return;
        resolve(opts.reply(null));
        this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, permissionId }));
      });
    });
  }

  private fileChangeTitle(itemId: unknown): string {
    const paths = this.fileChangePaths.get(String(itemId ?? "")) ?? [];
    if (paths.length === 0) return "Apply file changes?";
    const shown = paths.slice(0, 3).join(", ");
    return `Apply changes to ${paths.length} file(s): ${shown}${paths.length > 3 ? ", …" : ""}`;
  }

  // codex's text-blob plan item — folded into the same synthetic plan item that
  // turn/plan/updated drives, and skipped once a structured plan has arrived.
  private handleTextPlan(p: any): void {
    const turnId: string = p?.turnId ?? this.activeTurnId ?? "";
    if (this.structuredPlanTurns.has(turnId)) return;
    this.emitPlan(turnId, [{ text: String(p?.item?.text ?? ""), status: "pending" }]);
  }

  private emitPlan(turnId: string, entries: Array<{ text: string; status: string }>): void {
    const itemId = `plan:${turnId}`;
    this.send(createMessage("agent:item-updated", {
      sessionId: this.sessionId,
      turnId,
      itemId,
      item: { itemId, kind: "plan", entries },
    }));
  }
}

function permissionsTitle(profile: any): string {
  const parts: string[] = [];
  if (profile && typeof profile === "object") {
    if (profile.network) parts.push("network");
    if (profile.fileSystem) parts.push("file system");
  }
  return parts.length > 0 ? `Grant permissions: ${parts.join(", ")}` : "Grant additional permissions?";
}
