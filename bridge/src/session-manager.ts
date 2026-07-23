import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { readFile, writeFile, rename, chmod } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import { logger } from "./logger";
const log = logger.child({ component: "session-manager" });
import { resolveAgent, resolveAgentEnv, notificationSourceFor, titleSourceFor } from "./known-agents";
import { augmentAgentLaunch, injectsHookAliveProbe } from "./agent-launch-augmenter";
import { resumeArgv, sessionResumable } from "./agent-resume";
import { initialPromptArgv } from "./initial-prompt";
import type { TerminalManager } from "./terminal-manager";
import type { SessionEntry } from "./protocol";

interface AgentSpec {
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

interface SessionManagerOpts {
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
  /** Override for the codex thread store dir (resume pre-flight). Unset in
   *  production → defaults to ~/.codex; tests inject an isolated dir. */
  codexHome?: string;
  /** Override for the Copilot session store dir (resume pre-flight). */
  copilotHome?: string;
  /** Called by start()/stop() for a mode:'chat' session instead of the PTY path.
   *  Injected by agent-core to drive the StructuredAgentManager. */
  onStartChat?: (opts: { sessionId: string; tool: string; resumeId?: string; config?: Record<string, string>; initialPrompt?: string }) => void;
  onStopChat?: (sessionId: string) => void;
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
  // (claude/gemini/qwen). Used for the pre-flight existence check. Codex/
  // opencode don't post a path.
  agentTranscriptPath?: string;
  // Session-scoped structured-driver selections keyed by the wire config key the
  // app sent via agent:set-config (`model` | `effort` | `mode`), overwrite-latest
  // per key. Persisted-only — never on the wire (SessionEntry). Replayed through
  // driver.setConfig() on start so a restart restores the last-picked
  // model/mode/effort instead of reverting to the backend default.
  config?: Record<string, string>;
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
        agentSessionId: e.agentSessionId,
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

  create(name?: string, spec?: SessionLaunchSpec): SessionEntry {
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
    };
    // A new chat session inherits the last-used selection for its tool so it
    // opens on the model/mode/effort the user actually works with, not the
    // backend default. Terminal sessions and tool-less entries get nothing.
    if (entry.mode === "chat" && entry.tool) {
      const inherited = this.lastUsedConfigForTool(entry.tool);
      if (inherited) entry.config = inherited;
    }
    this.entries.set(id, entry);
    this.changed();
    return this.toWire(entry);
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
    // session — e.g. gemini's SessionStart fires before the transcript path is
    // known, then a later AfterAgent supplies it. A new session id resets it.
    const nextPath =
      agentSessionId === entry.agentSessionId
        ? (agentTranscriptPath ?? entry.agentTranscriptPath)
        : agentTranscriptPath;
    if (entry.agentSessionId === agentSessionId && entry.agentTranscriptPath === nextPath) {
      return; // unchanged — avoid a redundant flush/emit
    }
    entry.agentSessionId = agentSessionId;
    entry.agentTranscriptPath = nextPath;
    this.changed();
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

  /** Remove a session. Returns whether a row was actually present, so the
   *  control-plane delete reports the same `deleted` truthiness as the
   *  stopped-core path (deletePersisted) — a missing id is false either way. */
  delete(id: string): boolean {
    const entry = this.entries.get(id);
    if (!entry) return false;
    if (this.tm.has(id)) this.tm.kill(id);
    this.entries.delete(id);
    this.changed();
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
    this.changed();
    return [];
  }

  start(id: string, initialPrompt?: string): void {
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
      const aug = augmentAgentLaunch(entry.tool, this.opts.storeDir);
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
      base = this.agentSpec.command;
      baseArgs = this.agentSpec.args ?? [];
      // The antgrid.yaml default spec gets per-spawn hooks + resume only for
      // agents whose augmenter needs it; other default agents launch bare.
      if (this.agentSpec.name === "github-copilot" || this.agentSpec.name === "cursor-agent") {
        const aug = augmentAgentLaunch(this.agentSpec.name, this.opts.storeDir);
        baseArgs = [...baseArgs, ...aug.args];
        launchEnv = { ...launchEnv, ...aug.env, ANTGRID_TERMINAL_ID: id };
        notificationsInjected = aug.notificationsInjected;
        resumeArgs = this.resumeArgsFor(this.agentSpec.name, entry);
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
      : initialPromptArgv(entry.tool ?? this.agentSpec.name, initialPrompt ?? "");

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
      const resumeAfterRaw = (entry.tool ?? this.agentSpec.name) === "codex";
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
      cwd: this.agentSpec.workingDir ?? this.projectPath,
      cols: 80,
      rows: 24,
      type: "agent",
      env: Object.keys(launchEnv).length ? launchEnv : undefined,
      // notificationsInjected===false means the plugin channel this spawn
      // depends on (e.g. cursor-agent's hooks.json) failed to write — keep the
      // OSC scanner live rather than silently muting the session.
      suppressOscNotifications:
        notificationSourceFor(entry.tool ?? this.agentSpec.name) === "plugin" &&
        notificationsInjected !== false,
      // Same fail-open guard, for the title signal. notificationsInjected is
      // reused here (not a separate flag) because for every "structured"
      // titleSource agent, the title-correlation hook ships in the SAME
      // materialized plugin/hooks file as the notification hook (see
      // agent-launch-augmenter.ts) — one write, one success/failure signal.
      suppressOscTitle:
        titleSourceFor(entry.tool ?? this.agentSpec.name) === "structured" &&
        notificationsInjected !== false,
      expectsHookAliveProbe:
        injectsHookAliveProbe(entry.tool ?? this.agentSpec.name),
    });
    entry.lastUsedAt = Date.now();
    this.changed();
  }

  stop(id: string): void {
    const entry = this.entries.get(id);
    if (entry?.mode === "chat") {
      this.runningChat.delete(id);
      this.opts.onStopChat?.(id);
      this.changed();
      return;
    }
    if (!this.tm.has(id)) return;
    this.tm.kill(id);
    this.changed();
  }

  /** Called when the underlying PTY exits (regardless of stop() vs crash). */
  noteExited(id: string): void {
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
      running: e.mode === "chat" ? this.runningChat.has(e.id) : this.tm.has(e.id),
      tool: e.tool,
      command: e.command,
      args: e.args,
      mode: e.mode,
      agentSessionId: e.agentSessionId,
    };
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
