import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { readFile, writeFile, rename, chmod, mkdir } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { z } from "zod";
import { logger } from "./logger";
const log = logger.child({ component: "session-manager" });
import {
  resolveAgent,
  resolveAgentEnv,
  suppressesOscNotifications,
  suppressesOscTitle,
} from "./known-agents";
import { augmentAgentLaunch, injectsHookAliveProbe } from "./agent-launch-augmenter";
import { resumeArgv, sessionResumable } from "./agent-resume";
import { isChatCapableTool } from "./structured/chat-capable";
import { initialPromptArgv } from "./initial-prompt";
import type { WorkStatus } from "./protocol";
import type { TerminalManager } from "./terminal-manager";
import type { AbMessage, SessionEntry } from "./protocol";
import type { CheckoutRecord } from "./worktrees/checkout-types";
import { WorktreeError, type WorktreeManager } from "./worktrees/worktree-manager";
import { logWorktreeEvent, worktreeErrorCode } from "./worktrees/worktree-log";

export interface AgentSpec {
  command: string;
  name: string;
  args?: string[];
  workingDir?: string;
}

export interface SessionLaunchSpec {
  tool?: string;
  command?: string;
  args?: string;
  // 'chat' routes session:start to the structured driver instead of a PTY.
  mode?: "terminal" | "chat";
  /** Shared is the historical default. Worktree is host-gated and never accepts
   * a path from the caller. */
  isolation?: "shared" | "worktree";
  /** An explicitly selected local branch to use as a base for a worktree. */
  baseBranch?: string;
}

export interface DeleteSessionOptions {
  force?: boolean;
  /** Managed sessions own their checkout, so retaining it is forbidden. */
  removeCheckout?: boolean;
  /** Explicit opt-in; managed branches are preserved by default. */
  deleteBranch?: boolean;
}

/// Quote a single token (executable path or flag) for the shell that
/// terminal-session will wrap a whitespace command in (`cmd /c` on Windows,
/// `sh -c` elsewhere). Tokens without shell-significant characters pass through
/// unchanged so bare bins like `claude` stay clean.
function shellQuoteArg(s: string): string {
  if (s === "" || !/[\s"'\\]/.test(s)) return s;
  return process.platform === "win32"
    ? `"${s.replace(/"/g, '""')}"` // cmd.exe: double-quote, escape embedded "
    : `'${s.replace(/'/g, `'\\''`)}'`; // POSIX sh: single-quote, escape embedded '
}

export interface SessionManagerOpts {
  projectId: string;
  storeDir: string;                  // ~/.antgrid root
  /**
   * Absolute project directory. Used as the cwd fallback for sessions whose
   * `agent.workingDir` is unset — without this, `terminal-session.ts` would
   * fall through to `process.cwd()`, which is the agent process's cwd and
   * not necessarily the project folder.
   */
  projectPath: string;
  terminalManager: TerminalManager;
  agentSpec: AgentSpec;
  sendMessage: (msg: unknown) => void;
  /** This session's status in the owning core's work reduction, stamped onto
   *  each `session:updated` entry. Injected rather than folded here so there is
   *  exactly one per-session reduction; absent for a bare core with no owner,
   *  which then advertises no status at all. */
  sessionWorkStatusFor?: (sessionId: string) => WorkStatus | undefined;
  /** Override for the codex thread store dir (resume pre-flight). Unset in
   *  production → defaults to ~/.codex; tests inject an isolated dir. */
  codexHome?: string;
  /** Override for the Copilot session store dir (resume pre-flight). */
  copilotHome?: string;
  /** Override for how long setMode waits on the old runtime's teardown. Unset in
   *  production → TEARDOWN_TIMEOUT_MS; tests inject a short one to exercise the
   *  timeout path without stalling. */
  teardownTimeoutMs?: number;
  /** Override for the cursor-agent hooks dir (~/.cursor). Unset in production.
   *  Tests exercising the hooks write MUST inject an isolated dir; one that
   *  forgets gets a no-op rather than junk in the developer's real config —
   *  ensureGlobalCursorHooks refuses the homedir default under `bun test`,
   *  because the baked hook command there is the test file (Bun.main). */
  cursorDir?: string;
  /** Called by start()/stop() for a mode:'chat' session instead of the PTY path.
   *  Injected by agent-core to drive the StructuredAgentManager. */
  onStartChat?: (opts: { sessionId: string; tool: string; resumeId?: string; config?: Record<string, string>; initialPrompt?: string }) => void;
  /** May return the teardown promise. The structured driver's dispose is what
   *  releases the agent's own process lock (codex's ~/.codex sqlite), so a
   *  caller that restarts this slot on another runtime must be able to await
   *  it — a void-returning implementation stays valid. */
  onStopChat?: (sessionId: string) => void | Promise<void>;
  /** False until every checkout-variable workspace service is routed. */
  worktreeSessionsSupported?: boolean;
  /** Resolved lazily, never at construction: answering it costs a `git` spawn,
   *  and it is only ever consulted when an isolated session is created. Absent
   *  means "not a repository", so a caller that cannot answer fails closed. */
  isGitRepository?: () => Promise<boolean>;
  worktreeManager?: WorktreeManager;
  /** Construct the checkout-scoped runtime before a session can commit. */
  prepareCheckoutRuntime?: (checkout: CheckoutRecord) => Promise<void>;
  teardownCheckoutRuntime?: (checkoutId: string) => Promise<void>;
  /** Resolves persisted IDs on every start; explicit unknown IDs never main-fallback. */
  resolveCheckout?: (checkoutId: string) => Promise<CheckoutRecord | undefined>;
  /** Reads checkout-local configuration after runtime preparation. */
  resolveAgentSpec?: (checkoutId: string) => Promise<AgentSpec>;
}

interface PersistedEntry {
  id: string;
  name: string;
  createdAt: number;
  lastUsedAt: number;
  archived: boolean;
  tool?: string;
  command?: string;
  args?: string;
  // PTY (terminal) vs structured-driver (chat) session. Fixed at creation —
  // the two use different backends, so there is no post-hoc switch.
  mode: "terminal" | "chat";
  // True once the user has named this session (manual rename or explicit
  // create-time name). Auto-naming from the agent title is suppressed forever
  // after — manual always wins. Backfilled from the name pattern on load.
  manuallyRenamed: boolean;
  // Last-active agent-native conversation id for this slot (the agent's own
  // id-space, distinct from `id`). Persisted-only — never sent on the wire.
  // Overwrite-latest: whatever the agent last reported is "where you left off",
  // resumed on the next start(). See agent-resume.ts.
  agentSessionId?: string;
  // The agent's transcript/session file path when its hook supplied one
  // (claude). Used for the pre-flight existence check. Codex/
  // opencode don't post a path.
  agentTranscriptPath?: string;
  // Session-scoped structured-driver selections keyed by the wire config key the
  // app sent via agent:set-config (`model` | `effort` | `mode`), overwrite-latest
  // per key. Persisted-only — never on the wire (SessionEntry). Replayed through
  // driver.setConfig() on start so a restart restores the last-picked
  // model/mode/effort instead of reverting to the backend default.
  config?: Record<string, string>;
  checkoutId: string;
  checkoutKind: "main" | "managed-worktree" | "external-worktree";
  checkoutBranch?: string | null;
  checkoutState: "ready" | "missing" | "failed";
}

/** On-disk shape written by `flush()`; validated on read by PersistedFileSchema. */
interface FileShape {
  version: 1;
  sessions: PersistedEntry[];
}

// One malformed row must not drop the rest: id/name are the only hard
// requirements; bad scalar fields fall back rather than failing the row. A
// non-bool legacy `archived` (older builds wrote truthy) is coerced, not
// rejected. `.catch(undefined)` turns a wrong-typed timestamp/string into a
// missing value the transform then defaults.
const PersistedEntrySchema = z
  .object({
    id: z.string().min(1),
    name: z.string().min(1),
    createdAt: z.number().finite().optional().catch(undefined),
    lastUsedAt: z.number().finite().optional().catch(undefined),
    archived: z.unknown().transform((v) => Boolean(v)),
    tool: z.string().optional().catch(undefined),
    command: z.string().optional().catch(undefined),
    args: z.string().optional().catch(undefined),
    mode: z.enum(["terminal", "chat"]).optional().catch(undefined),
    manuallyRenamed: z.boolean().optional().catch(undefined),
    agentSessionId: z.string().optional().catch(undefined),
    agentTranscriptPath: z.string().optional().catch(undefined),
    config: z.record(z.string(), z.string()).optional().catch(undefined),
    checkoutId: z.string().optional().catch(undefined),
    checkoutKind: z.enum(["main", "managed-worktree", "external-worktree"]).optional().catch(undefined),
    checkoutBranch: z.string().nullable().optional().catch(undefined),
    checkoutState: z.enum(["ready", "missing", "failed"]).optional().catch(undefined),
  })
  .transform((s): PersistedEntry => {
    const createdAt = s.createdAt ?? Date.now();
    return {
      id: s.id,
      name: s.name,
      createdAt,
      lastUsedAt: s.lastUsedAt ?? createdAt,
      archived: s.archived,
      tool: s.tool,
      command: s.command,
      args: s.args,
      // Files written before this feature lack mode → 'terminal' (PTY), the
      // only backend those builds had.
      mode: s.mode ?? "terminal",
      // Backfill: files written before this feature lack the flag. A name that
      // isn't a default "Session N" was user-chosen → treat as manual so
      // live-follow never clobbers it. Default names start following.
      manuallyRenamed: s.manuallyRenamed ?? !/^Session \d+$/.test(s.name),
      agentSessionId: s.agentSessionId,
      agentTranscriptPath: s.agentTranscriptPath,
      config: s.config,
      checkoutId: s.checkoutId ?? "main",
      checkoutKind: s.checkoutKind ?? "main",
      checkoutBranch: s.checkoutBranch,
      checkoutState: s.checkoutState ?? "ready",
    };
  });

const PersistedFileSchema = z.object({
  version: z.literal(1),
  sessions: z.array(z.unknown()),
});

/** Validate sessions.json content into raw persisted entries (Zod, no I/O).
 *  Shared by the instance `load()` and the static `readPersisted()` peek so the
 *  two never drift. A malformed row is skipped; a missing/corrupt/wrong-version
 *  file yields []. Never throws. */
function parsePersistedContent(raw: string | null): PersistedEntry[] {
  if (raw === null) return [];
  try {
    const file = PersistedFileSchema.safeParse(JSON.parse(raw));
    if (!file.success) return [];
    const out: PersistedEntry[] = [];
    for (const s of file.data.sessions) {
      const entry = PersistedEntrySchema.safeParse(s);
      if (entry.success) out.push(entry.data);
    }
    return out;
  } catch (err) {
    log.warn("sessions.json unreadable, treating as empty: %s", err);
    return [];
  }
}

/** Atomically write sessions.json (async, fs/promises) — tmp file + rename so a
 *  crash mid-write can never truncate the file (which load()/readPersisted would
 *  then read as empty and silently drop every session). Mirrors the instance
 *  flush(): pretty-printed, 0o600 on POSIX. The only caller is the static
 *  deletePersisted on the WS event loop, hence async. Keep in lockstep with
 *  flush(). */
async function writePersistedAtomic(
  path: string,
  sessions: PersistedEntry[],
): Promise<void> {
  const file: FileShape = { version: 1, sessions };
  const tmp = `${path}.tmp`;
  await writeFile(tmp, JSON.stringify(file, null, 2), "utf8");
  await rename(tmp, path);
  if (process.platform !== "win32") {
    try { await chmod(path, 0o600); } catch { /* ignore */ }
  }
}

const FLUSH_DEBOUNCE_MS = 200;
// Upper bound on how long a mode flip waits for the OLD runtime to be really
// gone. A wedged PTY or a driver whose dispose never settles must fail the flip
// rather than hang it forever.
const TEARDOWN_TIMEOUT_MS = 15_000;

/** Leading text of `session:result.error` when a mode flip aborted because the
 *  old runtime never tore down. This is the ONLY setMode failure that leaves
 *  the session stopped, so the app branches its copy on it rather than telling
 *  every failure to go restart something — keep in lockstep with
 *  `kTeardownTimeoutError` in app/lib/widgets/session_mode_control.dart. */
export const TEARDOWN_TIMEOUT_ERROR = "timed out tearing down session";

/** Leading text of `session:result.error` when a mode flip tore the old runtime
 *  down but could not bring the new one up. Like {@link TEARDOWN_TIMEOUT_ERROR}
 *  it leaves the session STOPPED — the app must not tell the user it is
 *  untouched — but the shutdown itself worked, so it gets its own copy. Keep in
 *  lockstep with `kRestartFailedError` in
 *  app/lib/widgets/session_mode_control.dart. */
export const RESTART_FAILED_ERROR = "failed to restart session after mode switch";
// Live activity (keystrokes, notification bursts) fires many times a second;
// coalesce the session:updated emit so the drawer re-sort doesn't thrash.
const ACTIVITY_EMIT_DEBOUNCE_MS = 750;

export class SessionManager {
  private entries = new Map<string, PersistedEntry>();
  private observers = new Set<() => void>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private activityEmitTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly dir: string;
  private readonly path: string;
  private readonly tm: TerminalManager;
  private readonly projectPath: string;
  private agentSpec: AgentSpec;
  // Running state for chat sessions, which have no PTY to query for `has(id)`.
  // Set in start()'s chat branch, cleared in stop()'s — the PTY-less analogue of
  // `tm.has(id)`, and best-effort (a crashed driver surfaces via agent:error).
  private runningChat = new Set<string>();
  // Callbacks waiting for a session's PTY to actually be gone, keyed by session
  // id and fired from noteExited(). See awaitTerminalExit().
  private terminalExitWaiters = new Map<string, Set<(exited: boolean) => void>>();
  /** Sessions mid-`setMode`, counted rather than flagged. The exit-driven
   *  teardown reads this to tell a runtime swap apart from a session that is
   *  actually going away, and nothing serializes the verb — two clients can have
   *  flips in flight on one session at once, so the first one to finish must not
   *  clear the protection the second is still relying on. */
  private flipping = new Map<string, number>();
  // Memoized sessionResumable() answers, keyed by session id and tagged with the
  // agentSessionId they were computed for. toWire() runs per entry on every
  // changed() emit and the real check does existsSync + a bun:sqlite query, so
  // it must never reach that path. Invalidated whenever setAgentSession writes
  // something new; a stale `true` is harmless because start() re-runs the real
  // pre-flight and falls back to a fresh start.
  private resumableCache = new Map<string, { agentSessionId: string; resumable: boolean }>();

  constructor(private opts: SessionManagerOpts) {
    this.dir = join(opts.storeDir, "agents", opts.projectId);
    this.path = join(this.dir, "sessions.json");
    this.tm = opts.terminalManager;
    this.projectPath = opts.projectPath;
    this.agentSpec = opts.agentSpec;
    this.load();
  }

  /**
   * Replace the spec used for future `start()` calls. antgrid.yaml can change at
   * runtime (configController.watch); the new spec applies to sessions started
   * after this call. Already-running PTYs keep their original spec — the user
   * must stop+start to pick up a new command (matches `agentRestartRequired`
   * handling in index.ts).
   */
  setAgentSpec(spec: AgentSpec): void {
    this.agentSpec = spec;
  }

  // --- API ---

  list(includeArchived = false): SessionEntry[] {
    const out: SessionEntry[] = [];
    for (const e of this.entries.values()) {
      if (!includeArchived && e.archived) continue;
      out.push(this.toWire(e));
    }
    out.sort((a, b) => b.lastUsedAt - a.lastUsedAt);
    return out;
  }

  /** Whether any persisted session requires checkout-scoped workspace routing. */
  hasManagedSessions(): boolean {
    for (const entry of this.entries.values()) {
      if (entry.checkoutKind === "managed-worktree") return true;
    }
    return false;
  }

  /** Whether a work-status key belongs to the main checkout — i.e. whether a
   *  main-checkout branch switch can disturb it. An unknown key is main: the
   *  work reduction also files config `terminals:` slots and a project-wide
   *  fallback key, both of which live in the primary working tree. */
  isMainCheckoutSession(id: string): boolean {
    const entry = this.entries.get(id);
    return !entry || entry.checkoutId === "main";
  }

  /** Read a project's persisted session list from disk WITHOUT a live core —
   *  the drawer's control-plane peek. Async (`fs/promises`) because the only
   *  caller is the control-plane RPC handler on the WS event loop; a sync read
   *  on a slow/networked home dir would stall every other frame on that socket.
   *  `running` is always false: the file carries no runtime PTY state (a warm
   *  core's live `list()` is authoritative for that, fetched on focus). Durable
   *  fields, though, MUST be carried through — `agentSessionId` in particular:
   *  the peek is the only session source a second device has before focus, and
   *  the app gates chat-transcript hydration on it, so dropping it renders an
   *  empty transcript for a session started on another device. Path mirrors the
   *  instance writer: `join(storeDir, "agents", projectId, "sessions.json")`. */
  static async readPersisted(
    storeDir: string,
    projectId: string,
    includeArchived = false,
  ): Promise<SessionEntry[]> {
    const path = join(storeDir, "agents", projectId, "sessions.json");
    let raw: string | null = null;
    try {
      raw = await readFile(path, "utf8");
    } catch {
      return []; // missing or unreadable → empty peek
    }
    const out: SessionEntry[] = [];
    for (const e of parsePersistedContent(raw)) {
      if (!includeArchived && e.archived) continue;
      out.push({
        id: e.id, name: e.name, createdAt: e.createdAt, lastUsedAt: e.lastUsedAt,
        archived: e.archived, running: false,
        tool: e.tool, command: e.command, args: e.args, mode: e.mode,
        // Optimistic, like `running: false` above: the peek has no live core,
        // and the real check needs the agent-store overrides only an instance
        // holds. A wrong `true` shows a control the live list then hides; a
        // wrong `false` hides one that should be there.
        agentSessionResumable: true,
        agentSessionId: e.agentSessionId,
        checkoutId: e.checkoutId,
        checkoutKind: e.checkoutKind,
        checkoutBranch: e.checkoutBranch,
        checkoutState: e.checkoutState,
      });
    }
    out.sort((a, b) => b.lastUsedAt - a.lastUsedAt);
    return out;
  }

  /** Delete a session row from a project's persisted sessions.json WITHOUT a
   *  live core — the control-plane counterpart to readPersisted. Used only when
   *  no warm core owns the file (host-server routes warm cores to the live
   *  SessionManager so in-memory state never desyncs). Returns true if a row was
   *  removed. Path mirrors readPersisted. */
  static async deletePersisted(
    storeDir: string,
    projectId: string,
    sessionId: string,
  ): Promise<boolean> {
    const path = join(storeDir, "agents", projectId, "sessions.json");
    let raw: string | null = null;
    try {
      raw = await readFile(path, "utf8");
    } catch {
      return false; // missing/unreadable → nothing to delete
    }
    const entries = parsePersistedContent(raw);
    const next = entries.filter((e) => e.id !== sessionId);
    if (next.length === entries.length) return false; // id not present
    await writePersistedAtomic(path, next);
    return true;
  }

  get(id: string): SessionEntry | undefined {
    const e = this.entries.get(id);
    return e ? this.toWire(e) : undefined;
  }

  /**
   * The config a brand-new chat session for `tool` should start from: the
   * selection of the most-recently-used, non-archived chat session of the same
   * tool that carries one. This makes "default for a new session" == "what I last
   * used for this tool" without a separate preferences store. Returns a fresh
   * copy (callers persist it as the new entry's own config).
   */
  private lastUsedConfigForTool(tool: string): Record<string, string> | undefined {
    let best: PersistedEntry | undefined;
    for (const e of this.entries.values()) {
      if (e.archived || e.mode !== "chat" || e.tool !== tool) continue;
      if (!e.config || Object.keys(e.config).length === 0) continue;
      if (!best || e.lastUsedAt > best.lastUsedAt) best = e;
    }
    return best?.config ? { ...best.config } : undefined;
  }

  create(name?: string, spec?: SessionLaunchSpec & { isolation?: "shared" }): SessionEntry;
  create(name: string | undefined, spec: SessionLaunchSpec & { isolation: "worktree" }): Promise<SessionEntry>;
  create(name?: string, spec?: SessionLaunchSpec): SessionEntry | Promise<SessionEntry>;
  create(name?: string, spec?: SessionLaunchSpec): SessionEntry | Promise<SessionEntry> {
    if (spec?.baseBranch && spec.isolation !== "worktree") {
      throw new Error("baseBranch is only valid for an isolated worktree session");
    }
    if (spec?.isolation === "worktree") return this.createWorktree(name, spec);
    const entry = this.buildEntry(name, spec);
    this.entries.set(entry.id, entry);
    this.changed();
    return this.toWire(entry);
  }

  private buildEntry(name: string | undefined, spec: SessionLaunchSpec | undefined): PersistedEntry {
    let finalName: string;
    if (name === undefined) {
      finalName = this.nextDefaultName();
    } else {
      const trimmed = name.trim();
      if (!trimmed) throw new Error("name cannot be empty");
      finalName = trimmed;
    }
    // Validate the tool key up front so an unknown agent (e.g. a newer app
    // sending a key an older agent doesn't know) is rejected at the source as a
    // session:result error, rather than persisting an entry that fails every
    // start() forever (and re-fails on each reconnect once it's on disk).
    if (spec?.tool) resolveAgent(spec.tool);
    const id = crypto.randomUUID();
    const now = Date.now();
    const entry: PersistedEntry = {
      id,
      name: finalName,
      createdAt: now,
      lastUsedAt: now,
      archived: false,
      tool: spec?.tool,
      command: spec?.command,
      args: spec?.args,
      mode: spec?.mode ?? "terminal",
      manuallyRenamed: name !== undefined,
      checkoutId: "main",
      checkoutKind: "main",
      checkoutState: "ready",
    };
    // A new chat session inherits the last-used selection for its tool so it
    // opens on the model/mode/effort the user actually works with, not the
    // backend default. Terminal sessions and tool-less entries get nothing.
    if (entry.mode === "chat" && entry.tool) {
      const inherited = this.lastUsedConfigForTool(entry.tool);
      if (inherited) entry.config = inherited;
    }
    return entry;
  }

  /**
   * Isolated creation deliberately has no visible session until all host-owned
   * state is usable and durable. The old synchronous shared API remains intact
   * for compatibility with pre-worktree callers; the wire handler always awaits
   * either result.
   */
  private async createWorktree(name: string | undefined, spec: SessionLaunchSpec): Promise<SessionEntry> {
    if (!this.opts.worktreeSessionsSupported || !this.opts.worktreeManager) {
      throw new WorktreeError("WORKTREE_UNSUPPORTED", "This bridge cannot isolate sessions yet.");
    }
    if (!await this.opts.isGitRepository?.()) {
      throw new WorktreeError("NOT_GIT_REPOSITORY", "This project is not a Git repository.");
    }
    const entry = this.buildEntry(name, spec);
    let checkout: CheckoutRecord | undefined;
    let runtimePrepared = false;
    try {
      checkout = await this.opts.worktreeManager.prepareForSession({
        projectId: this.opts.projectId,
        repoPath: this.projectPath,
        sessionId: entry.id,
        sessionName: entry.name,
        baseBranch: spec.baseBranch,
      });
      await this.opts.prepareCheckoutRuntime?.(checkout);
      runtimePrepared = true;
      const checkoutSpec = await this.opts.resolveAgentSpec?.(checkout.id) ?? this.agentSpec;
      this.assertSafeWorkingDir(checkout.path, checkoutSpec.workingDir);
      entry.checkoutId = checkout.id;
      entry.checkoutKind = checkout.kind;
      entry.checkoutBranch = checkout.branch;
      entry.checkoutState = "ready";
      this.entries.set(entry.id, entry);
      await this.flushNowOrThrow();
      this.notifyObservers();
      return this.toWire(entry);
    } catch (error) {
      this.entries.delete(entry.id);
      if (runtimePrepared && checkout) {
        try { await this.opts.teardownCheckoutRuntime?.(checkout.id); } catch { /* rollback continues */ }
      }
      if (checkout) {
        try { await this.opts.worktreeManager.rollbackPrepared(checkout); } catch { /* preserve original error */ }
      }
      throw error;
    }
  }

  rename(id: string, name: string): void {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    const trimmed = name.trim();
    if (!trimmed) throw new Error("name cannot be empty");
    entry.name = trimmed;
    entry.manuallyRenamed = true;
    this.changed();
  }

  /**
   * Apply an auto-derived name from the running agent's conversation title.
   * The manual-wins check is HERE (apply time), not at the signal source, so a
   * debounced/in-flight auto-update is dropped the instant the user renames.
   * No-ops for non-session ids (service PTYs) and unchanged names so callers
   * can fire it freely without spamming session:updated.
   */
  /**
   * Whether an auto-name would still land on this id. Same predicate
   * applyAutoName enforces, exposed so a caller can skip EXPENSIVE work whose
   * only output is an auto-name — generating a title costs a model spawn, and
   * a user who renamed the session would never see it.
   */
  isAutoNameable(id: string): boolean {
    const entry = this.entries.get(id);
    return !!entry && !entry.manuallyRenamed;
  }

  applyAutoName(id: string, name: string): void {
    const entry = this.entries.get(id);
    if (!entry || entry.manuallyRenamed) return;
    const trimmed = name.trim();
    if (!trimmed || trimmed === entry.name) return;
    entry.name = trimmed;
    this.changed();
  }

  /**
   * Record the agent's last-active native conversation id for a slot
   * (overwrite-latest). Called from the /session-title pipeline every turn.
   * No-ops for unknown ids (service PTYs) so callers can fire it freely.
   * `id` is the slot id (== the hook's terminalId == the spawned PTY id).
   */
  setAgentSession(id: string, agentSessionId: string, agentTranscriptPath?: string): void {
    const entry = this.entries.get(id);
    if (!entry) return;
    // Keep a previously captured path if this report omits one for the SAME
    // session — an agent's SessionStart can fire before the transcript path is
    // known, then a later turn-end report supplies it. A new session id resets it.
    const nextPath =
      agentSessionId === entry.agentSessionId
        ? (agentTranscriptPath ?? entry.agentTranscriptPath)
        : agentTranscriptPath;
    if (entry.agentSessionId === agentSessionId && entry.agentTranscriptPath === nextPath) {
      return; // unchanged — avoid a redundant flush/emit
    }
    entry.agentSessionId = agentSessionId;
    entry.agentTranscriptPath = nextPath;
    this.resumableCache.delete(id);
    this.changed();
  }

  /** Handler-judge lookup. agentTranscriptPath is deliberately ABSENT from
   *  toWire()/SessionEntry (persisted-only, never on the wire) — do NOT expose
   *  it by adding it to toWire; this getter is the sanctioned read path. */
  getAgentTranscriptPath(id: string): string | undefined {
    return this.entries.get(id)?.agentTranscriptPath;
  }

  /**
   * Persist a structured-driver selection (model/effort/mode) for a chat slot,
   * overwrite-latest per key. The sibling of setAgentSession: persisted-only,
   * replayed through driver.setConfig() on the next start() so the selection
   * survives a stop→start. The driver's live capabilities echo already told the
   * app the current value, so no extra wire emit is needed here. No-ops for
   * unknown ids (service PTYs / stale slots) and unchanged values.
   */
  setSessionConfig(id: string, key: string, value: string): void {
    const entry = this.entries.get(id);
    if (!entry) return;
    if (entry.config?.[key] === value) return; // unchanged — avoid a redundant flush
    entry.config = { ...entry.config, [key]: value };
    this.changed();
  }

  archive(id: string): void {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    if (this.tm.has(id)) this.tm.kill(id);
    entry.archived = true;
    this.changed();
  }

  unarchive(id: string): void {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    entry.archived = false;
    this.changed();
  }

  /** Remove a session. Managed checkout removal is asynchronous because Git
   * must verify the worktree disappeared before the durable session binding can
   * be forgotten. Shared deletion preserves its historical synchronous API. */
  delete(id: string, options: DeleteSessionOptions = {}): boolean | Promise<boolean> {
    const entry = this.entries.get(id);
    if (!entry) return false;
    if (entry.checkoutKind === "managed-worktree") {
      return this.deleteManaged(entry, options);
    }
    if (this.tm.has(id)) this.tm.kill(id);
    this.entries.delete(id);
    this.resumableCache.delete(id);
    this.changed();
    return true;
  }

  private async deleteManaged(entry: PersistedEntry, options: DeleteSessionOptions): Promise<boolean> {
    if (options.removeCheckout === false) {
      throw new WorktreeError("WORKTREE_CONFLICT", "An isolated session cannot be deleted without its managed worktree.");
    }
    const manager = this.opts.worktreeManager;
    if (!manager) throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree manager is unavailable.");
    // First preflight gives the UI a non-destructive refusal. Kept in lockstep
    // with WorktreeManager.removeNow's own guard, which repeats it under the
    // project lock — the split codes must match or the dialog copy is wrong.
    const state = await manager.inspect(entry.checkoutId);
    if (state.dirty && !options.force) {
      throw new WorktreeError("WORKTREE_DIRTY", "The isolated worktree has uncommitted changes.");
    }
    if (state.unpushedCommits && !options.force) {
      throw new WorktreeError("WORKTREE_UNPUSHED", "The isolated worktree's branch has unpushed commits.");
    }
    if (!await this.stopAndAwait(entry.id)) {
      throw new WorktreeError("WORKTREE_DELETE_FAILED", "The session did not stop before its worktree could be removed.");
    }
    // BEFORE the removal, not after: the checkout's runtime holds the very
    // directory Git is about to delete — auto-started `services:` PTYs run with
    // their cwd inside it, and the file watcher keeps handles open. On Windows
    // that turns `git worktree remove` into a sharing violation and the session
    // becomes permanently undeletable. The runtime is rebuilt if Git refuses.
    await this.opts.teardownCheckoutRuntime?.(entry.checkoutId);
    try {
      // WorktreeManager repeats its Git-backed dirty/lock and registration checks
      // immediately before removal, closing the race after the preflight.
      await manager.remove({
        checkoutId: entry.checkoutId,
        force: options.force ?? false,
        deleteBranch: options.deleteBranch ?? false,
      });
    } catch (error) {
      const checkout = await this.opts.resolveCheckout?.(entry.checkoutId).catch(() => undefined);
      if (checkout) {
        try { await this.opts.prepareCheckoutRuntime?.(checkout); } catch { /* preserve original error */ }
      }
      throw error;
    }
    this.entries.delete(entry.id);
    this.resumableCache.delete(entry.id);
    await this.flushNowOrThrow();
    this.notifyObservers();
    return true;
  }

  focus(_id: string): void {}

  /**
   * Record live activity for a session — a terminal notification (osc9/
   * osc777) or user keystrokes — by bumping `lastUsedAt`, so a session that is
   * working or being typed into floats to the top of the drawer even when it
   * isn't the focused one. No-ops for terminal ids that aren't sessions
   * (service PTYs), so callers can fire it unconditionally.
   *
   * Unlike focus(), both the session:updated emit and the disk flush are
   * coalesced onto the activity window (see scheduleActivityEmit): activity
   * fires many times a second, and emitting a full re-sorted list — or
   * rewriting sessions.json — per keystroke would spam the wire and the disk.
   * Persisting once per window is plenty: lastUsedAt is recency ordering, not
   * durable state, so losing the last sub-window bump on a crash is harmless.
   */
  touch(id: string): void {
    const entry = this.entries.get(id);
    if (!entry) return;
    entry.lastUsedAt = Date.now();
    this.scheduleActivityEmit();
  }

  /**
   * The owning core's work reduction moved a session — re-emit the list so the
   * `workStatus` stamped on each entry stays current. Work status changes far
   * more often than the list does, and nothing else would re-advertise it.
   *
   * Emits without persisting: the reduction is runtime state, so it re-advertises
   * the list but must not dirty sessions.json.
   *
   * Terminates because the reduction is same-object-on-no-change: the
   * `session:updated` this emits folds back through `foldSessions`, which
   * returns the SAME state when the session set is unchanged, so `commitWork`
   * never fires this again. Keep that discipline or this becomes a loop.
   */
  refreshWorkStatus(): void {
    // Deferred: the caller is the owning core's bus subscriber, and emitting a
    // session:updated from inside the publish that triggered it would nest one
    // frame's fan-out in another's.
    queueMicrotask(() => this.notifyObservers());
  }

  /**
   * Resume tokens for the slot's last-active agent conversation, or [] when none
   * was captured or it no longer exists on disk. A stale id (conversation deleted
   * via the agent's own tools) is cleared in place so the next start spawns fresh
   * rather than a "resume failed" PTY. Shared by the per-session-tool and the
   * default-spec (copilot) launch paths.
   */
  private resumeArgsFor(tool: string, entry: PersistedEntry): string[] {
    if (!entry.agentSessionId) return [];
    const resumable = sessionResumable({
      tool,
      agentSessionId: entry.agentSessionId,
      agentTranscriptPath: entry.agentTranscriptPath,
      codexHome: this.opts.codexHome,
      copilotHome: this.opts.copilotHome,
    });
    if (resumable) return resumeArgv(tool, entry.agentSessionId);
    entry.agentSessionId = undefined;
    entry.agentTranscriptPath = undefined;
    this.resumableCache.delete(entry.id);
    this.changed();
    return [];
  }

  start(id: string, initialPrompt?: string): void | Promise<void> {
    const entry = this.entries.get(id);
    if (!entry || entry.checkoutId === "main") return this.startNow(id, initialPrompt);
    return this.startCheckout(id, initialPrompt, entry.checkoutId);
  }

  private async startCheckout(id: string, initialPrompt: string | undefined, checkoutId: string): Promise<void> {
    const checkout = await this.opts.resolveCheckout?.(checkoutId);
    if (!checkout || checkout.id !== checkoutId || !checkout.path) {
      const entry = this.entries.get(id);
      if (entry) {
        entry.checkoutState = "missing";
        this.changed();
      }
      logWorktreeEvent("worktree_resume_missing", {
        projectId: this.opts.projectId, checkoutId, sessionId: id,
      });
      throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree is no longer available.");
    }
    const spec = await this.opts.resolveAgentSpec?.(checkoutId) ?? this.agentSpec;
    try {
      this.assertSafeWorkingDir(checkout.path, spec.workingDir);
    } catch (error) {
      // The checkout is there but unusable — antgrid.yaml moved agent.workingDir
      // outside it since creation. Distinct from "missing" for triage.
      logWorktreeEvent("worktree_resume_conflict", {
        projectId: this.opts.projectId, checkoutId, sessionId: id,
        errorCode: worktreeErrorCode(error),
      });
      throw error;
    }
    const entry = this.entries.get(id);
    if (entry && entry.checkoutState !== "ready") {
      entry.checkoutState = "ready";
      this.changed();
    }
    this.startNow(id, initialPrompt, checkout.path, spec);
  }

  private startNow(id: string, initialPrompt?: string, checkoutPath = this.projectPath, sessionAgentSpec = this.agentSpec): void {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    if (entry.archived) throw new Error(`cannot start archived session: ${id}`);
    if (entry.mode === "chat") {
      // Chat sessions have no PTY. Delegate to the structured manager; the
      // persisted agentSessionId (codex threadId / opencode sessionID) resumes
      // the prior conversation. Tool defaults to codex — chat is only offered for
      // codex/opencode, gated app-side and re-checked in startChat.
      this.runningChat.add(id);
      this.opts.onStartChat?.({
        sessionId: id,
        tool: entry.tool ?? "codex",
        resumeId: entry.agentSessionId,
        config: entry.config,
        initialPrompt,
      });
      entry.lastUsedAt = Date.now();
      this.changed();
      return;
    }
    if (this.tm.has(id)) {
      log.warn(`session ${id} already running`);
      return;
    }

    // Resolve the launch command for THIS session. Precedence:
    //   per-session tool (registry -> bin) -> per-session custom command ->
    //   antgrid.yaml default spec. resolveAgent throws on an unknown key, which
    //   surfaces as a session:result error rather than spawning a stray shell.
    //
    // `baseArgs` carries the antgrid.yaml default flags (`agent.flags`) and applies
    // ONLY on the fallback path — a per-session tool/command launches a different
    // binary, so the default's flags don't belong to it.
    let base: string | undefined;
    let baseArgs: string[] = [];
    let launchEnv: Record<string, string> = {};
    // `isCustomLine` marks a free-form user command (`entry.command`): it may be
    // a whole shell line (`my-agent --serve`), so we must NOT quote it — the user
    // owns its quoting. A resolved bin or the antgrid.yaml default command is a
    // single executable token and IS quoted when folded, so a path with spaces
    // survives the shell.
    let isCustomLine = false;
    // Resume tokens (`--resume <id>`, `--session <id>`, or codex's `resume
    // <uuid>` subcommand). Captured here, appended LAST in the spawn block.
    let resumeArgs: string[] = [];
    // Set only when an augmenter branch actually reports it (currently
    // cursor-agent's hooks.json write); undefined means "trust the registry's
    // static notificationSource" for every other tool. See LaunchAugmentation.
    let notificationsInjected: boolean | undefined;
    if (entry.tool) {
      // Tool launch: the registry may supply default flags (e.g. Codex's
      // notification-forcing `-c` overrides). These belong to the resolved bin,
      // so they flow through baseArgs exactly like the antgrid.yaml fallback's.
      const resolved = resolveAgent(entry.tool);
      base = resolved.bin;
      baseArgs = resolved.args;
      launchEnv = resolveAgentEnv(entry.tool, this.opts.storeDir);
      // Per-spawn integration that lets the agent report its conversation title
      // for auto-naming. Additive flags/env only; fail-open inside the augmenter.
      const aug = augmentAgentLaunch(entry.tool, this.opts.storeDir, this.opts.cursorDir);
      baseArgs = [...baseArgs, ...aug.args];
      launchEnv = { ...launchEnv, ...aug.env };
      notificationsInjected = aug.notificationsInjected;
      if (entry.tool === "github-copilot" || entry.tool === "codex") {
        launchEnv = { ...launchEnv, ANTGRID_TERMINAL_ID: id };
      }
      // Resume the slot's last-active conversation (held in resumeArgs, appended
      // LAST in the spawn block so it lands after any per-session args — required
      // for codex's `resume` subcommand).
      resumeArgs = this.resumeArgsFor(entry.tool, entry);
    } else if (entry.command) {
      // Custom command lines never resume and get no per-spawn hooks: the user
      // owns the whole line, so we don't inject title/resume integration and no
      // agentSessionId is ever captured for them.
      base = entry.command;
      isCustomLine = true;
    } else {
      base = sessionAgentSpec.command;
      baseArgs = sessionAgentSpec.args ?? [];
      // The antgrid.yaml default spec gets per-spawn hooks + resume only for
      // agents whose augmenter needs it; other default agents launch bare.
      if (sessionAgentSpec.name === "github-copilot" || sessionAgentSpec.name === "cursor-agent") {
        const aug = augmentAgentLaunch(sessionAgentSpec.name, this.opts.storeDir, this.opts.cursorDir);
        baseArgs = [...baseArgs, ...aug.args];
        launchEnv = { ...launchEnv, ...aug.env, ANTGRID_TERMINAL_ID: id };
        notificationsInjected = aug.notificationsInjected;
        resumeArgs = this.resumeArgsFor(sessionAgentSpec.name, entry);
      }
    }
    if (!base) {
      // No per-session spec and the first-run wizard hasn't supplied an
      // agent.tool/command yet (placeholder `{command:""}`); refuse rather
      // than spawning a default shell.
      throw new Error("agent.tool or agent.command not configured");
    }

    // One-shot first prompt, appended LAST (after resume tokens — codex's
    // `resume <uuid>` is a subcommand and the positional prompt must follow it).
    const promptArgs = isCustomLine
      ? []
      : initialPromptArgv(entry.tool ?? sessionAgentSpec.name, initialPrompt ?? "");

    // No per-session args: spawn `base` with its default argv (the antgrid.yaml
    // flags on the fallback path, empty otherwise) — preserves no-shell direct
    // exec. With per-session args, fold base + default flags + args into one
    // shell command line (the documented shell-semantics tradeoff) and let
    // terminal-session split it. The resolved executable and config-supplied
    // flags are shell-quoted so spaces in a path/value don't mis-split; the
    // custom line and the user's raw args string keep full shell semantics.
    // The initial prompt is a single opaque argument that may carry newlines
    // (Shift+Enter in the composer). A raw newline folded into a `cmd.exe /c`
    // command line terminates the command mid-launch, so on win32 the prompt
    // must travel as a DISCRETE argv element — terminal-session's cmd.exe shell
    // path appends spawn args after the `/c <line>` intact. POSIX's `sh -c
    // <line>` ignores trailing argv, so there the prompt folds into the line
    // instead (single-quoting via shellQuoteArg preserves any newlines).
    const foldPromptIntoLine = process.platform !== "win32";
    const argsStr = entry.args?.trim();
    let command = base;
    if (argsStr) {
      const head = isCustomLine
        ? [base]
        : [shellQuoteArg(base), ...baseArgs.map(shellQuoteArg)];
      // Codex's `resume <uuid>` is a subcommand and must follow user/global
      // flags. Other agents' resume switches go before raw args so a user `--`
      // boundary cannot swallow them.
      const resumeAfterRaw = (entry.tool ?? sessionAgentSpec.name) === "codex";
      const beforeRaw = resumeAfterRaw ? [] : resumeArgs.map(shellQuoteArg);
      const afterRaw = resumeAfterRaw ? resumeArgs.map(shellQuoteArg) : [];
      const foldedPrompt = foldPromptIntoLine ? promptArgs.map(shellQuoteArg) : [];
      command = [...head, ...beforeRaw, argsStr, ...afterRaw, ...foldedPrompt].join(" ");
    }
    // With per-session args folded into `command`, spawnArgs is normally []; on
    // win32 the un-foldable prompt rides here as discrete argv (appended LAST,
    // after the folded line, mirroring the fold order).
    const spawnArgs = argsStr
      ? foldPromptIntoLine
        ? []
        : [...promptArgs]
      : [...baseArgs, ...resumeArgs, ...promptArgs];

    // Spawn at default 80x24. The app's first `terminal:resize` (sent by the
    // viewed terminal once its cell metrics settle and it claims driver)
    // corrects the geometry within a frame or two — TUI agents (claude-code,
    // codex…) handle the SIGWINCH transparently. Earlier revisions deferred the
    // spawn until terminal:resize arrived, but that produced a chicken-and-egg
    // deadlock: the tab never mounts without a PTY, so the resize never
    // fires, so the PTY never spawns.
    this.tm.spawn({
      terminalId: id,
      name: entry.name,
      command,
      args: spawnArgs, // [] when args were folded into `command`; default flags otherwise
      cwd: sessionAgentSpec.workingDir ? resolve(checkoutPath, sessionAgentSpec.workingDir) : checkoutPath,
      cols: 80,
      rows: 24,
      type: "agent",
      env: Object.keys(launchEnv).length ? launchEnv : undefined,
      // Spec intent AND this spawn's injection outcome, both decided in
      // known-agents.ts: notificationsInjected===false means the plugin channel
      // this spawn depends on (e.g. cursor-agent's hooks.json) failed to write,
      // so the OSC scanner stays live rather than silently muting the session.
      suppressOscNotifications: suppressesOscNotifications(
        entry.tool ?? sessionAgentSpec.name,
        notificationsInjected,
      ),
      suppressOscTitle: suppressesOscTitle(
        entry.tool ?? sessionAgentSpec.name,
        notificationsInjected,
      ),
      expectsHookAliveProbe:
        injectsHookAliveProbe(entry.tool ?? sessionAgentSpec.name),
    });
    entry.lastUsedAt = Date.now();
    this.changed();
  }

  /** Initiates teardown; it is NOT complete when this returns. The chat branch
   *  hands back the driver's teardown promise so a caller that restarts this
   *  slot on another runtime can wait it out (see stopAndAwait); every existing
   *  caller ignores it, exactly as before. */
  stop(id: string): void | Promise<void> {
    const entry = this.entries.get(id);
    if (entry?.mode === "chat") {
      this.runningChat.delete(id);
      const torndown = this.opts.onStopChat?.(id);
      this.changed();
      return torndown;
    }
    if (!this.tm.has(id)) return;
    this.tm.kill(id);
    this.changed();
  }

  /**
   * Switch a session between the PTY and the structured-driver runtime,
   * restarting it in place when it was running. The agent-native conversation
   * carries over: both runtimes read and write the same `agentSessionId`.
   *
   * Async because `stop()` only INITIATES teardown, and the old runtime's
   * completion callbacks are keyed by session id — start the new runtime inline
   * and the dead one's teardown lands on it (the handler disarm on the PTY side,
   * the agent's own process lock on the driver side).
   */
  async setMode(id: string, mode: "terminal" | "chat"): Promise<void> {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    if (entry.archived) throw new Error(`cannot switch archived session: ${id}`);
    if (entry.mode === mode) return;
    if (mode === "chat" && !isChatCapableTool(entry.tool)) {
      throw new Error(`tool has no chat driver: ${entry.tool}`);
    }
    // Read with the OLD mode — the same expression toWire uses.
    const wasRunning = entry.mode === "chat" ? this.runningChat.has(id) : this.tm.has(id);
    // Held across the teardown only: the exit-driven handler teardown fires
    // inside the await below, and this is what tells it the session outlives
    // the runtime it is losing.
    this.flipping.set(id, (this.flipping.get(id) ?? 0) + 1);
    try {
      return await this.setModeInner(id, mode, entry, wasRunning);
    } finally {
      const left = (this.flipping.get(id) ?? 1) - 1;
      if (left > 0) this.flipping.set(id, left);
      else this.flipping.delete(id);
    }
  }

  /** True while this session is swapping runtimes, i.e. the teardown now in
   *  flight is a mode flip and not the session going away. */
  isFlipping(id: string): boolean {
    return this.flipping.has(id);
  }

  private async setModeInner(
    id: string,
    mode: "terminal" | "chat",
    entry: PersistedEntry,
    wasRunning: boolean,
  ): Promise<void> {
    if (wasRunning && !(await this.stopAndAwait(id))) {
      // Teardown never landed. Leave `mode` untouched: the session is now
      // stopped in its original mode, which is exactly the post-session:stop
      // state, and the caller can retry.
      throw new Error(`${TEARDOWN_TIMEOUT_ERROR}: ${id}`);
    }
    // Strictly between the stop and the start: both branch on entry.mode, so a
    // flip before the stop tears down the wrong runtime (orphaning a live PTY)
    // and a flip after the start would have started the wrong one.
    const previous = entry.mode;
    entry.mode = mode;
    this.changed();
    if (!wasRunning) return;
    try {
      await this.start(id); // never an initialPrompt — this is a restart
    } catch (err) {
      // A spawn that threw leaves no runtime, so an entry left describing the
      // target mode would contradict the ok:false the caller is about to get.
      entry.mode = previous;
      this.changed();
      // Tagged, not rethrown bare: the old runtime is already gone, so this is
      // one of the two refusals that leaves the session STOPPED. Untagged it
      // reads to the app as an ordinary refusal ("nothing changed"), which
      // would leave the user with a dead session and no reason to restart it.
      throw new Error(`${RESTART_FAILED_ERROR}: ${id}: ${err}`);
    }
  }

  /** Stop the session and resolve once the runtime it was on is really gone.
   *  The completion signal differs per runtime: a PTY reports through its exit
   *  handler, a driver through the promise its dispose returns. */
  private stopAndAwait(id: string): Promise<boolean> {
    const timeoutMs = this.opts.teardownTimeoutMs ?? TEARDOWN_TIMEOUT_MS;
    const wasChat = this.entries.get(id)?.mode === "chat";
    const torndown = this.stop(id);
    if (!wasChat) return this.awaitTerminalExit(id, timeoutMs);
    // No chat bridge wired (or nothing to dispose): there is no later signal.
    if (!torndown) return Promise.resolve(true);
    return new Promise<boolean>((resolve, reject) => {
      const timer = setTimeout(() => resolve(false), timeoutMs);
      torndown.then(
        () => { clearTimeout(timer); resolve(true); },
        (err) => { clearTimeout(timer); reject(err); },
      );
    });
  }

  /**
   * Resolve once this session's PTY is really gone, or false if it hasn't gone
   * within `timeoutMs`.
   *
   * `TerminalManager.kill()` is fire-and-forget — it signals the process and
   * leaves removal to the exit handler, which lands on `noteExited()` some time
   * later along with the exit-driven teardown in agent-core (handler disarm,
   * namer forget). A caller that starts another runtime on this slot must let
   * that teardown land first, or it arrives on the runtime that just started.
   *
   * The wait is bounded because a wedged PTY must not hang its caller forever;
   * false means the caller's own state is still whatever a plain stop() left.
   */
  awaitTerminalExit(id: string, timeoutMs: number): Promise<boolean> {
    // No live PTY: the exit that would resolve a waiter has already happened
    // (terminal-manager drops the session in the same handler that calls
    // noteExited), so there is nothing left to wait for.
    if (!this.tm.has(id)) return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const settle = (exited: boolean): void => {
        clearTimeout(timer);
        const waiters = this.terminalExitWaiters.get(id);
        if (waiters) {
          waiters.delete(settle);
          if (waiters.size === 0) this.terminalExitWaiters.delete(id);
        }
        resolve(exited);
      };
      let waiters = this.terminalExitWaiters.get(id);
      if (!waiters) {
        waiters = new Set();
        this.terminalExitWaiters.set(id, waiters);
      }
      waiters.add(settle);
      timer = setTimeout(() => settle(false), timeoutMs);
    });
  }

  /** Called when the underlying PTY exits (regardless of stop() vs crash). */
  noteExited(id: string): void {
    const waiters = this.terminalExitWaiters.get(id);
    if (waiters) {
      // Drop the set before firing so a waiter's own cleanup can't mutate what
      // we're iterating, and a re-registration lands in a fresh set.
      this.terminalExitWaiters.delete(id);
      for (const settle of waiters) settle(true);
    }
    if (!this.entries.has(id)) return;
    this.changed();
  }

  onChange(fn: () => void): () => void {
    this.observers.add(fn);
    return () => { this.observers.delete(fn); };
  }

  flushNow(): void {
    // Either timer being armed means a write is pending. Disarm both (a stray
    // timer must not outlive teardown and keep the event loop alive) and do a
    // single final write so the last activity bump survives. The activity
    // timer's wire emit is intentionally dropped — peers re-read persisted
    // lastUsedAt on reconnect.
    const dirty = this.flushTimer !== null || this.activityEmitTimer !== null;
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    if (this.activityEmitTimer) {
      clearTimeout(this.activityEmitTimer);
      this.activityEmitTimer = null;
    }
    if (dirty) this.flush();
  }

  /** Transaction commit for an isolated creation. Unlike flushNow(), this never
   * swallows an I/O error and it writes even when no debounce timer was armed. */
  private async flushNowOrThrow(): Promise<void> {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
    if (this.activityEmitTimer) {
      clearTimeout(this.activityEmitTimer);
      this.activityEmitTimer = null;
    }
    await mkdir(this.dir, { recursive: true });
    await writePersistedAtomic(this.path, Array.from(this.entries.values()));
  }

  /** Absolute paths, and relative paths that escape the checkout, would make a
   * session advertised as isolated execute in the shared repository. */
  private assertSafeWorkingDir(checkoutPath: string, workingDir?: string): void {
    if (!workingDir) return;
    if (isAbsolute(workingDir)) {
      throw new WorktreeError("WORKTREE_WORKING_DIR_UNSAFE", "agent.workingDir must be relative to the isolated checkout.");
    }
    const target = resolve(checkoutPath, workingDir);
    const rel = relative(checkoutPath, target);
    if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new WorktreeError("WORKTREE_WORKING_DIR_UNSAFE", "agent.workingDir escapes the isolated checkout.");
    }
  }

  // --- internals ---

  // `agentTranscriptPath` is deliberately withheld: it's a local filesystem path
  // no client consumes. `agentSessionId` IS carried — the app gates chat
  // transcript hydration on it (see the app's hydrateAttachedChatIfNeeded), so
  // withholding it leaves a session started on another device rendering empty.
  private toWire(e: PersistedEntry): SessionEntry {
    return {
      id: e.id,
      name: e.name,
      createdAt: e.createdAt,
      lastUsedAt: e.lastUsedAt,
      archived: e.archived,
      running: this.isRunning(e),
      tool: e.tool,
      command: e.command,
      args: e.args,
      mode: e.mode,
      agentSessionResumable: this.agentSessionResumable(e),
      // Read from the owning core's reduction (work-status.ts), never folded
      // here: one per-session reduction, not two that can disagree. Undefined
      // for a session that isn't running — the reduction only files a status for
      // live sessions — which reaches the app as "the bridge didn't say", and is
      // right: a mode flip does not restart a stopped session, so there is
      // nothing to warn about.
      workStatus: this.opts.sessionWorkStatusFor?.(e.id),
      agentSessionId: e.agentSessionId,
      checkoutId: e.checkoutId,
      checkoutKind: e.checkoutKind,
      checkoutBranch: e.checkoutBranch,
      checkoutState: e.checkoutState,
    };
  }

  /** Whether this slot's runtime is live — a PTY for terminal mode, the driver
   *  bookkeeping for chat, since a chat session has no PTY to ask. */
  private isRunning(e: PersistedEntry): boolean {
    return e.mode === "chat" ? this.runningChat.has(e.id) : this.tm.has(e.id);
  }

  /**
   * The tool whose resume argv a start() of this entry would actually use, or
   * undefined when this entry never resumes. Mirrors start()'s three branches:
   * a per-session tool resumes, a custom command line never does (the user owns
   * the whole line), and the antgrid.yaml default spec only gets resume wiring
   * for the agents whose augmenter needs it.
   */
  private resumeToolFor(e: PersistedEntry): string | undefined {
    if (e.tool) return e.tool;
    if (e.command) return undefined;
    const name = this.agentSpec.name;
    return name === "github-copilot" || name === "cursor-agent" ? name : undefined;
  }

  /**
   * Whether this session's agent-native conversation could still be resumed —
   * the ONLY question this answers. Chat capability is deliberately excluded so
   * "this agent has no chat driver" and "this conversation is gone" reach the
   * app as two separable facts; see the field's comment in protocol.ts.
   *
   * An unset agentSessionId is true: nothing has been captured yet, so nothing
   * can be lost. The resume-argv clause is unreachable today (every chat-capable
   * agent resumes) and is kept as a fail-closed assertion for the first driver
   * added to an agent that cannot resume by id.
   */
  private agentSessionResumable(e: PersistedEntry): boolean {
    const tool = this.resumeToolFor(e);
    if (!tool || resumeArgv(tool, "x").length === 0) return false;
    if (e.agentSessionId === undefined) return true;
    const cached = this.resumableCache.get(e.id);
    if (cached && cached.agentSessionId === e.agentSessionId) return cached.resumable;
    const resumable = sessionResumable({
      tool,
      agentSessionId: e.agentSessionId,
      agentTranscriptPath: e.agentTranscriptPath,
      codexHome: this.opts.codexHome,
      copilotHome: this.opts.copilotHome,
    });
    this.resumableCache.set(e.id, { agentSessionId: e.agentSessionId, resumable });
    return resumable;
  }

  private nextDefaultName(): string {
    let max = 0;
    for (const e of this.entries.values()) {
      const m = /^Session (\d+)$/.exec(e.name);
      if (m) {
        const n = parseInt(m[1], 10);
        if (n > max) max = n;
      }
    }
    return `Session ${max + 1}`;
  }

  private changed(): void {
    this.scheduleFlush();
    this.notifyObservers();
  }

  private notifyObservers(): void {
    for (const fn of this.observers) {
      try { fn(); } catch { /* ignore */ }
    }
  }

  /** Leading-coalesce the activity emit: the first touch in a window arms a
   *  timer that fires one session:updated (and one persist); touches during
   *  the window ride it. */
  private scheduleActivityEmit(): void {
    if (this.activityEmitTimer) return;
    this.activityEmitTimer = setTimeout(() => {
      this.activityEmitTimer = null;
      this.scheduleFlush();
      this.notifyObservers();
    }, ACTIVITY_EMIT_DEBOUNCE_MS);
  }

  private load(): void {
    let raw: string | null = null;
    try {
      if (existsSync(this.path)) raw = readFileSync(this.path, "utf8");
    } catch (err) {
      log.warn("sessions.json unreadable, treating as empty: %s", err);
    }
    for (const e of parsePersistedContent(raw)) this.entries.set(e.id, e);
  }

  private scheduleFlush(): void {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flush();
    }, FLUSH_DEBOUNCE_MS);
  }

  private flush(): void {
    try {
      if (!existsSync(this.dir)) mkdirSync(this.dir, { recursive: true });
      const data: FileShape = {
        version: 1,
        sessions: Array.from(this.entries.values()),
      };
      const tmp = `${this.path}.tmp`;
      writeFileSync(tmp, JSON.stringify(data, null, 2));
      renameSync(tmp, this.path);
      if (process.platform !== "win32") {
        try { chmodSync(this.path, 0o600); } catch { /* ignore */ }
      }
    } catch (err) {
      log.error("failed to persist sessions.json: %s", err);
    }
  }
}
