import type { CanUseTool } from "@anthropic-ai/claude-agent-sdk";
import { createMessage, createTranscriptReplay, type AbMessage } from "../protocol";
import type { StructuredDriver } from "../structured/structured-manager";
import type { ClaudeQueryLike, PromptStreamController } from "./spawn-claude";
import { resolveConfigPick } from "../structured/set-config";
import {
  mapAssistantContent, mapToolKind, mapUsage, addUsage, mapResultError, mapFailureError,
  type ClaudeUsageTotals, type ClaudeRateLimit,
} from "./claude-mapping";
import { claudeResumeReplay } from "./claude-resume-replay";
import { readClaudeTranscript } from "./claude-transcript-read";
import { logger } from "../logger";
const log = logger.child({ component: "claude-driver" });

// The SDK's `displayName` is a bare family name ("Sonnet"); the version lives
// in `resolvedModel`, the canonical wire id ("claude-sonnet-5", "claude-opus-4-8").
// Fold the version into the label so the composer shows "Sonnet 5" / "Opus 4.8"
// instead of a version-less name. Rules: strip the `[1m]` 1M-context marker the
// SDK appends to some wire ids (claude-opus-4-8[1m]) so the last version segment
// still parses; skip if displayName already carries a digit (SDK gave a
// versioned name); skip synthetic alias rows like "Default" whose wire id
// belongs to a different family; drop the trailing 8-digit date stamp
// (claude-haiku-4-5-20251001 → "Haiku 4.5").
export function prettyModelName(displayName: unknown, resolvedModel: unknown): string {
  const name = String(displayName ?? "").trim();
  const resolved = String(resolvedModel ?? "").trim().replace(/\[[^\]]*\]/g, "");
  if (!name) return resolved;
  if (/\d/.test(name) || !resolved) return name;
  // Only stamp a version when the wire id is actually this family — otherwise a
  // "Default" row resolving to some concrete model would become "Default 5".
  if (!resolved.toLowerCase().includes(name.toLowerCase())) return name;
  const version = resolved
    .replace(/^claude-/, "")
    .split("-")
    .filter((p) => /^\d+$/.test(p) && !/^\d{8}$/.test(p))
    .join(".");
  return version ? `${name} ${version}` : name;
}

type CatalogModel = { id: string; name: string; efforts?: string[]; defaultEffort?: string };

// ModelInfo = { value, displayName, resolvedModel, supportsEffort, supportedEffortLevels, ... }
// — `value` is the id setModel takes; shared by initializationResult().models
// and supportedModels() (identical shape, see spawn-claude.ts's ClaudeQueryLike).
function mapModelInfos(models: any[]): CatalogModel[] {
  return models
    .filter((m: any) => m?.value)
    .map((m: any) => {
      const base: string[] =
        m.supportsEffort && Array.isArray(m.supportedEffortLevels) && m.supportedEffortLevels.length
          ? m.supportedEffortLevels.map(String)
          : [];
      // "ultracode" is a session flag (xhigh + standing dynamic-workflow
      // orchestration), not a catalog effort level, but Claude Code surfaces it
      // as the top rung of the effort selector — mirror that. The SDK gates it
      // on an xhigh-capable model, so only offer it where xhigh is present.
      const efforts = base.includes("xhigh") ? [...base, "ultracode"] : base;
      return {
        id: String(m.value), name: prettyModelName(m.displayName ?? m.value, m.resolvedModel),
        ...(efforts.length ? { efforts } : {}),
        // Claude's ModelInfo carries no default-effort marker, so seed one from
        // the catalog order: the 2nd real rung (base[1]). The composer shows
        // this as the effort pill's default and the driver applies it to the
        // session (see seedDefaultEffort) so pill and session effort stay in
        // lockstep. Derived from `base`, never `efforts`, so the appended
        // "ultracode" pseudo-rung is never picked as a silent default — it's a
        // heavy session flag (xhigh + standing orchestration), not a sane default.
        ...(base.length > 1 ? { defaultEffort: base[1] } : {}),
      };
    });
}

// Strip the SDK's optional [1m] context-window marker (claude-opus-4-8[1m]) so
// resolved wire ids compare on their bare form across catalog rows and init.
function stripModelMarker(id: string): string {
  return id.replace(/\[[^\]]*\]/g, "");
}

// Map a concrete resolved wire id ("claude-opus-4-8") back to the alias row the
// composer is keyed on ("opus"), matching on either `value` or `resolvedModel`
// and skipping the synthetic "default" row. Used both to reconcile
// system:init.model and to follow the default row to its concrete model.
function aliasIdForResolved(rawModels: any[], wireId: string): string | undefined {
  const target = stripModelMarker(wireId);
  const row = rawModels.find(
    (m) => m?.value !== "default" &&
      (stripModelMarker(String(m?.resolvedModel ?? "")) === target ||
        stripModelMarker(String(m?.value ?? "")) === target),
  );
  return row ? String(row.value) : undefined;
}

// The SDK catalog carries a synthetic "default" row (value: "default") standing
// for the account's configured default model. Resolve it to the CONCRETE alias
// row it points to (via resolvedModel) so the composer shows a real model name
// ("Opus 4.8") instead of "Default". Returns undefined when there's no default
// row or no concrete sibling to resolve to.
function resolveDefaultModelId(rawModels: any[]): string | undefined {
  const def = rawModels.find((m) => m?.value === "default");
  const target = def?.resolvedModel ? stripModelMarker(String(def.resolvedModel)) : "";
  return target ? aliasIdForResolved(rawModels, target) : undefined;
}

// Hard ceiling on dispose()'s wait for the consume loop to end naturally
// before escalating to abort(), and again after abort() before giving up.
const DISPOSE_GRACE_MS = 6_000;
const DISPOSE_ABORT_GRACE_MS = 1_000;
// Stderr tail is truncated before being appended to an emitted error message
// so one runaway stderr burst can't blow up the agent:error payload.
const STDERR_TAIL_MAX_CHARS = 2_000;
// Bound on the in-memory transcript history (see `history`) — keeps a
// long-lived session's getTranscriptSnapshot() replay from growing unbounded.
const HISTORY_MAX_ENTRIES = 500;

export interface ClaudeDriverOpts {
  sessionId: string;
  sendMessage: (m: AbMessage) => void;
  model?: string;
  // Injected so tests supply a fake query; agent-core passes real spawnClaude.
  spawn: (args: { canUseTool: CanUseTool; abort: AbortController; resume?: string }) => { query: ClaudeQueryLike; controller: PromptStreamController };
  // Project cwd — needed to locate Claude Code's on-disk transcript for
  // cold-resume backfill (getTranscriptSnapshot). Omitted by tests that don't
  // exercise disk backfill (then the in-memory fallback is used).
  cwd?: string;
  // Injected transcript reader (tests supply a fake; agent-core omits it to use
  // the real on-disk reader). Returns claudeResumeReplay-shaped history entries.
  readTranscript?: (cwd: string, agentSessionId: string) => Promise<any[]> | any[];
  // Called when the Claude SDK reports its native session id via system:init.
  // start() returns before init arrives (the SDK boots the subprocess only on
  // the first prompt), so the id is surfaced here for resume persistence —
  // agent-core wires this to sessions.setAgentSession (overwrite-latest).
  onSessionId?: (agentSessionId: string) => void;
  // Recent subprocess stderr, tailed onto an error message emitted when the
  // consume loop dies unexpectedly — the SDK's own stderr callback otherwise
  // has no other sink (see agent-core's factory ring buffer).
  stderrTail?: () => string;
}

export class ClaudeDriver implements StructuredDriver {
  private readonly sessionId: string;
  private readonly send: (m: AbMessage) => void;
  private readonly spawnFn: ClaudeDriverOpts["spawn"];

  private q: ClaudeQueryLike | null = null;
  private controller: PromptStreamController | null = null;
  private abort = new AbortController();
  private activeTurnId: string | null = null;
  private turnCounter = 0;
  private disposed = false;
  // Completion promise of the consume loop launched by start(); dispose()
  // awaits this (with a timeout) instead of returning before the SDK's
  // subprocess has actually been asked to exit.
  private consumeDone: Promise<void> = Promise.resolve();

  // itemId first-sighting tracker: first → item-added, later → item-updated.
  private seenItems = new Set<string>();
  // The app treats each item frame as a full replacement (codex parity), so
  // partial updates (e.g. tool completion) merge over the cached item.
  private itemCache = new Map<string, Record<string, unknown>>();
  private cancelRequested = false;
  // The CLI announces a usage limit on its own `rate_limit_event` channel,
  // BEFORE the turn dies, and the failing result chunk names no cause. Holding
  // the last rejection lets a failure be classified as a limit (which the
  // handler lifecycle parks on) instead of a generic error.
  private rateLimited: { resetsAt?: number } | null = null;
  // agent:usage `total` is cumulative for the session (see protocol.ts); the
  // SDK result chunk reports per-turn usage, so accumulate here.
  private usageTotal: ClaudeUsageTotals = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 0 };
  // Multiple init frames can overlap their fire-and-forget context RPCs. Only
  // the newest response may seed the meter; an older pre-compaction response
  // must not overwrite the post-compaction occupancy.
  private contextUsageGeneration = 0;

  // In-memory transcript for getTranscriptSnapshot() — the SDK exposes no
  // transcript-read API (probe-verified), so this driver keeps its own
  // shape-compatible history (claudeResumeReplay's contract) and replays it
  // as a synthetic turn for clients attaching to an already-running session.
  // Real user prompts only (not the "/compact" push) and each turn's final
  // assistant text, capped so a long-lived session can't grow unbounded.
  private history: any[] = [];

  // Capability discovery + selection (identical contract to codex-driver).
  private capModels: CatalogModel[] = [];
  // Last raw SDK model list, kept so resolvedModel-based mapping (default row →
  // concrete alias, system:init.model → alias) can run outside mapModelInfos,
  // which drops resolvedModel from the emitted catalog.
  private rawModelCatalog: any[] = [];
  private capCommands: Array<{ id: string; name: string; description?: string; argHint?: string }> = [];
  // Permission modes are the SDK's fixed PermissionMode enum (setPermissionMode),
  // NOT a discovered catalog — supportedAgents() lists subagent definitions,
  // which are not modes. bypassPermissions is deliberately not offered remotely
  // (it skips every permission check — unsafe over the wire).
  private capModes: Array<{ id: string; name: string; description?: string }> = [
    { id: "default", name: "Default", description: "Ask before each tool use" },
    { id: "auto", name: "Auto", description: "Model classifier approves or denies tool prompts" },
    { id: "acceptEdits", name: "Accept edits", description: "Auto-approve file edits" },
    { id: "plan", name: "Plan", description: "Read-only planning mode" },
  ];
  private selModel?: string;
  private resolvedModel?: string;
  private selMode?: string; // permission mode: default | acceptEdits | plan
  // Newest in-flight pick per axis ("model" | "mode" | "effort"), so a slow
  // rejection can tell whether it still owns the selection it wants to roll back.
  private pickSeq = new Map<string, number>();
  private selEffort?: string;
  // The user (constructor opts.model / setConfig) pinned this axis — blocks the
  // eager default resolution and the system:init reconciliation from overriding it.
  private modelExplicit = false;
  private effortExplicit = false;
  private capsDiscovered = false;
  private pendingConfig: Array<{ key: string; value: string }> = [];

  // canUseTool permission bridge + AskUserQuestion interception state.
  private pendingApprovals = new Map<string, (o: string | null) => void>();
  private pendingQuestions = new Map<string, (v: string | null) => void>();
  private questionOptions = new Map<string, string[]>();
  private approvalCounter = 0;
  private questionCounter = 0;

  private readonly onSessionId?: (agentSessionId: string) => void;
  private readonly stderrTail?: () => string;
  private readonly cwd?: string;
  private readonly readTranscript: (cwd: string, agentSessionId: string) => Promise<any[]> | any[];
  private resumeRequested?: string;
  // The Claude session id whose on-disk transcript backfills a cold resume.
  // Pinned to the resumed id (its file holds the pre-resume history); for a
  // fresh session it captures the SDK's new id at init. See getTranscriptSnapshot.
  private agentSessionId?: string;

  constructor(opts: ClaudeDriverOpts) {
    this.sessionId = opts.sessionId;
    this.send = opts.sendMessage;
    this.spawnFn = opts.spawn;
    this.selModel = opts.model;
    this.modelExplicit = !!opts.model;
    this.onSessionId = opts.onSessionId;
    this.stderrTail = opts.stderrTail;
    this.cwd = opts.cwd;
    this.readTranscript = opts.readTranscript ?? readClaudeTranscript;
  }

  async start(resumeId?: string): Promise<string> {
    this.resumeRequested = resumeId;
    // Anchor on-disk transcript backfill to the resumed id up front (its file
    // holds the pre-resume conversation), before init reports anything.
    this.agentSessionId = resumeId;
    const spawned = this.spawnFn({ canUseTool: this.makeCanUseTool(), abort: this.abort, resume: resumeId });
    this.q = spawned.query;
    this.controller = spawned.controller;
    // Stored (not fire-and-forget) so dispose() can await the loop actually
    // draining/erroring out instead of returning before the SDK subprocess has
    // been asked to exit — see dispose().
    this.consumeDone = this.consumeLoop();
    // Do NOT await system:init: the Claude SDK boots the subprocess (and emits
    // init) only after the first prompt-stream message, which prompt() pushes —
    // and the manager only calls prompt() after start() resolves. Awaiting init
    // here would deadlock. The real session id is captured in onInit and
    // surfaced via onSessionId; the empty return makes the manager's
    // `if (agentId)` guard skip persistence until the real id arrives.
    //
    // Emit a cheap capabilities frame right away (static modes, empty
    // models/commands) so the app receives SOMETHING for this session before
    // the user's first prompt — codex/opencode both fire discoverCapabilities()
    // synchronously from start() for the same reason. Without this, nothing
    // reaches the app until the user's own first message boots the subprocess,
    // and the app's per-session loading indicator (flipped by the first
    // inbound frame) spins forever instead of showing "Send a message to
    // start".
    this.emitCapabilities();
    // Then kick off the REAL catalog eagerly (fire-and-forget): initializationResult()
    // forces the subprocess to boot right now instead of waiting on the user's
    // first prompt (see discoverCapabilities()). This replaces the frame above
    // with real models/commands within a couple seconds of session creation,
    // whether or not the user ever types anything.
    void this.discoverCapabilities();
    // Push the resumed conversation's on-disk history onto the stream NOW, the
    // way codex/opencode replay theirs from start(resumeId) — the desktop app
    // renders resumed transcripts from this start-time push, not from the
    // (mobile-attach-only) transcriptSnapshot pull. Awaited so the history lands
    // before the manager lets the user prompt. The SDK exposes no transcript API,
    // so it comes straight from Claude Code's own ~/.claude/projects file.
    if (resumeId && this.cwd) await this.replayResumedTranscript(resumeId);
    return "";
  }

  // Read Claude Code's on-disk transcript for the resumed session and push it as
  // synthetic per-prompt turns — the app's primary path for showing prior
  // history (codex/opencode do the equivalent from their start()). Best-effort:
  // a missing/unreadable file (e.g. the conversation was deleted — the SDK
  // resume then also errors "No conversation found") replays nothing rather than
  // failing start(). Guarded against duplicate emission if start() runs twice.
  private replayedResume = false;
  private async replayResumedTranscript(resumeId: string): Promise<void> {
    if (this.replayedResume || !this.cwd) return;
    try {
      const disk = await this.readTranscript(this.cwd, resumeId);
      if (!disk.length) return;
      this.replayedResume = true;
      const replay = createTranscriptReplay(this.sessionId, claudeResumeReplay(this.sessionId, disk));
      if (replay) this.send(replay);
    } catch (err) {
      log.warn("claude resume-replay failed for session %s (%s): %s", this.sessionId, resumeId, err);
    }
  }

  // Never rejects: dispose() races this against a timeout, so an unhandled
  // rejection here would surface as an unhandled promise rejection instead.
  private async consumeLoop(): Promise<void> {
    if (!this.q) return;
    try {
      for await (const chunk of this.q) {
        if (this.disposed) break;
        try { await this.handleChunk(chunk as any); }
        catch (err) { log.error("claude chunk handler threw for %s: %s", (chunk as any)?.type, err); }
      }
    } catch (err) {
      // dispose() closes the query/aborts the controller, which the SDK
      // surfaces as an iterator error — not a real failure, so stay silent.
      if (this.disposed) return;
      log.warn("claude consume loop ended for session %s: %s", this.sessionId, err);
      const tail = this.stderrTail?.() ?? "";
      const message = tail
        ? `claude session ended unexpectedly: ${err instanceof Error ? err.message : String(err)}\nstderr: ${tail.slice(-STDERR_TAIL_MAX_CHARS)}`
        : `claude session ended unexpectedly: ${err instanceof Error ? err.message : String(err)}`;
      this.send(createMessage("agent:error", {
        sessionId: this.sessionId,
        error: mapFailureError(message, this.limitSnapshot()),
      }));
      // The stream died mid-turn: no `result` chunk is coming, so onResult never
      // fires and the app's active turn would spin forever. Close it out here.
      this.endActiveTurnOnFailure(message);
    }
  }

  // Force-close the in-flight turn when the backend dies before its `result`
  // (consume loop error). Mirrors onResult's teardown minus the usage frame the
  // dead stream can't supply. No-op when no turn is active.
  private endActiveTurnOnFailure(message: string): void {
    const turnId = this.activeTurnId;
    if (!turnId) return;
    this.cancelRequested = false;
    this.send(createMessage("agent:turn-end", {
      sessionId: this.sessionId,
      turnId,
      stopReason: "error",
      error: mapFailureError(message, this.limitSnapshot()),
    }));
    this.retractAllPending();
    this.activeTurnId = null;
    this.seenItems.clear();
    this.itemCache.clear();
  }

  // Async so the init path (below) can await model discovery before flushing
  // pendingConfig — the consume loop is sequential, so awaiting here just
  // delays the NEXT chunk, never deadlocks (supportedModels() is a
  // control-channel RPC independent of the message stream).
  private async handleChunk(c: any): Promise<void> {
    switch (c?.type) {
      case "system":
        if (c.subtype === "init") return this.onInit(c);
        if (c.subtype === "commands_changed") return this.onCommandsChanged(c);
        // "status" also carries compacting/compact_result during a manual
        // "/compact" push (probe-verified, see .superpowers/sdd/sdk-probe-report.md,
        // Q1): status{compacting} -> status{compact_result} -> a mid-stream
        // re-init -> compact_boundary. No typed compact API/event exists on the
        // wire protocol.ts side, so the compaction fields aren't forwarded;
        // compact_boundary gets a user-visible marker via the existing
        // "compaction" item kind. onStatus only picks up the permissionMode the
        // CLI re-broadcasts here on a live mode change (shift+tab, escalation).
        if (c.subtype === "status") return this.onStatus(c);
        if (c.subtype === "compact_boundary") return this.onCompactBoundary(c);
        return;
      // No "stream_event" case: those only arrive with includePartialMessages,
      // which v1 doesn't enable (no live token streaming; text lands per
      // assistant message).
      case "rate_limit_event": return this.onRateLimit(c);
      case "assistant": return this.onAssistant(c);
      case "user": return this.onToolResult(c);
      case "result": return this.onResult(c);
      default: return;
    }
  }

  // Only a "rejected" status means the account is actually being refused;
  // "allowed_warning" is a pre-limit heads-up we deliberately do not park on.
  private onRateLimit(c: any): void {
    const info = c?.rate_limit_info;
    if (!info) return;
    this.rateLimited = info.status === "rejected"
      ? (typeof info.resetsAt === "number" ? { resetsAt: info.resetsAt } : {})
      : null;
  }

  private limitSnapshot(): ClaudeRateLimit | undefined {
    if (!this.rateLimited) return undefined;
    const now = Date.now();
    // A window whose reset time has passed says nothing about THIS failure: the
    // CLI announces each rejection on its own event. Keeping it would classify
    // an unrelated error as a limit and hand the handler a wake time already
    // gone, which parks and resumes in the same tick.
    if (this.rateLimited.resetsAt !== undefined && this.rateLimited.resetsAt * 1000 <= now) {
      this.rateLimited = null;
      return undefined;
    }
    return { ...this.rateLimited, now };
  }

  // The CLI re-broadcasts permissionMode on a live mode change (shift+tab, an
  // escalation mid-turn) via a system:status chunk. Without this the mode pill
  // stays pinned to whatever system:init reported and drifts from the real
  // session state until the next reconnect. Only re-emit on an actual change.
  private onStatus(c: any): void {
    if (typeof c.permissionMode === "string" && c.permissionMode !== this.selMode) {
      this.selMode = c.permissionMode;
      this.emitCapabilities();
    }
  }

  private async onInit(c: any): Promise<void> {
    if (c.session_id) {
      // v1 resume policy: if resume returned a different id, resume silently
      // failed/forked; accept the reported (fresh) id and continue. Checked
      // only against the FIRST init: compaction re-emits init mid-stream
      // (probe-verified) on the now-established session, and comparing that
      // later init back to the original resume request would log a spurious
      // mismatch every time.
      if (this.resumeRequested && c.session_id !== this.resumeRequested) {
        log.warn("claude resume mismatch: asked %s, got %s; continuing on fresh session", this.resumeRequested, c.session_id);
      }
      this.resumeRequested = undefined;
      // Capture the on-disk transcript anchor for a FRESH session (no resume).
      // A resumed session keeps its anchor from start() even if the SDK forked
      // to a new id here — the old file is the one holding the pre-resume history.
      if (!this.agentSessionId && typeof c.session_id === "string") this.agentSessionId = c.session_id;
      this.onSessionId?.(c.session_id);
    }
    if (!this.selMode && typeof c.permissionMode === "string") this.selMode = c.permissionMode;
    if (typeof c.model === "string") this.resolvedModel = c.model;
    this.ingestCommands(c.slash_commands);
    this.ingestSkills(c.skills);
    // Awaited (not fire-and-forget): a setConfig('model', ...) arriving before
    // this resolves would otherwise see an empty capModels and be silently
    // dropped (resolveConfigPick -> null). discoverModels emits its own
    // capabilities frame on error paths only; the single authoritative emit
    // for the init sequence happens at the end of this function.
    await this.discoverModels();
    // Reconcile the current model with what the session actually booted with.
    // system:init.model is the resolved wire id; map it back to the catalog
    // alias so currentModelId matches a row (the app looks models up by id).
    // Overrides the eager default guess, but never a user-pinned model.
    if (!this.modelExplicit && typeof c.model === "string") {
      const aliasId = aliasIdForResolved(this.rawModelCatalog, c.model);
      if (aliasId && aliasId !== this.selModel) {
        this.selModel = aliasId;
        // Model changed under us — drop the effort seeded for the eager-default
        // model so seedDefaultEffort re-derives (and re-applies) it for the
        // booted model. Otherwise currentEffortId stays bound to the old model
        // and may not even be in the new model's effort list. A user-pinned
        // effort is preserved.
        if (!this.effortExplicit) this.selEffort = undefined;
      }
    }
    this.seedDefaultEffort();
    this.capsDiscovered = true;
    const queued = this.pendingConfig; this.pendingConfig = [];
    for (const p of queued) this.applyConfig(p.key, p.value);
    this.emitCapabilities();
    // Refreshes after the initial boot and the re-init emitted by compaction.
    // This must not hold up init processing if the control request is slow.
    void this.emitContextUsage();
  }

  private onCommandsChanged(c: any): void {
    // SDKCommandsChangedMessage REPLACES the cached list (supportedCommands()
    // never reflects mid-session changes — see the SDK type doc).
    this.ingestCommands(c.commands);
    this.emitCapabilities();
  }

  private onCompactBoundary(c: any): void {
    const turnId = this.activeTurnId ?? "";
    const meta = c?.compact_metadata ?? {};
    const summary = typeof meta.trigger === "string"
      ? `Context compacted (${meta.trigger}): ${meta.pre_tokens ?? "?"} -> ${meta.post_tokens ?? "?"} tokens`
      : "Context compacted";
    this.emitItem(turnId, `compaction:${c?.uuid ?? this.turnCounter}`, { kind: "compaction", summary });
  }

  private ingestCommands(entries: any): void {
    // init sends slash_commands as string[]; commands_changed sends SlashCommand
    // objects ({name, description, argumentHint}) — keep the richer fields.
    const list = Array.isArray(entries) ? entries : [];
    const cmds = list
      .map((e: any) => (typeof e === "string" ? { name: e } : e))
      .filter((e: any) => e?.name)
      .map((e: any) => ({
        id: `cmd:${e.name}`, name: String(e.name),
        ...(e.description ? { description: String(e.description) } : {}),
        ...(e.argumentHint ? { argHint: String(e.argumentHint) } : {}),
      }));
    cmds.push({ id: "builtin:compact", name: "compact" } as any);
    this.capCommands = cmds;
  }

  private ingestSkills(_skills: any): void {
    // Skills already surface as slash commands in slash_commands; kept as a hook
    // for a future dedicated skills section. No-op for v1.
  }

  // Eager, start()-time discovery: initializationResult() is a control-channel
  // RPC that forces the subprocess to boot and resolves with the full catalog
  // even with nothing pushed to the prompt stream yet (probe-verified against
  // the real binary — resolves in ~1.5-3s, and doesn't disturb the system:init
  // the user's first real prompt still produces). Runs independently of (and
  // usually finishes well before) onInit's own discoverModels() call, which
  // stays as the fallback for whichever prompt arrives first.
  // start() fire-and-forgets this, so a rejection would escape into the void and
  // reach the host's process-level unhandledRejection hook, which tears down every
  // project on the machine (see index.ts) — not just this session. The inner try
  // only covers the RPC; the tail past it (the pendingConfig flush and the
  // capabilities emit) writes to the transport and can throw too.
  private async discoverCapabilities(): Promise<void> {
    try {
      await this.discoverCapabilitiesInner();
    } catch (err) {
      log.warn("claude capability discovery failed for session %s: %s", this.sessionId, err);
    }
  }

  private async discoverCapabilitiesInner(): Promise<void> {
    if (!this.q) return;
    let gotCatalog = false;
    try {
      const init = await this.q.initializationResult();
      if (Array.isArray(init?.models)) {
        this.rawModelCatalog = init.models;
        this.capModels = mapModelInfos(init.models);
        // A successful RPC can still carry an empty models array (or a list that
        // maps to nothing) — treat that like a failure, not a real catalog, so
        // the gate below stays closed and early picks aren't flushed against []
        // and dropped (see the gate comment).
        if (this.capModels.length) {
          this.pickDefaultModelIfUnset();
          this.seedDefaultEffort();
          gotCatalog = true;
        }
      }
      if (Array.isArray(init?.commands)) this.ingestCommands(init.commands);
      // initializationResult() boots the subprocess before any prompt or
      // system:init. Seed the meter from that same eager path; onInit still
      // issues a newer refresh once the stream reports the live session state.
      if (!this.disposed) void this.emitContextUsage();
    } catch { /* best effort; onInit's own discovery covers this once a prompt is sent */ }
    if (this.disposed) return;
    // Only open the config gate once a real catalog arrived. If the RPC failed
    // (empty capModels), flipping capsDiscovered would flush pendingConfig
    // against nothing — resolveConfigPick drops every pick — and onInit's
    // fallback discovery can't recover them (queue already drained). Leaving it
    // false keeps early picks queued for whichever discovery populates first.
    if (!gotCatalog) return;
    this.capsDiscovered = true;
    const queued = this.pendingConfig; this.pendingConfig = [];
    for (const p of queued) this.applyConfig(p.key, p.value);
    this.emitCapabilities();
  }

  // Caller (onInit) emits capabilities once, after this resolves — no emit
  // here, so the init sequence produces exactly one agent:capabilities frame.
  private async discoverModels(): Promise<void> {
    if (!this.q) return;
    try {
      const models = await this.q.supportedModels();
      if (Array.isArray(models)) {
        this.rawModelCatalog = models;
        this.capModels = mapModelInfos(models);
        this.pickDefaultModelIfUnset();
      }
    } catch { /* capability refresh is best-effort */ }
  }

  // Eagerly select the account default (resolved to its concrete model) so the
  // composer's model/effort pills populate before the first prompt — unless the
  // user pinned a model. system:init later reconciles this to the booted model.
  private pickDefaultModelIfUnset(): void {
    if (this.modelExplicit || this.selModel) return;
    // Prefer the account default resolved to its concrete model (Option B), then
    // fall back to the first concrete row, then any row — so currentModelId is
    // never left unset while a catalog exists (the app gates the effort pill and
    // effort picks on having a current model). A degenerate default-only catalog
    // resolves to "default"; init reconciliation refines the guess once the
    // session reports its booted model.
    this.selModel =
      resolveDefaultModelId(this.rawModelCatalog) ??
      this.capModels.find((m) => m.id !== "default")?.id ??
      this.capModels[0]?.id;
  }

  // Seed the effort selector to the current model's default (its 2nd rung) and
  // apply it to the session, so the pill and the actual session effort agree
  // from session create. No-op once the user has picked an effort, or when the
  // current model has no effort levels (the pill is hidden then anyway).
  private seedDefaultEffort(): void {
    if (this.effortExplicit || this.selEffort) return;
    const pick = this.capModels.find((m) => m.id === this.selModel)?.defaultEffort;
    if (!pick) return;
    this.selEffort = pick;
    this.guardPick(this.q?.applyFlagSettings({ effortLevel: pick, ultracode: false }), "effort", pick,
      () => { this.selEffort = undefined; });
  }

  private emitCapabilities(): void {
    this.send(createMessage("agent:capabilities", {
      sessionId: this.sessionId,
      // The init sequence emits an early frame before the model catalog lands
      // (capsDiscovered still false) so the app renders a loading state.
      ready: this.capsDiscovered,
      commands: this.capCommands,
      modes: this.capModes,
      models: this.capModels,
      ...(this.selModel ? { currentModelId: this.selModel } : {}),
      ...(this.selMode ? { currentModeId: this.selMode } : {}),
      ...(this.selEffort ? { currentEffortId: this.selEffort } : {}),
    }));
  }

  setConfig(key: string, value: unknown): void {
    if (typeof value !== "string") return;
    if (!this.capsDiscovered) { this.pendingConfig.push({ key, value }); return; }
    if (this.applyConfig(key, value)) this.emitCapabilities();
  }

  // A selection is written optimistically and pushed to the CLI fire-and-forget,
  // but the control call is fallible: the CLI arbitrates picks it never
  // advertised (permission mode "auto" is gated per-model, and no discovery API
  // reports which models allow it) and answers an unsupported one with an error
  // verdict, which the SDK surfaces as a rejection. Unguarded, that reaches the
  // host's process-level unhandledRejection hook and takes down every project on
  // the machine. Roll the optimistic write back and re-emit so the app's pills
  // report the state the session is actually in.
  private guardPick(call: Promise<unknown> | undefined, axis: string, id: string, revert: () => void): void {
    const seq = (this.pickSeq.get(axis) ?? 0) + 1;
    this.pickSeq.set(axis, seq);
    // The trailing catch keeps the handler total: emitCapabilities() writes to the
    // transport, and a throw there would reject this .catch()'s own promise —
    // landing right back on the hook this guard exists to keep clear.
    void call?.catch((err) => {
      if (this.disposed) return;
      log.warn("claude %s pick \"%s\" rejected for session %s: %s", axis, id, this.sessionId, err);
      // A newer pick on this axis already superseded ours and the CLI took it;
      // rolling back now would clobber a selection that actually applied.
      if (this.pickSeq.get(axis) !== seq) return;
      revert();
      this.emitCapabilities();
    }).catch(() => {});
  }

  private applyConfig(key: string, value: string): boolean {
    const pick = resolveConfigPick(key, value, {
      models: this.capModels, modes: this.capModes,
      currentModelId: this.selModel, currentEffortId: this.selEffort,
    });
    if (!pick) return false;
    if (pick.key === "model") {
      const prevModel = this.selModel, prevResolved = this.resolvedModel, prevExplicit = this.modelExplicit;
      this.selModel = pick.id;
      const raw = this.rawModelCatalog.find((m) => String(m?.value ?? "") === pick.id);
      this.resolvedModel = typeof raw?.resolvedModel === "string" ? raw.resolvedModel : pick.id;
      this.modelExplicit = true;
      this.guardPick(this.q?.setModel(pick.id), "model", pick.id, () => {
        this.selModel = prevModel; this.resolvedModel = prevResolved; this.modelExplicit = prevExplicit;
      });
      // Clearing a carried-over effort also lifts ultracode — it's a sticky
      // session flag, so a bare effortLevel:null wouldn't turn it off.
      if (pick.clearEffort) {
        const prevEffort = this.selEffort;
        this.selEffort = undefined;
        this.guardPick(this.q?.applyFlagSettings({ effortLevel: null, ultracode: false }), "effort", "none",
          () => { this.selEffort = prevEffort; });
      }
    } else if (pick.key === "mode") {
      const prevMode = this.selMode;
      this.selMode = pick.id;
      this.guardPick(this.q?.setPermissionMode(pick.id), "mode", pick.id, () => { this.selMode = prevMode; });
    } else if (pick.key === "effort") {
      const prevEffort = this.selEffort, prevExplicit = this.effortExplicit;
      this.selEffort = pick.id; this.effortExplicit = true;
      // ultracode isn't an effortLevel value — set its own flag; any concrete
      // level must also lift a previously-set ultracode (it's sticky).
      this.guardPick(
        this.q?.applyFlagSettings(pick.id === "ultracode" ? { ultracode: true } : { effortLevel: pick.id, ultracode: false }),
        "effort", pick.id,
        () => { this.selEffort = prevEffort; this.effortExplicit = prevExplicit; },
      );
    }
    return true;
  }

  async prompt(text: string, commandId?: string): Promise<void> {
    if (!this.controller) throw new Error("claude session not started");
    if (commandId === "builtin:compact") return this.compact();
    this.activeTurnId = `turn-${this.turnCounter++}`;
    this.cancelRequested = false;
    this.send(createMessage("agent:turn-start", { sessionId: this.sessionId, turnId: this.activeTurnId }));
    // Slash command → send the literal "/name args"; the CLI parses it.
    const body = commandId?.startsWith("cmd:") ? `/${commandId.slice(4)}${text.trim() ? " " + text : ""}` : text;
    // The Claude SDK stream never echoes the user turn back (unlike codex), so
    // emit the user message ourselves — otherwise it renders only on resume via
    // claudeResumeReplay, never live. Shape mirrors that replay path.
    this.emitItem(this.activeTurnId, `user:${this.activeTurnId}`, { kind: "message", role: "user", text: body });
    this.pushHistory({ type: "user", message: { role: "user", content: body } });
    this.controller.push({ type: "user", message: { role: "user", content: body }, parent_tool_use_id: null } as any);
  }

  // Shape matches claudeResumeReplay's expected entries so getTranscriptSnapshot
  // can hand `history` straight through. Capped at HISTORY_MAX_ENTRIES (drop
  // oldest) — see field doc on `history`.
  private pushHistory(entry: any): void {
    // Stamp with the wall-clock time the turn happened so a later in-memory
    // replay (getTranscriptSnapshot) carries a real per-message time, matching
    // the ISO `timestamp` Claude Code writes to disk (see claudeResumeReplay).
    if (entry && entry.timestamp === undefined) entry.timestamp = new Date().toISOString();
    this.history.push(entry);
    if (this.history.length > HISTORY_MAX_ENTRIES) this.history.splice(0, this.history.length - HISTORY_MAX_ENTRIES);
  }

  private onAssistant(c: any): void {
    const turnId = this.activeTurnId ?? "";
    const { text, thinking, toolUses } = mapAssistantContent(c?.message?.content ?? []);
    if (thinking) this.emitItem(turnId, `reason:${c.uuid}`, { kind: "reasoning", role: "assistant", text: thinking });
    if (text) {
      this.emitItem(turnId, `msg:${c.uuid}`, { kind: "message", role: "assistant", text });
      // Same text as the emitted item — see `history` field doc.
      this.pushHistory({ type: "assistant", message: {
        role: "assistant", content: [{ type: "text", text }],
        ...(c?.message?.usage ? { usage: c.message.usage } : {}),
        ...(c?.message?.id ? { id: c.message.id } : {}),
      }, uuid: c?.uuid });
    }
    for (const t of toolUses) {
      this.emitItem(turnId, `tool:${t.id}`, {
        kind: "tool_call", status: "running", toolKind: mapToolKind(t.name), title: t.name, rawInput: t.input,
      });
    }
  }

  // Attach tool_result (arrives as a `user` chunk) → mark the tool item completed.
  // Post-compaction the SDK also emits synthetic `user` chunks whose content is
  // plain text/summary (a string, not tool_result blocks) — the Array.isArray
  // guard below already turns that into a no-op iteration, so those are
  // silently ignored rather than crashing or emitting garbage items.
  private onToolResult(c: any): void {
    const turnId = this.activeTurnId ?? "";
    for (const b of Array.isArray(c?.message?.content) ? c.message.content : []) {
      if (b?.type !== "tool_result") continue;
      const itemId = `tool:${b.tool_use_id}`;
      const data = typeof b.content === "string" ? b.content : JSON.stringify(b.content);
      this.emitItem(turnId, itemId, {
        kind: "tool_call", status: b.is_error ? "error" : "completed",
        content: [{ type: "terminal", data }],
      });
    }
  }

  // Missing support and teardown races simply defer meter initialization to
  // the normal result-frame path.
  private async emitContextUsage(): Promise<void> {
    const generation = ++this.contextUsageGeneration;
    const fn = this.q?.getContextUsage?.bind(this.q);
    if (!fn) return;
    try {
      const usage = await fn();
      if (this.disposed || generation !== this.contextUsageGeneration) return;
      const totalTokens = usage?.totalTokens;
      const maxTokens = usage?.maxTokens;
      if (typeof totalTokens !== "number" || typeof maxTokens !== "number" || maxTokens <= 0) return;
      this.send(createMessage("agent:usage", {
        sessionId: this.sessionId,
        total: { ...this.usageTotal },
        last: { totalTokens },
        contextWindow: maxTokens,
      }));
    } catch {
      // Best effort; see method doc.
    }
  }

  private onResult(c: any): void {
    const turnId = this.activeTurnId ?? "";
    if (!turnId) return;
    const stopReason = this.cancelRequested ? "cancelled" : c?.is_error ? "error" : "end_turn";
    this.cancelRequested = false;
    const limited = stopReason === "error" ? this.limitSnapshot() : undefined;
    // A turn that ran to completion proves the window is over, whether or not
    // the CLI bothered to emit a clearing rate_limit_event.
    if (stopReason === "end_turn") this.rateLimited = null;
    if (c?.usage) {
      const last = mapUsage(c.usage);
      addUsage(this.usageTotal, last);
      const modelUsage = this.resolvedModel ? c?.modelUsage?.[this.resolvedModel] : undefined;
      const contextWindow = modelUsage?.contextWindow;
      this.send(createMessage("agent:usage", {
        sessionId: this.sessionId, turnId,
        // total_cost_usd is the SDK's own cumulative-for-the-query figure, which
        // with one persistent query per session IS the session total.
        total: { ...this.usageTotal, ...(typeof c?.total_cost_usd === "number" ? { costUsd: c.total_cost_usd } : {}) },
        last,
        ...(typeof contextWindow === "number" && contextWindow > 0 ? { contextWindow } : {}),
      }));
    }
    this.send(createMessage("agent:turn-end", {
      sessionId: this.sessionId, turnId, stopReason,
      ...(stopReason === "error" ? { error: mapResultError(c, limited) } : {}),
    }));
    this.retractAllPending();
    this.activeTurnId = null;
    this.seenItems.clear();
    this.itemCache.clear();
    // Do NOT end the prompt stream here: one persistent query serves the whole
    // session, so stdin stays open across turns; end() happens only in dispose().
  }

  private emitItem(turnId: string, itemId: string, fields: Record<string, unknown>): void {
    const first = !this.seenItems.has(itemId);
    this.seenItems.add(itemId);
    const item = { ...this.itemCache.get(itemId), ...fields, itemId };
    this.itemCache.set(itemId, item);
    this.send(createMessage(first ? "agent:item-added" : "agent:item-updated", {
      sessionId: this.sessionId, turnId, itemId, item: item as any,
    }));
  }

  async cancel(turnId?: string): Promise<boolean> {
    if (!this.activeTurnId) return false;
    // A turnId naming anything but the live turn comes from a client whose
    // turn-end was lost: interrupting would stop a turn the user never asked to
    // stop. Refuse, so the manager answers that phantom with its own turn-end
    // (returning true would suppress it and strand the turn open forever).
    // Absent turnId = cancel whatever is live.
    if (turnId && turnId !== this.activeTurnId) return false;
    this.cancelRequested = true;
    await this.q?.interrupt();
    return true;
  }

  async compact(): Promise<void> {
    if (!this.controller) return;
    // Query exposes no typed compact API — pushing the literal "/compact" text
    // over the streaming-input channel is verified (SDK 0.3.201, real binary)
    // to engage the actual compaction subsystem rather than being read as a
    // literal chat message: status{compacting} -> status{compact_result} ->
    // a mid-stream re-init -> compact_boundary on success (see
    // .superpowers/sdd/sdk-probe-report.md, Q1).
    this.controller.push({ type: "user", message: { role: "user", content: "/compact" }, parent_tool_use_id: null } as any);
  }
  // The Claude Agent SDK exposes no revert/rollback API (unlike codex's
  // thread/rollback), so this driver has nothing to call — documented no-op.
  async revert(_t: { turnId?: string; itemId?: string; messageId?: string }): Promise<void> {}

  async getTranscriptSnapshot(): Promise<AbMessage[]> {
    // The SDK restores model context on resume but exposes no transcript-read
    // API and re-emits no history on the stream (probe-verified against SDK
    // 0.3.201 — see .superpowers/sdd/sdk-probe-report.md, Q2). So read Claude
    // Code's own on-disk transcript: it survives a cold resume (fresh driver
    // after a bridge restart) and a late second client attaching — the
    // in-memory `history` only holds turns THIS driver instance produced.
    if (this.cwd && this.agentSessionId) {
      try {
        const disk = await this.readTranscript(this.cwd, this.agentSessionId);
        if (disk.length) return claudeResumeReplay(this.sessionId, disk);
      } catch (err) {
        log.warn("claude transcript read failed for session %s (%s); falling back to in-memory: %s",
          this.sessionId, this.agentSessionId, err);
      }
    }
    // Fallback: id/cwd not known yet, or nothing on disk — replay whatever this
    // instance has seen live.
    if (this.history.length === 0) return [];
    return claudeResumeReplay(this.sessionId, this.history);
  }

  private makeCanUseTool(): CanUseTool {
    return (toolName, input, options): Promise<Awaited<ReturnType<CanUseTool>>> => {
      // AskUserQuestion / ExitPlanMode are user-input tools, not local exec —
      // intercept and surface as agent:question / plan approval.
      if (toolName === "AskUserQuestion") return this.handleAskUserQuestion(input, options);
      return new Promise((resolve) => {
        const permissionId = `perm-${this.approvalCounter++}`;
        // "Always" persists via the SDK's own suggestions (returned as
        // updatedPermissions per the CanUseTool doc) — without suggestions
        // there is nothing to persist, so the option isn't offered.
        const suggestions = Array.isArray(options?.suggestions) ? options.suggestions : [];
        this.pendingApprovals.set(permissionId, (optionId) => {
          this.pendingApprovals.delete(permissionId);
          if (optionId === "reject" || optionId == null) {
            resolve({ behavior: "deny", message: "denied by user", ...(optionId == null ? { interrupt: true } : {}) });
          } else {
            resolve({
              behavior: "allow", updatedInput: input,
              ...(optionId === "always" && suggestions.length ? { updatedPermissions: suggestions } : {}),
            });
          }
        });
        this.send(createMessage("agent:permission-request", {
          sessionId: this.sessionId, permissionId, itemId: `tool:${options?.toolUseID ?? ""}`,
          title: options?.title ?? `Allow ${toolName}?`,
          ...(options?.description ? { reason: String(options.description) } : {}),
          options: [
            { optionId: "once", label: "Allow once", kind: "allow_once" as const },
            ...(suggestions.length ? [{ optionId: "always", label: "Always allow", kind: "allow_always" as const }] : []),
            { optionId: "reject", label: "Deny", kind: "reject" as const },
          ],
        }));
      });
    };
  }

  private handleAskUserQuestion(input: any, _options: any): Promise<Awaited<ReturnType<CanUseTool>>> {
    // v1 surfaces only the first question (the tool allows 1-4). The SDK's
    // documented feedback channel is AskUserQuestionInput.answers — a map keyed
    // by the question TEXT — echoed back via updatedInput.
    const q = (Array.isArray(input?.questions) ? input.questions[0] : undefined) ?? {};
    const opts: any[] = Array.isArray(q.options) ? q.options : [];
    return new Promise((resolve) => {
      const questionId = `q-${this.questionCounter++}`;
      if (opts.length) this.questionOptions.set(questionId, opts.map((o) => String(o?.label ?? "")));
      this.pendingQuestions.set(questionId, (value) => {
        this.pendingQuestions.delete(questionId);
        const labels = this.questionOptions.get(questionId);
        this.questionOptions.delete(questionId);
        if (value == null) { resolve({ behavior: "deny", message: "question dismissed", interrupt: true }); return; }
        const i = Number(value);
        const answer = labels && Number.isInteger(i) && i >= 0 && i < labels.length ? labels[i] : value;
        resolve({ behavior: "allow", updatedInput: { ...input, answers: { [String(q.question ?? "")]: answer } } });
      });
      this.send(createMessage("agent:question", {
        sessionId: this.sessionId, questionId,
        kind: opts.length ? "single_select" : "text",
        prompt: String(q.question ?? q.header ?? "?"),
        ...(opts.length ? { options: opts.map((o, idx) => ({ id: String(idx), label: String(o?.label ?? ""), description: o?.description })) } : {}),
      }));
    });
  }

  resolvePermission(permissionId: string, optionId: string): void {
    this.pendingApprovals.get(permissionId)?.(optionId);
  }

  resolveQuestion(questionId: string, answer: string | string[]): void {
    const v = Array.isArray(answer) ? answer[0] ?? "" : answer;
    this.pendingQuestions.get(questionId)?.(v);
  }

  private retractAllPending(): void {
    // Snapshot then clear before invoking callbacks: each cb() synchronously
    // deletes its own entry (see pendingApprovals.set), so iterating the live
    // map while it mutates is needlessly fragile.
    const approvals = [...this.pendingApprovals];
    this.pendingApprovals.clear();
    for (const [permissionId, cb] of approvals) {
      this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, permissionId }));
      cb(null);
    }
    const questions = [...this.pendingQuestions];
    this.pendingQuestions.clear();
    this.questionOptions.clear();
    for (const [questionId, cb] of questions) {
      this.send(createMessage("agent:request-retracted", { sessionId: this.sessionId, questionId }));
      cb(null);
    }
  }

  // Async: the SDK's close() only schedules SIGTERM/SIGKILL on unref'd
  // 2s/5s timers and returns immediately, so a synchronous dispose let a
  // stop->restart race two claude processes. Wait out the consume loop
  // (which ends once the query's iterator completes); if it's still running
  // after the grace period, escalate to aborting the spawn's AbortController
  // as a hard kill and wait once more before giving up.
  async dispose(): Promise<void> {
    this.disposed = true;
    this.retractAllPending();
    this.controller?.end("dispose");
    try { this.q?.close(); } catch { /* best effort */ }
    const timedOut = Symbol("dispose-timeout");
    const outcome = await Promise.race([
      this.consumeDone.then(() => "done" as const),
      Bun.sleep(DISPOSE_GRACE_MS).then(() => timedOut),
    ]);
    if (outcome !== timedOut) return;
    this.abort.abort();
    await Promise.race([this.consumeDone, Bun.sleep(DISPOSE_ABORT_GRACE_MS)]);
  }
}
