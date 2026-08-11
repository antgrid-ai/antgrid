import type { CanUseTool } from "@anthropic-ai/claude-agent-sdk";
import { type AbMessage } from "../../protocol";
import type { ClaudeQueryLike, PromptStreamController } from "./spawn";
import type { ConfigPick } from "../../structured/set-config";
import {
  ChatSession,
  type ChatSessionProfile,
  type SelectionSnapshot,
} from "../../structured/chat-session";
import {
  mapAssistantContent, mapToolKind, mapUsage, addUsage, mapResultError, mapFailureError,
  type ClaudeUsageTotals, type ClaudeRateLimit,
} from "./mapping";
import { claudeResumeReplay } from "./resume-replay";
import { readClaudeTranscript } from "./transcript-read";
import { logger } from "../../logger";
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

// How long a rejection that named no reset time stays attributable to the
// failure that follows it. Mirrors the handler's LIMIT_FALLBACK_MS — the same
// "we were not told how long, assume this" answer on the other side of the same
// event. Kept local so the driver layer does not import the supervisor.
const UNDATED_LIMIT_TTL_MS = 30 * 60_000;

type CatalogModel = { id: string; name: string; efforts?: string[]; defaultEffort?: string };

// ModelInfo = { value, displayName, resolvedModel, supportsEffort, supportedEffortLevels, ... }
// — `value` is the id setModel takes; shared by initializationResult().models
// and supportedModels() (identical shape, see spawn.ts's ClaudeQueryLike).
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
// Bound on `recentlySettled` (see field doc) — a long session settling many
// background tasks can't grow this map without limit.
const RECENTLY_SETTLED_CAP = 20;
// How long dispose() waits on the background-task reap before giving up, so a
// wedged control channel can't stall teardown.
const BACKGROUND_REAP_GRACE_MS = 1_000;

// The SDK's fixed PermissionMode enum (setPermissionMode), NOT a discovered
// catalog — supportedAgents() lists subagent definitions, which are not modes.
// bypassPermissions is deliberately not offered remotely (it skips every
// permission check — unsafe over the wire). Seeded at construction so the
// session's first, pre-discovery capabilities frame already carries them.
const PERMISSION_MODES = [
  { id: "default", name: "Default", description: "Ask before each tool use" },
  { id: "auto", name: "Auto", description: "Model classifier approves or denies tool prompts" },
  { id: "acceptEdits", name: "Accept edits", description: "Auto-approve file edits" },
  { id: "plan", name: "Plan", description: "Read-only planning mode" },
];

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

export class ClaudeDriver extends ChatSession {
  // The SDK never echoes the user turn and reports tool completion as a partial
  // update over the tool_use it already sent, so the session mints the turn and
  // merges item frames. Its transcript is a settled on-disk file, readable at
  // any point in a turn.
  protected readonly profile: ChatSessionProfile = {
    turnSource: "session",
    mergeItems: true,
    snapshotDuringTurn: true,
    interruptScope: "turn",
  };

  private readonly spawnFn: ClaudeDriverOpts["spawn"];

  private q: ClaudeQueryLike | null = null;
  private controller: PromptStreamController | null = null;
  private abort = new AbortController();
  // Completion promise of the consume loop launched by start(); dispose()
  // awaits this (with a timeout) instead of returning before the SDK's
  // subprocess has actually been asked to exit.
  private consumeDone: Promise<void> = Promise.resolve();

  // The CLI announces a usage limit on its own `rate_limit_event` channel,
  // BEFORE the turn dies, and the failing result chunk names no cause. Holding
  // the last rejection lets a failure be classified as a limit (which the
  // handler lifecycle parks on) instead of a generic error.
  // `at` is when WE saw it, not the CLI's clock: it is the only expiry a
  // rejection carrying no resetsAt has (see limitSnapshot).
  private rateLimited: { resetsAt?: number; at: number } | null = null;
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

  // ── Background tasks ─────────────────────────────────────────────────────
  // The SDK reports backgrounded work (run_in_background Bash, subagents,
  // monitors) via system task_* messages: task_started mints a task_id,
  // task_updated patches status, task_notification settles it. Session-scoped
  // (tasks outlive turns); the full list is re-emitted on every change
  // (latest-wins, like agent:capabilities).
  private backgroundTasks = new Map<string, {
    taskId: string;
    kind: string;
    title: string;
    // Advertised as-is: the SDK's non-terminal states (pending, running,
    // paused) are the app's to render, and a paused task reported as running is
    // a lie the wire field exists to avoid.
    status: string;
    itemId?: string;
    turnId: string;
    startedAt: number;
    // Last-known fields of the correlated tool item. seenItems/itemCache clear
    // at turn end but the settle can land turns later — re-emitting a COMPLETE
    // item (the app replaces items wholesale) needs this snapshot.
    itemSnapshot?: Record<string, unknown>;
  }>();

  // task_updated is a raw state-patch stream that can flip a task to a terminal
  // status before the separately-computed task_notification (carrying the
  // summary) arrives — settling on the patch would otherwise drop that summary
  // on the floor forever. Bounded (RECENTLY_SETTLED_CAP), oldest evicted first.
  private recentlySettled = new Map<string, { itemId?: string; turnId: string; itemSnapshot?: Record<string, unknown> }>();

  // Last raw SDK model list, kept so resolvedModel-based mapping (default row →
  // concrete alias, system:init.model → alias) can run outside mapModelInfos,
  // which drops resolvedModel from the emitted catalog.
  private rawModelCatalog: any[] = [];
  private resolvedModel?: string;

  private readonly onSessionId?: (agentSessionId: string) => void;
  private readonly stderrTail?: () => string;
  private readonly cwd?: string;
  private readonly readTranscript: (cwd: string, agentSessionId: string) => Promise<any[]> | any[];
  private resumeRequested?: string;
  // The Claude session id whose on-disk transcript backfills a cold resume.
  // Pinned to the resumed id (its file holds the pre-resume history); for a
  // fresh session it captures the SDK's new id at init. See transcriptSnapshot.
  private agentSessionId?: string;

  constructor(opts: ClaudeDriverOpts) {
    super({ sessionId: opts.sessionId, sendMessage: opts.sendMessage });
    this.spawnFn = opts.spawn;
    this.selModel = opts.model;
    this.modelExplicit = !!opts.model;
    this.capModes = PERMISSION_MODES.map((m) => ({ ...m }));
    this.onSessionId = opts.onSessionId;
    this.stderrTail = opts.stderrTail;
    this.cwd = opts.cwd;
    this.readTranscript = opts.readTranscript ?? readClaudeTranscript;
  }

  protected async startBackend(resumeId?: string): Promise<string> {
    this.resumeRequested = resumeId;
    // Anchor on-disk transcript backfill to the resumed id up front (its file
    // holds the pre-resume conversation), before init reports anything.
    this.agentSessionId = resumeId;
    const spawned = this.spawnFn({ canUseTool: this.makeCanUseTool(), abort: this.abort, resume: resumeId });
    this.q = spawned.query;
    this.controller = spawned.controller;
    // Stored (not fire-and-forget) so dispose() can await the loop actually
    // draining/erroring out instead of returning before the SDK subprocess has
    // been asked to exit — see disposeBackend().
    this.consumeDone = this.consumeLoop();
    // Kick off the REAL catalog eagerly (fire-and-forget): initializationResult()
    // forces the subprocess to boot right now instead of waiting on the user's
    // first prompt (see discoverCapabilities()). This replaces the session's own
    // early not-ready frame with real models/commands within a couple seconds of
    // session creation, whether or not the user ever types anything.
    void this.discoverCapabilities();
    // Push the resumed conversation's on-disk history onto the stream NOW, the
    // way codex/opencode replay theirs from start(resumeId) — the desktop app
    // renders resumed transcripts from this start-time push, not from the
    // (mobile-attach-only) transcriptSnapshot pull. Awaited so the history lands
    // before the manager lets the user prompt. The SDK exposes no transcript API,
    // so it comes straight from Claude Code's own ~/.claude/projects file.
    if (resumeId && this.cwd) await this.replayResumedTranscript(resumeId);
    // Do NOT await system:init: the Claude SDK boots the subprocess (and emits
    // init) only after the first prompt-stream message, which prompt() pushes —
    // and the manager only calls prompt() after start() resolves. Awaiting init
    // here would deadlock. The real session id is captured in onInit and
    // surfaced via onSessionId; the empty return makes the manager's
    // `if (agentId)` guard skip persistence until the real id arrives.
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
      this.emitTranscriptReplay(claudeResumeReplay(this.sessionId, disk));
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
      this.emitError(mapFailureError(message, this.limitSnapshot()));
      // The stream died mid-turn: no `result` chunk is coming, so onResult never
      // fires and the app's active turn would spin forever. Close it out here —
      // mirrors onResult's teardown minus the usage frame the dead stream can't
      // supply.
      if (this.activeTurnId) {
        this.closeTurn({ stopReason: "error", error: mapFailureError(message, this.limitSnapshot()) });
      }
      this.clearBackgroundTasks();
    }
  }

  // Async so the init path (below) can await model discovery before flushing
  // queued config picks — the consume loop is sequential, so awaiting here just
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
        if (c.subtype === "task_started") return this.onTaskStarted(c);
        if (c.subtype === "task_updated") return this.onTaskUpdated(c);
        if (c.subtype === "task_notification") return this.onTaskNotification(c);
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
      ? { ...(typeof info.resetsAt === "number" ? { resetsAt: info.resetsAt } : {}), at: Date.now() }
      : null;
  }

  private limitSnapshot(): ClaudeRateLimit | undefined {
    if (!this.rateLimited) return undefined;
    const now = Date.now();
    // A window whose reset time has passed says nothing about THIS failure: the
    // CLI announces each rejection on its own event. Keeping it would classify
    // an unrelated error as a limit and hand the handler a wake time already
    // gone, which parks and resumes in the same tick.
    //
    // A rejection with NO reset time needs the same expiry or it never gets one:
    // the only other reset is a turn that ends cleanly, which a session stuck
    // failing never reaches — so every later failure, including a dead backend,
    // would report as a retryable rate limit forever. Assume the same window the
    // handler assumes for an undated limit (keep in step with LIMIT_FALLBACK_MS).
    const expired = this.rateLimited.resetsAt !== undefined
      ? this.rateLimited.resetsAt * 1000 <= now
      : now - this.rateLimited.at >= UNDATED_LIMIT_TTL_MS;
    if (expired) {
      this.rateLimited = null;
      return undefined;
    }
    const { resetsAt } = this.rateLimited;
    return resetsAt !== undefined ? { resetsAt, now } : { now };
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
    // dropped (resolveConfigPick -> null). discoverModels emits no capabilities
    // frame of its own; the single authoritative emit for the init sequence
    // happens at the end of this function.
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
    this.capabilitiesReady();
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
    this.emitItem(`compaction:${c?.uuid ?? this.turnCounter}`, { kind: "compaction", summary }, { turnId });
  }

  private publishBackgroundTasks(): void {
    this.emitBackgroundTasks([...this.backgroundTasks.values()].map((t) => ({
      taskId: t.taskId, kind: t.kind, title: t.title, status: t.status,
      ...(t.itemId ? { itemId: t.itemId } : {}),
      startedAt: t.startedAt,
    })));
  }

  private taskByItemId(itemId: string) {
    for (const t of this.backgroundTasks.values()) if (t.itemId === itemId) return t;
    return undefined;
  }

  private onTaskStarted(c: any): void {
    if (!c?.task_id || c.skip_transcript) return;
    const itemId = c.tool_use_id ? `tool:${c.tool_use_id}` : undefined;
    const task = {
      taskId: String(c.task_id),
      kind: String(c.task_type ?? (c.subagent_type ? "subagent" : "shell")),
      title: String(c.description ?? c.task_id),
      status: "running",
      itemId,
      turnId: this.activeTurnId ?? "",
      startedAt: Date.now(),
      itemSnapshot: itemId ? this.cachedItem(itemId) : undefined,
    };
    this.backgroundTasks.set(task.taskId, task);
    if (itemId) {
      // The stub tool_result ("running in the background") may already have
      // marked the item completed (onToolResult can't tell a stub from a real
      // result when it arrives first) — re-assert running. The item↔task link
      // travels on the advertised list's itemId, not on the item.
      // `kind` is restated rather than left to the merge: a resumed session (or
      // any task_started landing past its turn's cache clear) has nothing to
      // merge over, and an item frame without one fails AgentItemSchema.
      this.emitItem(itemId, { kind: "tool_call", status: "running" }, { turnId: task.turnId });
      task.itemSnapshot = this.cachedItem(itemId);
    }
    this.publishBackgroundTasks();
  }

  private onTaskUpdated(c: any): void {
    const task = this.backgroundTasks.get(String(c?.task_id ?? ""));
    if (!task) return;
    const status = c?.patch?.status;
    // The patch beat task_notification to the terminal status: settle now, but
    // keep the item's identity in recentlySettled so the summary the notification
    // carries can still be attached when it lands (see recentlySettled doc).
    if (status === "completed" || status === "failed") {
      this.settleTask(task, status === "completed" ? "completed" : "error", undefined, { recoverable: true });
      return;
    }
    // A kill is a stop, not a failure — it is what our own stopTask does. The
    // CLI emits this patch and then a task_notification for the same kill
    // (which reports it as "stopped", never "killed"), so the summary rides in
    // on the notification: settle recoverable, or every stop loses its summary.
    if (status === "killed") {
      this.settleTask(task, "cancelled", undefined, { recoverable: true });
      return;
    }
    let changed = false;
    if (typeof status === "string" && status !== task.status) {
      task.status = status;
      changed = true;
    }
    if (typeof c?.patch?.description === "string") {
      task.title = c.patch.description;
      changed = true;
    }
    if (changed) this.publishBackgroundTasks();
  }

  // The notification's own verdict, or null when it carries none.
  private notificationStatus(c: any): string | null {
    if (c?.status === "completed") return "completed";
    if (c?.status === "stopped") return "cancelled";
    return typeof c?.status === "string" ? "error" : null;
  }

  private onTaskNotification(c: any): void {
    const taskId = String(c?.task_id ?? "");
    const task = this.backgroundTasks.get(taskId);
    if (!task) return this.recoverLateSummary(taskId, c);
    this.settleTask(task, this.notificationStatus(c) ?? "error",
      typeof c?.summary === "string" ? c.summary : undefined);
  }

  // Remove the task and settle its transcript item. The settle can land turns
  // after the item's own turn (seenItems/itemCache cleared), so a COMPLETE
  // item is re-emitted from the snapshot under the ORIGINAL turnId.
  private settleTask(task: { taskId: string; itemId?: string; turnId: string; title: string; itemSnapshot?: Record<string, unknown> }, status: string, summary: string | undefined, opts?: { recoverable?: boolean }): void {
    this.backgroundTasks.delete(task.taskId);
    if (task.itemId) {
      this.emitItem(task.itemId, this.settledItemFields(task.itemId, task.itemSnapshot, task.title, status, summary), { turnId: task.turnId });
      if (opts?.recoverable) {
        this.recentlySettled.set(task.taskId, { itemId: task.itemId, turnId: task.turnId, itemSnapshot: this.cachedItem(task.itemId) });
        if (this.recentlySettled.size > RECENTLY_SETTLED_CAP) {
          const oldest = this.recentlySettled.keys().next().value;
          if (oldest !== undefined) this.recentlySettled.delete(oldest);
        }
      }
    }
    this.publishBackgroundTasks();
  }

  // A task_notification for a task no longer in backgroundTasks (settled early
  // by task_updated) recovers its summary from recentlySettled instead of being
  // dropped — one-shot, and deliberately does NOT call emitBackgroundTasks():
  // the task is not, and must not become, part of the live advertised list again.
  private recoverLateSummary(taskId: string, c: any): void {
    const stashed = this.recentlySettled.get(taskId);
    if (!stashed || typeof c?.summary !== "string") return;
    this.recentlySettled.delete(taskId);
    if (!stashed.itemId) return;
    // The notification outranks the patch that settled early: a task the patch
    // reported completed can still notify as failed, and that is the verdict.
    const priorStatus = (stashed.itemSnapshot as any)?.status;
    const status = this.notificationStatus(c)
      ?? (typeof priorStatus === "string" ? priorStatus : "completed");
    this.emitItem(stashed.itemId,
      this.settledItemFields(stashed.itemId, stashed.itemSnapshot, "", status, c.summary),
      { turnId: stashed.turnId });
  }

  // Shared by settleTask and recoverLateSummary: layers status + an appended
  // summary onto whatever terminal content the item already has.
  private settledItemFields(itemId: string, itemSnapshot: Record<string, unknown> | undefined, fallbackTitle: string, status: string, summary: string | undefined): Record<string, unknown> {
    const snapshot = this.cachedItem(itemId) ?? itemSnapshot
      ?? { kind: "tool_call", toolKind: "shell", title: fallbackTitle };
    if (!summary) return { ...snapshot, status };
    // The summary appends to the item's terminal block IN PLACE: a settle must
    // not be able to drop content it doesn't own (a diff, a text block) just
    // because today's background tasks only ever produce terminal output.
    const prior: any[] = Array.isArray((snapshot as any).content) ? (snapshot as any).content : [];
    const at = prior.findIndex((b: any) => b?.type === "terminal");
    const priorTerm: string = at === -1 ? "" : prior[at]?.data ?? "";
    const merged = { type: "terminal", data: priorTerm ? `${priorTerm}\n${summary}` : summary };
    return {
      ...snapshot,
      status,
      content: at === -1 ? [...prior, merged] : prior.map((b, i) => (i === at ? merged : b)),
    };
  }

  // Backend died: its tasks are gone (or orphaned and unmanageable) — drop
  // them from the advertised list rather than showing zombies. A dead backend
  // also can't deliver a late notification, so nothing is left to recover.
  private clearBackgroundTasks(): void {
    this.recentlySettled.clear();
    if (this.backgroundTasks.size === 0) return;
    this.backgroundTasks.clear();
    this.publishBackgroundTasks();
  }

  async stopTask(taskId: string): Promise<void> {
    // No optimistic local removal — the SDK's task_notification
    // (status "stopped") is the settle signal and re-emits the list.
    await this.q?.stopTask(taskId);
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
  // only covers the RPC; the tail past it (the queued-pick flush and the
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
    // (empty capModels), flipping it would flush the queued picks against
    // nothing — resolveConfigPick drops every pick — and onInit's fallback
    // discovery can't recover them (queue already drained). Leaving it closed
    // keeps early picks queued for whichever discovery populates first.
    if (!gotCatalog) return;
    this.capabilitiesReady();
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

  protected applySelection(pick: ConfigPick, prev: SelectionSnapshot): void {
    // The only backend whose apply is fallible: the CLI arbitrates picks it
    // never advertised and answers an unsupported one with a rejection, so each
    // call is guarded and rolls back only the axis it owns.
    if (pick.key === "model") {
      const prevResolved = this.resolvedModel;
      const raw = this.rawModelCatalog.find((m) => String(m?.value ?? "") === pick.id);
      this.resolvedModel = typeof raw?.resolvedModel === "string" ? raw.resolvedModel : pick.id;
      this.guardPick(this.q?.setModel(pick.id), "model", pick.id, () => {
        this.selModel = prev.model; this.resolvedModel = prevResolved; this.modelExplicit = prev.modelExplicit;
      });
      // Clearing a carried-over effort also lifts ultracode — it's a sticky
      // session flag, so a bare effortLevel:null wouldn't turn it off.
      if (pick.clearEffort) {
        this.guardPick(this.q?.applyFlagSettings({ effortLevel: null, ultracode: false }), "effort", "none",
          () => { this.selEffort = prev.effort; });
      }
    } else if (pick.key === "mode") {
      this.guardPick(this.q?.setPermissionMode(pick.id), "mode", pick.id, () => { this.selMode = prev.mode; });
    } else if (pick.key === "effort") {
      // ultracode isn't an effortLevel value — set its own flag; any concrete
      // level must also lift a previously-set ultracode (it's sticky).
      this.guardPick(
        this.q?.applyFlagSettings(pick.id === "ultracode" ? { ultracode: true } : { effortLevel: pick.id, ultracode: false }),
        "effort", pick.id,
        () => { this.selEffort = prev.effort; this.effortExplicit = prev.effortExplicit; },
      );
    }
  }

  protected preparePrompt(): void {
    if (!this.controller) throw new Error("claude session not started");
  }

  protected async sendPrompt(text: string, commandId?: string): Promise<void> {
    const turnId = this.activeTurnId ?? "";
    // Slash command → send the literal "/name args"; the CLI parses it.
    const body = commandId?.startsWith("cmd:") ? `/${commandId.slice(4)}${text.trim() ? " " + text : ""}` : text;
    // The Claude SDK stream never echoes the user turn back (unlike codex), so
    // emit the user message ourselves — otherwise it renders only on resume via
    // claudeResumeReplay, never live. Shape mirrors that replay path.
    this.emitItem(`user:${turnId}`, { kind: "message", role: "user", text: body }, { turnId });
    this.pushHistory({ type: "user", message: { role: "user", content: body } });
    this.controller?.push({ type: "user", message: { role: "user", content: body }, parent_tool_use_id: null } as any);
  }

  // Shape matches claudeResumeReplay's expected entries so transcriptSnapshot
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
    if (thinking) this.emitItem(`reason:${c.uuid}`, { kind: "reasoning", role: "assistant", text: thinking }, { turnId });
    if (text) {
      this.emitItem(`msg:${c.uuid}`, { kind: "message", role: "assistant", text }, { turnId });
      // Same text as the emitted item — see `history` field doc.
      this.pushHistory({ type: "assistant", message: {
        role: "assistant", content: [{ type: "text", text }],
        ...(c?.message?.usage ? { usage: c.message.usage } : {}),
        ...(c?.message?.id ? { id: c.message.id } : {}),
      }, uuid: c?.uuid });
    }
    for (const t of toolUses) {
      this.emitItem(`tool:${t.id}`, {
        kind: "tool_call", status: "running", toolKind: mapToolKind(t.name), title: t.name, rawInput: t.input,
      }, { turnId });
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
      // A backgrounded Bash returns a stub result while the process keeps
      // running — task_notification is the real settle event. Keep the item
      // running until then.
      const live = this.taskByItemId(itemId);
      this.emitItem(itemId, {
        kind: "tool_call",
        status: live ? "running" : b.is_error ? "error" : "completed",
        content: [{ type: "terminal", data }],
      }, { turnId });
      if (live) live.itemSnapshot = this.cachedItem(itemId);
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
      this.emitUsage({ total: { ...this.usageTotal }, last: { totalTokens }, contextWindow: maxTokens });
    } catch {
      // Best effort; see method doc.
    }
  }

  private onResult(c: any): void {
    const turnId = this.activeTurnId ?? "";
    if (!turnId) return;
    const stopReason = this.cancelRequested ? "cancelled" : c?.is_error ? "error" : "end_turn";
    const limited = stopReason === "error" ? this.limitSnapshot() : undefined;
    // A turn that ran to completion proves the window is over, whether or not
    // the CLI bothered to emit a clearing rate_limit_event.
    if (stopReason === "end_turn") this.rateLimited = null;
    if (c?.usage) {
      const last = mapUsage(c.usage);
      addUsage(this.usageTotal, last);
      const modelUsage = this.resolvedModel ? c?.modelUsage?.[this.resolvedModel] : undefined;
      const contextWindow = modelUsage?.contextWindow;
      this.emitUsage({
        turnId,
        // total_cost_usd is the SDK's own cumulative-for-the-query figure, which
        // with one persistent query per session IS the session total.
        total: { ...this.usageTotal, ...(typeof c?.total_cost_usd === "number" ? { costUsd: c.total_cost_usd } : {}) },
        last,
        ...(typeof contextWindow === "number" && contextWindow > 0 ? { contextWindow } : {}),
      });
    }
    this.closeTurn({
      stopReason,
      turnId,
      ...(stopReason === "error" ? { error: mapResultError(c, limited) } : {}),
    });
    // Do NOT end the prompt stream here: one persistent query serves the whole
    // session, so stdin stays open across turns; end() happens only in dispose().
  }

  protected async interrupt(_turnId: string): Promise<void> {
    await this.q?.interrupt();
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

  protected async transcriptSnapshot(): Promise<AbMessage[]> {
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
        // "Always" persists via the SDK's own suggestions (returned as
        // updatedPermissions per the CanUseTool doc) — without suggestions
        // there is nothing to persist, so the option isn't offered.
        const suggestions = Array.isArray(options?.suggestions) ? options.suggestions : [];
        this.askPermission({
          itemId: `tool:${options?.toolUseID ?? ""}`,
          title: options?.title ?? `Allow ${toolName}?`,
          reason: options?.description !== undefined ? String(options.description) : undefined,
          options: [
            { optionId: "once", label: "Allow once", kind: "allow_once" as const },
            ...(suggestions.length ? [{ optionId: "always", label: "Always allow", kind: "allow_always" as const }] : []),
            { optionId: "reject", label: "Deny", kind: "reject" as const },
          ],
        }, (optionId) => {
          if (optionId === "reject" || optionId == null) {
            resolve({ behavior: "deny", message: "denied by user", ...(optionId == null ? { interrupt: true } : {}) });
          } else {
            resolve({
              behavior: "allow", updatedInput: input,
              ...(optionId === "always" && suggestions.length ? { updatedPermissions: suggestions } : {}),
            });
          }
        });
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
      this.askQuestion({
        kind: opts.length ? "single_select" : "text",
        prompt: String(q.question ?? q.header ?? "?"),
        ...(opts.length ? { options: opts.map((o, idx) => ({ id: String(idx), label: String(o?.label ?? ""), description: o?.description })) } : {}),
      }, (value) => {
        if (value == null) { resolve({ behavior: "deny", message: "question dismissed", interrupt: true }); return; }
        const answer = Array.isArray(value) ? (value[0] ?? "") : value;
        resolve({ behavior: "allow", updatedInput: { ...input, answers: { [String(q.question ?? "")]: answer } } });
      }, {
        single: true,
        // The app answers with the synthetic index id; the SDK's answers map is
        // keyed by question text and takes the LABEL as its value.
        ...(opts.length ? { labels: opts.map((o) => String(o?.label ?? "")) } : {}),
      });
    });
  }

  // Async: the SDK's close() only schedules SIGTERM/SIGKILL on unref'd
  // 2s/5s timers and returns immediately, so a synchronous dispose let a
  // stop->restart race two claude processes. Wait out the consume loop
  // (which ends once the query's iterator completes); if it's still running
  // after the grace period, escalate to aborting the spawn's AbortController
  // as a hard kill and wait once more before giving up.
  protected async disposeBackend(): Promise<void> {
    // Best-effort reap before teardown: on the SIGKILL escalation path the SDK
    // kills only the CLI pid (no process group), orphaning background shells.
    if (this.backgroundTasks.size > 0) {
      const stops = [...this.backgroundTasks.keys()].map(
        (id) => this.q?.stopTask(id).catch(() => {}) ?? Promise.resolve(),
      );
      await Promise.race([Promise.all(stops), Bun.sleep(BACKGROUND_REAP_GRACE_MS)]);
      this.clearBackgroundTasks();
    }
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
