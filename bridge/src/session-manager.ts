import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
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
import { agentSpec } from "./agents/registry";
// Aliased: this module declares its own, unrelated `AgentSpec` (the launch
// triple) right below.
import type { AgentSpec as RegistryAgentSpec } from "./agents/types";
import { stripAnsi } from "./handler/context";
import { resumeArgv, sessionResumable } from "./agent-resume";
import { isChatCapableTool } from "./structured/chat-capable";
import { initialPromptArgv } from "./initial-prompt";
import { TITLE_RANKS, titleRankValue, type TitleRank } from "./session-namer";
import type { WorkStatus } from "./protocol";
import type { TerminalManager } from "./terminal-manager";
import type { AbMessage, SessionEntry } from "./protocol";
import {
  CHECKOUT_KINDS,
  CHECKOUT_STATES,
  DURABLE_SETUP_STATES,
  isIsolatedCheckoutKind,
  isManagedCheckoutKind,
  type CheckoutKind,
  type CheckoutRecord,
  type CheckoutSetupProgress,
  type CheckoutState,
  type DurableSetupState,
  type SetupState,
} from "./worktrees/checkout-types";
import { CheckoutStore } from "./worktrees/checkout-store";
import { WorktreeError, type WorktreeManager } from "./worktrees/worktree-manager";
import { logWorktreeEvent, worktreeErrorCode } from "./worktrees/worktree-log";
import { createKeyedLock } from "./keyed-lock";
import { atomicWriteFile } from "./discovery";
import { runGit } from "./worktrees/project-resolver";

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

export type ForkWorkspace = "copy" | "current";

// The handoff is deliberately bounded before any durable row or worktree is
// created. A fork must preserve context, never silently trim a conversation.
export const MAX_FORK_TRANSCRIPT_BYTES = 128 * 1024;

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
  /** Construct the checkout-scoped runtime before a session can commit.
   *  `deferServices` still starts watchers, port detection and tunnels but
   *  holds the `services` block: auto-starting `bun run dev` against a worktree
   *  whose `node_modules` has not been provisioned yet is a guaranteed failure
   *  the user then has to read past. `startDeferredServices` releases them. */
  prepareCheckoutRuntime?: (checkout: CheckoutRecord, opts?: { deferServices?: boolean }) => Promise<void>;
  /** Release the `services` a `deferServices` preparation held back. */
  startDeferredServices?: (checkoutId: string) => Promise<void>;
  /** Kick off `worktree.setup` for a freshly cut managed checkout. Returns void
   *  rather than a promise on purpose: createWorktree must have replied and
   *  announced before this runs, and must never wait on it. Coarse transitions
   *  come back through `onProgress`; the live transcript is the setup
   *  terminal's own output. */
  runCheckoutSetup?: (
    checkout: CheckoutRecord,
    sessionId: string,
    onProgress: (progress: CheckoutSetupProgress) => void,
  ) => void;
  /** Kill a running setup's process tree and await it. Awaited before a managed
   *  checkout is removed: on Windows a live `bun install` holding the worktree
   *  as its cwd makes `git worktree remove` fail. */
  cancelCheckoutSetup?: (checkoutId: string) => Promise<void>;
  /** Whether this checkout has a `worktree.setup` block AT ALL, answered from
   *  its own antgrid.yaml. Read once per managed checkout on load, and only to
   *  keep "died mid-run" apart from "never had a run": every checkout cut before
   *  this feature shipped carries no marker either, and reporting those as
   *  `interrupted` puts a "Setup didn't finish" banner on every isolated session
   *  the user already had. Unanswerable (an unreadable config) reads as true, so
   *  the doubt surfaces rather than hides. */
  checkoutDeclaresSetup?: (checkout: CheckoutRecord) => boolean;
  /** Re-push the checkout's workspace state AFTER the session is announced.
   *  `prepareCheckoutRuntime` emits it too, but nothing replays a push frame
   *  and at that point no app knows the checkout exists — so its subscriber
   *  does not exist either, and the state (project name, git branch, commands)
   *  is lost until an unrelated event happens to re-emit. A terminal session
   *  hides that behind its own traffic; a chat session never does. */
  announceCheckoutRuntime?: (checkoutId: string) => void;
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
  // Which signal produced the current `name`, absent for a default name or one
  // derived from the terminal's OSC chrome. Durable because SessionNamer's copy
  // of the same precedence dies with the PTY: without it every restart lets the
  // per-turn first-message read rename the session back to its opening prompt,
  // and lets the naming gate spend another model spawn re-titling a session that
  // already has a real title. Released when a NEW conversation takes the slot —
  // see noteConversationStart and setAgentSession.
  autoTitleRank?: TitleRank;
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
  checkoutKind: CheckoutKind;
  checkoutBranch?: string | null;
  checkoutState: CheckoutState;
  /** A one-shot normalized conversation handoff, deleted after first launch. */
  forkTranscript?: string;
  /** One-shot provider-native fork argv; never reaches the client. */
  forkNativeArgs?: string[];
  /** Whether `forkNativeArgs` has already been spawned once. Bounds the wait
   *  for a provider identity that a mismatched CLI never reports. */
  forkNativeAttempted?: boolean;
  conversationStart?: "fresh" | "resume" | "fork";
  /** The session `fork()` copied this one from. Provenance, not a link: the
   *  source may be renamed, archived or deleted, and nothing resolves it back.
   *  It is what still answers "forked from what" once the derived name below
   *  has been renamed away on either side. */
  forkedFromSessionId?: string;
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
    autoTitleRank: z.enum(TITLE_RANKS).optional().catch(undefined),
    agentSessionId: z.string().optional().catch(undefined),
    agentTranscriptPath: z.string().optional().catch(undefined),
    config: z.record(z.string(), z.string()).optional().catch(undefined),
    checkoutId: z.string().optional().catch(undefined),
    checkoutKind: z.enum(CHECKOUT_KINDS).optional().catch(undefined),
    checkoutBranch: z.string().nullable().optional().catch(undefined),
    checkoutState: z.enum(CHECKOUT_STATES).optional().catch(undefined),
    forkTranscript: z.string().optional().catch(undefined),
    forkNativeArgs: z.array(z.string()).optional().catch(undefined),
    forkNativeAttempted: z.boolean().optional().catch(undefined),
    conversationStart: z.enum(["fresh", "resume", "fork"]).optional().catch(undefined),
    forkedFromSessionId: z.string().optional().catch(undefined),
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
      manuallyRenamed: s.manuallyRenamed ?? !isDefaultSessionName(s.name),
      // Deliberately NOT backfilled from the name: a file written before this
      // field existed cannot say whether its name was generated or read off the
      // opening prompt, and guessing "generated" would freeze every one of them
      // against ever being named properly. Absent means "behave as before" —
      // the rank starts describing the name from the next title that lands.
      autoTitleRank: s.autoTitleRank,
      agentSessionId: s.agentSessionId,
      agentTranscriptPath: s.agentTranscriptPath,
      config: s.config,
      checkoutId: s.checkoutId ?? "main",
      // Resolved together: a row whose checkoutId was lost (truncated write,
      // hand edit) but whose kind survived would otherwise claim to be a
      // managed worktree living in the primary tree, and the delete path would
      // route it to deleteManaged with `main` as the checkout to reclaim.
      checkoutKind: s.checkoutId ? (s.checkoutKind ?? "main") : "main",
      checkoutBranch: s.checkoutBranch,
      checkoutState: s.checkoutState ?? "ready",
      forkTranscript: s.forkTranscript,
      forkNativeArgs: s.forkNativeArgs,
      forkNativeAttempted: s.forkNativeAttempted,
      conversationStart: s.conversationStart ?? (s.agentSessionId ? "resume" : "fresh"),
      forkedFromSessionId: s.forkedFromSessionId,
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

/** The ONE publish primitive for sessions.json — every writer in this file goes
 *  through it, so there is a single scratch-name and rename-retry policy for the
 *  file. tmp + rename means a crash mid-write can never truncate it (which
 *  load()/readPersisted would then read as empty and silently drop every
 *  session).
 *
 *  It must never suspend, and that — not the lock — is what makes it safe. An
 *  await between writing the scratch file and renaming it is a window another
 *  writer lands in: the two would rename past each other and publish a blend.
 *  Being synchronous, it occupies one turn and nothing can interleave with it.
 *
 *  Do NOT make it take `withSessionsFile` itself. flushNow() reaches it off the
 *  lock on purpose (see there), so the lock is not an invariant it could restore
 *  — and createKeyedLock is not reentrant, so acquiring the key its two awaited
 *  callers already hold would hang every isolated-session create and every cold
 *  delete, permanently and with no error. */
function writePersistedAtomic(path: string, sessions: PersistedEntry[]): void {
  const file: FileShape = { version: 1, sessions };
  atomicWriteFile(path, JSON.stringify(file, null, 2), { fileMode: 0o600 });
}

/** Serializes the sessions.json writers that SUSPEND, keyed on the absolute file
 *  path — deletePersisted's read-modify-write, and the debounced flush queued
 *  behind it. It is deliberately not "every publish": flushNow() writes off the
 *  lock (see there), which is safe only because writePersistedAtomic occupies a
 *  single turn.
 *
 *  Module-level rather than per-instance because the static deletePersisted has
 *  no instance, and host-server can briefly hold two SessionManagers for one
 *  project across an evict/reopen. Nothing slow may ever be held under it —
 *  flushNowOrThrow sits on the isolated-create path the app waits on — and
 *  nothing may acquire withCheckoutMembership from inside it, since that lock is
 *  already held across flushNowOrThrow in the other order. */
const withSessionsFile = createKeyedLock();

/** True for an unedited default slot name ("Session 3") — one the user never
 *  named. Gates the auto-name backfill (a non-default name was user-chosen) and
 *  the OSC placeholder guard (the "Antigravity" fallback may only label a
 *  still-default slot, never overwrite a resolved name). */
export function isDefaultSessionName(name: string): boolean {
  return /^Session \d+$/.test(name);
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

/** A session's `worktree.setup` run. Runtime-only, deliberately absent from
 *  PersistedEntry: only the OUTCOME reaches disk (checkouts.json), so a bridge
 *  that dies mid-run comes back reporting `interrupted` rather than a run that
 *  nothing on this launch is alive to finish. */
interface SetupRuntime {
  /** Tells this run apart from the one a `rerun` replaced, and from the dying
   *  report of a run a cancel already killed: neither may overwrite the state
   *  the user has since been shown. Zero for a state recovered from disk, which
   *  has no runner behind it at all. */
  runId: number;
  state: SetupState;
  stepIndex: number;
  stepCount: number;
  stepName?: string;
  terminalId?: string;
  exitCode?: number;
  message?: string;
  startedAt: number;
  finishedAt?: number;
  /** A start held behind this run. Never persisted — `initialPrompt` is
   *  one-shot launch state everywhere else too, and a bridge restart
   *  legitimately drops it (the session then sits stopped with a Start
   *  affordance). */
  pendingStart?: { initialPrompt?: string };
  /** The prompt the last queued start carried, kept after that start fired so a
   *  rerun can re-arm it. Under `onFailure: warn` every exit from `running`
   *  fires the queue, so a failed run has already spent its prompt on a tree
   *  the agent could not build in — carrying it forward is what makes
   *  re-run-setup → restart-agent not a retype. */
  lastQueuedPrompt?: string;
  /** Starts no longer queue behind this run. Separate from `state` because a
   *  skipped run KEEPS RUNNING and keeps reporting — releasing the gate is the
   *  whole of what Skip does. */
  gateReleased: boolean;
  /** This run's checkout was prepared with `deferServices`, so its `services:`
   *  block is this run's to release when it ends. A rerun never holds them:
   *  the first run already let them go. */
  holdsServices: boolean;
}

export class SessionManager {
  private entries = new Map<string, PersistedEntry>();
  /** Serializes attach, promotion and member removal for one checkout. */
  private readonly withCheckoutMembership = createKeyedLock();
  private observers = new Set<() => void>();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  /** A debounced flush whose timer has fired but whose write is still queued on
   *  `withSessionsFile`. Without it flushNow() reads a null flushTimer as "clean"
   *  and skips the final write on exactly the shutdown it exists to cover. */
  private flushQueued = false;
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
  /** Sessions whose managed delete is in flight, mapped to the checkout being
   *  removed. Transient and in-memory: it never reaches `toPersisted`, so a
   *  bridge that dies mid-delete comes back with an ordinary, deletable row
   *  rather than one permanently pending. It is the single source for BOTH the
   *  `deleting` wire flag and `isCheckoutDeleting` — one set, one lifetime, so
   *  the flag an app saw and the refusal it then gets can never disagree.
   *  Populated only by `deleteManaged`; any future checkout-removal path outside
   *  this class must flag itself here or it goes unguarded. A `null` value is a
   *  delete that reclaims NO checkout (detaching one member of a shared
   *  workspace) — the row still reports `deleting`, but `isCheckoutDeleting`
   *  must not refuse the siblings that keep working in that directory. */
  private readonly deleting = new Map<string, string | null>();
  // Memoized sessionResumable() answers, keyed by session id and tagged with the
  // agentSessionId they were computed for. toWire() runs per entry on every
  // changed() emit and the real check does existsSync + a bun:sqlite query, so
  // it must never reach that path. Invalidated whenever setAgentSession writes
  // something new; a stale `true` is harmless because start() re-runs the real
  // pre-flight and falls back to a fresh start.
  private resumableCache = new Map<string, { agentSessionId: string; resumable: boolean }>();
  /** Sessions launched to CONTINUE their previous conversation, until the agent
   *  reports the identity it continued under. Per-run and therefore in memory:
   *  a launch always precedes the report, and a bridge that died between them
   *  killed the run too. See noteConversationStart. */
  private readonly awaitingResumedIdentity = new Set<string>();
  /** Live and recovered `worktree.setup` state, keyed by session id. Runtime
   *  only — it reaches the wire through toWire and never sessions.json, which
   *  is also why every mutation here emits with notifyObservers() rather than
   *  changed(). */
  private readonly setups = new Map<string, SetupRuntime>();
  private nextSetupRunId = 1;

  constructor(private opts: SessionManagerOpts) {
    this.dir = join(opts.storeDir, "agents", opts.projectId);
    this.path = join(this.dir, "sessions.json");
    this.tm = opts.terminalManager;
    this.projectPath = opts.projectPath;
    this.agentSpec = opts.agentSpec;
    this.load();
    void this.recoverSetupStates().catch((err) => {
      log.warn("recovering checkout setup states failed: %s", err);
    });
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

  /** Whether any persisted session requires checkout-scoped workspace routing.
   *  This is the ROUTING question, not the ownership one — any checkout that is
   *  not main's working tree needs it, whoever created it, so it must stay on
   *  `isIsolatedCheckoutKind` even though every kind that answers true today is
   *  also one Antgrid created. */
  hasIsolatedSessions(): boolean {
    for (const entry of this.entries.values()) {
      if (isIsolatedCheckoutKind(entry.checkoutKind)) return true;
    }
    return false;
  }

  /** Whether a delete is currently tearing this checkout down. The ONLY read
   *  path for agent-core's dispatch guard: a checkout-variable verb answered
   *  while its worktree is being removed either races the removal for the
   *  directory (a sharing violation on Windows) or — worse — gets served from
   *  main's tree by `runtimeFor`'s fallback. `main` can never be flagged: only
   *  managed checkouts are deletable. */
  isCheckoutDeleting(checkoutId: string): boolean {
    // Asserted, not assumed: a row that answers `main` here would refuse every
    // checkout-variable verb in the project — file reads, git, keystrokes —
    // loopback included, for as long as the delete ran.
    if (checkoutId === "main") return false;
    if (this.deleting.size === 0) return false;
    for (const id of this.deleting.values()) {
      if (id === checkoutId) return true;
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
        // Like `running` above: the flag is in-memory on the warm core that owns
        // the delete, and this peek has no core to ask.
        deleting: false,
        tool: e.tool, command: e.command, args: e.args, mode: e.mode,
        // Pessimistic, unlike `agentSessionResumable` below: hiding a control
        // the live list then shows is recoverable; offering Fork on a cold peek
        // that cannot resolve the checkout's agent spec is a menu item that can
        // only fail.
        forkSupported: false,
        sharedWorkspace: false,
        workspaceMemberCount: 1,
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
    // The read and the write are one transaction: two deletes on the same cold
    // project overlap otherwise, and the second republishes the set it read
    // before the first landed — resurrecting a row the user already removed.
    return withSessionsFile(path, async () => {
      let raw: string | null = null;
      try {
        raw = await readFile(path, "utf8");
      } catch {
        return false; // missing/unreadable → nothing to delete
      }
      const entries = parsePersistedContent(raw);
      const next = entries.filter((e) => e.id !== sessionId);
      if (next.length === entries.length) return false; // id not present
      writePersistedAtomic(path, next);
      return true;
    });
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

  /** Create a fresh registry-agent conversation from bridge-owned context. */
  async fork(sourceSessionId: string, workspace: ForkWorkspace): Promise<SessionEntry> {
    const source = this.entries.get(sourceSessionId);
    if (!source) throw new Error(`session not found: ${sourceSessionId}`);
    if (source.command) throw new Error("Custom-command sessions cannot be forked.");
    const sourcePath = await this.checkoutPathForFork(source);
    const sourceAgentSpec = source.checkoutId === "main"
      ? this.agentSpec
      : await this.opts.resolveAgentSpec?.(source.checkoutId) ?? this.agentSpec;
    const tool = source.tool ?? sourceAgentSpec.name;
    const adapter = agentSpec(tool);
    if (!adapter) throw new Error("This session's agent does not support transcript forks.");
    const nativeForkArgs = source.mode === "terminal" && source.agentSessionId
      ? adapter.fork.nativeForkArgs?.(source.agentSessionId)
      : undefined;
    const transcript = nativeForkArgs?.length
      ? undefined
      : await this.captureForkTranscript(source, adapter, sourcePath);
    if (transcript && Buffer.byteLength(transcript, "utf8") > MAX_FORK_TRANSCRIPT_BYTES) {
      throw new Error("This conversation is too large to fork. Compact or summarize it first.");
    }

    // Never inherit raw command/args. A fork launches the registry default.
    const entry = this.buildEntry(undefined, { tool, mode: source.mode });
    // Named after its source rather than left as the next "Session N": what a
    // fork is FOR is that it came from somewhere, and the drawer row is where
    // the user reads that. Assigned here instead of passed to buildEntry so
    // `manuallyRenamed` stays false — a derived name is not a name the user
    // chose, and the agent's own conversation title must still win over it.
    entry.name = this.forkName(source.name);
    entry.forkedFromSessionId = source.id;
    entry.conversationStart = "fork";
    entry.forkTranscript = transcript;
    entry.forkNativeArgs = nativeForkArgs;
    if (workspace === "current") {
      return this.withCheckoutMembership(source.checkoutId, async () => {
        // Re-read under the membership lock: a concurrent delete may have
        // promoted or removed the source while transcript capture was pending.
        const liveSource = this.entries.get(sourceSessionId);
        if (!liveSource) throw new Error(`session not found: ${sourceSessionId}`);
        entry.checkoutId = liveSource.checkoutId;
        entry.checkoutKind = liveSource.checkoutKind;
        entry.checkoutBranch = liveSource.checkoutBranch;
        entry.checkoutState = liveSource.checkoutState;
        this.entries.set(entry.id, entry);
        try {
          await this.flushNowOrThrow();
        } catch (error) {
          this.entries.delete(entry.id);
          throw error;
        }
        this.notifyObservers();
        if (entry.checkoutId !== "main") this.reannounceCheckout(entry.checkoutId);
        return this.toWire(entry);
      });
    }

    return this.createWorktree(
      undefined,
      { tool, mode: source.mode, isolation: "worktree" },
      entry,
      // A thunk, not a value: an argument expression is evaluated before the
      // call, so resolving HEAD eagerly here would answer "no committed HEAD"
      // for a non-Git project that createWorktree's own preflight names
      // correctly as NOT_GIT_REPOSITORY.
      () => this.committedHead(sourcePath),
    );
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
      conversationStart: "fresh",
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

  private async checkoutPathForFork(source: PersistedEntry): Promise<string> {
    if (source.checkoutId === "main") return this.projectPath;
    const checkout = await this.opts.resolveCheckout?.(source.checkoutId);
    if (!checkout || !existsSync(checkout.path)) {
      throw new WorktreeError("WORKTREE_MISSING", "The source worktree is no longer available.");
    }
    return checkout.path;
  }

  /** The source checkout's HEAD, as an object id `git worktree add` can use.
   *  Through `runGit` like every other git call on this path: a synchronous
   *  spawn here blocks the one loop that is also forwarding every PTY and relay
   *  frame on the machine, for as long as process creation takes. Only the
   *  shape is checked — `resolveBase` re-verifies the value against the
   *  repository before it becomes a Git argument. */
  private async committedHead(path: string): Promise<string> {
    const head = await runGit(["rev-parse", "--verify", "HEAD"], path);
    // Any hex object id: a repository created with `--object-format=sha256`
    // answers 64 characters, and rejecting it would make its forks impossible.
    if (head.exitCode === 0 && /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(head.stdout.trim())) {
      return head.stdout.trim();
    }
    throw new WorktreeError("WORKTREE_CONFLICT", "The source checkout has no committed HEAD to copy.");
  }

  private async captureForkTranscript(source: PersistedEntry, adapter: RegistryAgentSpec, projectPath: string): Promise<string> {
    const scrollback = this.tm.getScrollback(source.id)?.text;
    const text = await adapter.fork.handoff({
      maxMsgs: 500,
      projectPath,
      agentSessionId: source.agentSessionId,
      transcriptPath: source.agentTranscriptPath,
      codexHome: this.opts.codexHome,
      // Stripped here, at the single point every adapter's terminal fallback
      // draws from: `getScrollback` is raw PTY output, and a TUI's tail is
      // mostly CSI/OSC redraw. It becomes an agent's opening prompt — and for
      // the no-argv agents it is typed back into a PTY, where those bytes read
      // as keys.
      terminalTranscript: scrollback ? stripAnsi(scrollback) : undefined,
    });
    if (!text.trim()) {
      throw new Error("This session has no captured transcript to fork yet.");
    }
    return text;
  }

  /**
   * Isolated creation deliberately has no visible session until all host-owned
   * state is usable and durable. The old synchronous shared API remains intact
   * for compatibility with pre-worktree callers; the wire handler always awaits
   * either result.
   */
  private async createWorktree(
    name: string | undefined,
    spec: SessionLaunchSpec,
    preparedEntry?: PersistedEntry,
    resolveBaseCommit?: () => Promise<string>,
  ): Promise<SessionEntry> {
    if (!this.opts.worktreeSessionsSupported || !this.opts.worktreeManager) {
      throw new WorktreeError("WORKTREE_UNSUPPORTED", "This bridge cannot isolate sessions yet.");
    }
    if (!await this.opts.isGitRepository?.()) {
      throw new WorktreeError("NOT_GIT_REPOSITORY", "This project is not a Git repository.");
    }
    const baseCommit = await resolveBaseCommit?.();
    const entry = preparedEntry ?? this.buildEntry(name, spec);
    let checkout: CheckoutRecord | undefined;
    let runtimePrepared = false;
    try {
      checkout = await this.opts.worktreeManager.prepareForSession({
        projectId: this.opts.projectId,
        repoPath: this.projectPath,
        sessionId: entry.id,
        sessionName: undefined, // new session won't have a name
        baseBranch: spec.baseBranch,
        baseCommit,
      });
      // Services are held back until setup finishes: auto-starting `bun run dev`
      // against a worktree whose `node_modules` has not been provisioned yet is
      // a guaranteed failure the user then has to read past. Watchers, port
      // detection and tunnels still come up now.
      // Asked of the CHECKOUT, not the project: the worktree is cut from a
      // commit, so the block that governs this session is the one on its own
      // branch. A checkout that declares none must take neither half of the
      // lifecycle — deferring services for a run that will never release them
      // strands the dev server, and stamping the `done` such a run reports
      // banners "Workspace ready" on a project that never opted in, on this
      // launch and (through recoverSetupStates) on every launch after it.
      const declaresSetup = !!this.opts.runCheckoutSetup
        && this.opts.checkoutDeclaresSetup?.(checkout) !== false;
      await this.opts.prepareCheckoutRuntime?.(checkout, { deferServices: declaresSetup });
      runtimePrepared = true;
      const checkoutSpec = await this.opts.resolveAgentSpec?.(checkout.id) ?? this.agentSpec;
      this.assertSafeWorkingDir(checkout.path, checkoutSpec.workingDir);
      entry.checkoutId = checkout.id;
      entry.checkoutKind = checkout.kind;
      // Provenance, not state: the branch Antgrid CREATED for this session. The
      // agent and the user are free to switch the checkout afterwards, and
      // nothing refreshes this — the live branch is a Git read against the
      // checkout path (`cachedGitBranch`), which is what the UI renders.
      entry.checkoutBranch = checkout.branch;
      entry.checkoutState = "ready";
      // Seeded before the commit so the entry the create reply carries already
      // says `running` — the app must never see an isolated session that looks
      // provisioned for the frame before the first progress lands.
      const setup = declaresSetup ? this.beginSetup(entry.id, true) : undefined;
      this.entries.set(entry.id, entry);
      await this.flushNowOrThrow();
      this.notifyObservers();
      // Strictly after the announce: the app builds this checkout's service
      // bundle from the session list, so anything pushed earlier lands with no
      // subscriber. Never fatal — the session itself is already committed.
      this.reannounceCheckout(checkout.id);
      // Last, and never awaited: the create reply is what the app is waiting on
      // (15 s), and a setup run takes minutes. The sub-millisecond gap after the
      // announce is deliberate — a runner frame sent before it has no subscriber.
      if (setup) {
        this.opts.runCheckoutSetup?.(checkout, entry.id,
          (progress) => this.onSetupProgress(entry.id, setup.runId, progress));
      }
      return this.toWire(entry);
    } catch (error) {
      this.entries.delete(entry.id);
      this.setups.delete(entry.id);
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
    // The name is the user's now, so it no longer describes any signal. Kept
    // honest rather than load-bearing: manuallyRenamed already refuses every
    // auto-name, and a rank left behind would outlive the title it described.
    entry.autoTitleRank = undefined;
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

  /**
   * Whether this slot already holds a name no model call should try to improve
   * on. The DURABLE twin of SessionNamer.hasFinalTitle, which holds nothing once
   * the PTY has exited — so this is the only thing that still knows, after a
   * restart, that the name on the row was generated rather than defaulted.
   */
  hasFinalAutoTitle(id: string): boolean {
    const entry = this.entries.get(id);
    return titleRankValue(entry?.autoTitleRank) >= titleRankValue("self");
  }

  applyAutoName(id: string, name: string, rank?: TitleRank): void {
    const entry = this.entries.get(id);
    if (!entry || entry.manuallyRenamed) return;
    // Precedence, restated here because SessionNamer's copy only spans one run:
    // the first-message read repeats the SAME opening prompt every turn and the
    // OSC signal is terminal chrome, so after a restart either would rename a
    // session we had already titled back to something worse.
    if (titleRankValue(rank) < titleRankValue(entry.autoTitleRank)) return;
    const trimmed = name.trim();
    if (!trimmed) return;
    // The rank travels with the name it describes, so an unchanged name still
    // writes when the signal behind it strengthened.
    if (trimmed === entry.name && rank === entry.autoTitleRank) return;
    entry.name = trimmed;
    entry.autoTitleRank = rank;
    this.changed();
  }

  /**
   * Record whether this launch continues the slot's previous conversation, and
   * release the generated title when it does not.
   *
   * A continuation cannot be recognized from the agent's session id afterwards:
   * measured on Claude Code, `--resume` copies the transcript into a new file
   * and appends under a FRESH id, so the same thread comes back wearing a
   * different name. Only the launch knows, which is why it is recorded here and
   * consumed by the first report in setAgentSession.
   */
  private noteConversationStart(entry: PersistedEntry, resumed: boolean): void {
    if (resumed) {
      this.awaitingResumedIdentity.add(entry.id);
      return;
    }
    this.awaitingResumedIdentity.delete(entry.id);
    entry.autoTitleRank = undefined;
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
    // A conversation change releases the slot's title — the name describes what
    // was being worked on, not the slot. Ordered BEFORE the unchanged early-out
    // below so a resume that comes back under the SAME id still consumes the
    // claim; left armed, the `/clear` after it would read as that resume.
    if (!this.awaitingResumedIdentity.delete(id)
        && entry.agentSessionId !== undefined
        && entry.agentSessionId !== agentSessionId) {
      entry.autoTitleRank = undefined;
    }
    // Keep a previously captured path if this report omits one for the SAME
    // session — an agent's SessionStart can fire before the transcript path is
    // known, then a later turn-end report supplies it (antigravity's
    // PreInvocation behaves the same way). A new session id resets it.
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
    // A native fork command starts its new conversation as the PTY launches.
    // Keep its one-shot argv until the provider reports that new identity; a
    // successful OS spawn alone cannot distinguish an invalid source id from a
    // real provider fork.
    if (this.awaitingNativeForkIdentity(entry)) this.completeForkLaunch(entry);
    this.changed();
  }

  /** Handler-judge lookup. agentTranscriptPath is deliberately ABSENT from
   *  toWire()/SessionEntry (persisted-only, never on the wire) — do NOT expose
   *  it by adding it to toWire; this getter is the sanctioned read path. */
  getAgentTranscriptPath(id: string): string | undefined {
    return this.entries.get(id)?.agentTranscriptPath;
  }

  /**
   * The slot id whose last-active agent conversation is `conversationId`, or
   * undefined. Used by the antigravity rename watcher to route a live `/rename`
   * (keyed by agy's conversationId) back to the owning session for auto-naming.
   */
  findSlotByAgentSession(conversationId: string): string | undefined {
    for (const e of this.entries.values()) {
      if (e.agentSessionId === conversationId) return e.id;
    }
    return undefined;
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
    // The kill above cannot reach a start that has not happened yet: a session
    // archived while its checkout is still provisioning would otherwise launch
    // its agent the moment setup settled. The prompt stays in
    // `lastQueuedPrompt`, so unarchive then rerun still re-arms it.
    const queued = this.setups.get(id);
    if (queued) queued.pendingStart = undefined;
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
    if (isManagedCheckoutKind(entry.checkoutKind)) {
      // Refused BEFORE the lock, never queued behind it: a second delete is an
      // immediate answer the caller is owed, and serializing it would leave the
      // app waiting out the whole first teardown for a refusal.
      // Rejected, not thrown: this arm's contract is a promise, and a sync
      // throw would escape every caller that only awaits the result.
      if (this.deleting.has(id)) {
        return Promise.reject(new WorktreeError(
          "WORKTREE_DELETE_IN_PROGRESS", "This isolated session is already being deleted."));
      }
      // BOTH arms under the membership key, and the count read inside it. The
      // count is what picks between detaching a member and `git worktree
      // remove`, so reading it outside lets a concurrent fork attach to the
      // checkout this call is about to destroy — and lets two member deletes
      // both see a survivor that the first one then removes.
      return this.withCheckoutMembership(entry.checkoutId, async () => {
        if (!this.entries.has(entry.id)) return false;
        return this.membersForCheckout(entry.checkoutId).length > 1
          ? this.deleteAttachedMemberLocked(entry)
          : this.deleteManaged(entry, options);
      });
    }
    if (this.tm.has(id)) this.tm.kill(id);
    this.dropSession(id);
    this.changed();
    return true;
  }

  /** Everything a delete must release for one session, the TerminalManager's
   *  own memory of its PTY included. That last part is what nothing did: a
   *  session terminal is namespaced by nothing, so its whole attribution is the
   *  owner row agent-core writes, and `forget` is the only signal that releases
   *  it. Left in `stoppedTerminals` with its entry gone, the corpse resolves
   *  through `terminalOwner`'s "main" default and is advertised in the primary
   *  workspace as a stopped agent tab, for the life of the process, with
   *  nothing on any surface able to close it. Safe to call before the PTY's
   *  exit lands: `forget` tombstones a still-live terminal so the exit cannot
   *  re-create the rows it just dropped. */
  private dropSession(id: string): void {
    this.tm.forget(id);
    this.entries.delete(id);
    this.resumableCache.delete(id);
    this.awaitingResumedIdentity.delete(id);
    this.setups.delete(id);
  }

  /** Flag a session's delete as in flight and announce it. Emits without
   *  persisting — `deleting` is runtime state that must never dirty
   *  sessions.json — which is also why this is not `changed()`. */
  private markDeleting(entry: PersistedEntry, checkoutId: string | null = entry.checkoutId): void {
    this.deleting.set(entry.id, checkoutId);
    this.notifyObservers();
  }

  /** Drop the flag, reporting whether it was actually set so the caller can
   *  decide whether an emit is owed. Never emits itself: the success path rides
   *  the emit that already follows the flush, while the failure paths need the
   *  clear to land BEFORE they do anything else. */
  private clearDeleting(sessionId: string): boolean {
    return this.deleting.delete(sessionId);
  }

  private async deleteManaged(entry: PersistedEntry, options: DeleteSessionOptions): Promise<boolean> {
    if (options.removeCheckout === false) {
      throw new WorktreeError("WORKTREE_CONFLICT", "An isolated session cannot be deleted without its managed worktree.");
    }
    // The flag has to cover exactly one operation. Two deletes racing on one
    // session would have the first to finish clear it — re-opening the dispatch
    // guard while the second is still tearing the directory down.
    if (this.deleting.has(entry.id)) {
      throw new WorktreeError("WORKTREE_DELETE_IN_PROGRESS", "This isolated session is already being deleted.");
    }
    const manager = this.opts.worktreeManager;
    if (!manager) throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree manager is unavailable.");
    if (!await manager.recordFor(this.opts.projectId, entry.checkoutId)) {
      // The checkout metadata is gone (reconciled away, or lost with a forgotten
      // project's store), so there is nothing left to reclaim and the session
      // row is the only trace. Refusing here — which `inspect`'s
      // WORKTREE_MISSING would — makes that row permanently undeletable.
      if (this.tm.has(entry.id)) this.tm.kill(entry.id);
      this.markDeleting(entry);
      try {
        await this.cancelSetupForDelete(entry);
        // Still torn down even though there is no worktree left to unlock: the
        // checkout's `services:` PTYs, watcher and port detector outlive it, and
        // once this row is gone nothing on the machine can name that checkoutId
        // again. A no-op when no runtime was ever prepared.
        await this.opts.teardownCheckoutRuntime?.(entry.checkoutId);
      } catch (error) {
        if (this.clearDeleting(entry.id)) this.notifyObservers();
        // The session survived its delete, so the setup this flow cancelled is
        // still holding its `services:` back with nothing else able to release
        // them — same reason as the sibling catch on the main delete path.
        await this.releaseSetupHold(entry);
        throw error;
      }
      this.dropSession(entry.id);
      this.clearDeleting(entry.id);
      // In a finally: the row is already gone from memory and the flag already
      // cleared, so a flush that throws must not leave the app holding the
      // `deleting: true` push as its newest view of a session the bridge has
      // forgotten — that row is inert on every surface with nothing left to
      // clear it.
      try {
        await this.flushNowOrThrow();
      } finally {
        this.notifyObservers();
      }
      return true;
    }
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
    // Re-checked, not just checked on entry: the preflight above awaits two Git
    // calls, and a second delete for the same session can arrive and mark
    // during them. Nothing may await between here and markDeleting.
    if (this.deleting.has(entry.id)) {
      throw new WorktreeError("WORKTREE_DELETE_IN_PROGRESS", "This isolated session is already being deleted.");
    }
    // Flagged only past the preflight: those two refusals destroy nothing and
    // the user can still answer them, so the row must not blink through a
    // pending state on the way to a dialog.
    this.markDeleting(entry);
    try {
      // Cancelled, never refused: a user deleting a session does not want to be
      // told to wait out a `bun install`. Placed past the two preflight
      // refusals, which destroy nothing and are still answerable — but before
      // everything that does, because a live setup process holding the checkout
      // as its cwd is what makes `git worktree remove` fail on Windows.
      await this.cancelSetupForDelete(entry);
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
        // Cleared before the rebuild, never in a `finally` after it: from here on
        // the checkout is being RESTORED, and everything the rebuilt runtime
        // serves would be refused by a guard that still reads it as dying.
        if (this.clearDeleting(entry.id)) this.notifyObservers();
        const checkout = await this.opts.resolveCheckout?.(entry.checkoutId).catch(() => undefined);
        if (checkout) {
          try { await this.opts.prepareCheckoutRuntime?.(checkout); } catch { /* preserve original error */ }
        }
        throw error;
      }
    } catch (error) {
      if (this.clearDeleting(entry.id)) this.notifyObservers();
      // The session survived its delete, so the setup this flow cancelled is
      // still holding its `services:` back with nothing else able to release
      // them: `settleSetup` is gated on a `running` state the cancel moved, and
      // a rerun mints a run that holds nothing.
      await this.releaseSetupHold(entry);
      throw error;
    }
    this.dropSession(entry.id);
    this.clearDeleting(entry.id);
    // See the sibling tail above: the emit is owed even when the flush fails.
    try {
      await this.flushNowOrThrow();
    } finally {
      this.notifyObservers();
    }
    return true;
  }

  /** Deliberately inert. `session:focus` DOES have a reader — the work-status
   *  read state, which agent-core routes straight to the owning ProjectCore —
   *  but nothing here may move: bumping `lastUsedAt` on a look would make the
   *  drawer's ACTIVITY ordering re-sort itself under the user's cursor every
   *  time they switched sessions. */
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
   * The slot's last-active agent conversation id, or undefined when none was
   * captured or it no longer exists on disk. A stale id (conversation deleted
   * via the agent's own tools, or written under a cwd this slot no longer runs
   * in — a managed worktree that has since gone) is cleared in place so the next
   * start opens a fresh conversation.
   *
   * EVERY start path must come through here, PTY and chat alike. A dead id is
   * worse for chat than for a PTY: the driver resumes it on every start, the
   * backend answers "no conversation found", and nothing clears the id — so the
   * session is bricked for good rather than for one spawn.
   */
  private resumeIdFor(tool: string, entry: PersistedEntry): string | undefined {
    if (!entry.agentSessionId) return undefined;
    const resumable = sessionResumable({
      tool,
      agentSessionId: entry.agentSessionId,
      agentTranscriptPath: entry.agentTranscriptPath,
      codexHome: this.opts.codexHome,
      copilotHome: this.opts.copilotHome,
    });
    if (resumable) return entry.agentSessionId;
    entry.agentSessionId = undefined;
    entry.agentTranscriptPath = undefined;
    this.resumableCache.delete(entry.id);
    this.changed();
    return undefined;
  }

  /**
   * Resume tokens for the slot's last-active agent conversation, or [] when
   * [resumeIdFor] has nothing live to resume. Shared by the per-session-tool and
   * the default-spec (copilot) launch paths.
   */
  private resumeArgsFor(tool: string, entry: PersistedEntry): string[] {
    const resumeId = this.resumeIdFor(tool, entry);
    return resumeId ? resumeArgv(tool, resumeId) : [];
  }

  start(id: string, initialPrompt?: string): void | Promise<void> {
    const entry = this.entries.get(id);
    // The second door into a dying checkout's runtime: startCheckout would
    // re-prepare it and spawn a PTY cwd'd inside the directory the delete is
    // about to remove.
    if (entry && this.deleting.has(entry.id)) {
      return Promise.reject(new WorktreeError(
        "WORKTREE_DELETE_IN_PROGRESS",
        "This isolated session is being deleted.",
      ));
    }
    // Queued, not refused: the workspace this agent would launch into is still
    // being provisioned. The reply stays `ok` because the entry it carries says
    // `pendingStart`, which is how the app tells "queued" from "started" — and
    // the queue lives here rather than in the app so a user who locks their
    // phone comes back to a running agent. Skip, cancel and completion all
    // release the gate and fire this.
    //
    // Never for a session that is ALREADY running: such a start is the
    // reconnect re-announce path (see startNow / reannounceCheckout), and
    // queuing it would hold that app's checkout view until the run ends
    // instead of re-pushing the state it is waiting for.
    const gate = entry && !this.isRunning(entry) ? this.setupGate(entry.id) : undefined;
    if (gate) {
      // A prompt already queued survives a start that carries none: every
      // ungated auto-start path (a row tap, the workspace bootstrap) sends a
      // bare `session:start`, and letting one overwrite the create flow's
      // prompt loses the only copy the user typed.
      gate.pendingStart = { initialPrompt: initialPrompt ?? gate.pendingStart?.initialPrompt };
      this.notifyObservers();
      return;
    }
    if (!entry || entry.checkoutId === "main") return this.startNow(id, initialPrompt);
    return this.startCheckout(id, initialPrompt, entry.checkoutId);
  }

  /** The two unusable-checkout states are what the app's two badge treatments
   *  are for, so every path that discovers one must stamp it: `missing` is not
   *  recoverable in place, `failed` is a config/environment fault the user can
   *  repair and retry. */
  private markCheckoutState(sessionId: string, state: CheckoutState): void {
    const entry = this.entries.get(sessionId);
    if (!entry || entry.checkoutState === state) return;
    entry.checkoutState = state;
    this.changed();
  }

  private async startCheckout(id: string, initialPrompt: string | undefined, checkoutId: string): Promise<void> {
    let checkout: CheckoutRecord | undefined;
    try {
      checkout = await this.opts.resolveCheckout?.(checkoutId);
    } catch (error) {
      // The record is there; building its runtime is what failed. Repairable,
      // so it is `failed` rather than `missing`.
      this.markCheckoutState(id, "failed");
      logWorktreeEvent("worktree_resume_failed", {
        projectId: this.opts.projectId, checkoutId, sessionId: id,
        errorCode: worktreeErrorCode(error),
      });
      throw error;
    }
    if (!checkout || checkout.id !== checkoutId || !checkout.path) {
      this.markCheckoutState(id, "missing");
      logWorktreeEvent("worktree_resume_missing", {
        projectId: this.opts.projectId, checkoutId, sessionId: id,
      });
      throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree is no longer available.");
    }
    if (!existsSync(checkout.path)) {
      // The record is durable metadata and says nothing about the disk. Without
      // this stat a hand-deleted worktree spawns a PTY whose cwd does not exist
      // while the badge keeps claiming `ready`.
      this.markCheckoutState(id, "missing");
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
      this.markCheckoutState(id, "failed");
      logWorktreeEvent("worktree_resume_conflict", {
        projectId: this.opts.projectId, checkoutId, sessionId: id,
        errorCode: worktreeErrorCode(error),
      });
      throw error;
    }
    this.markCheckoutState(id, "ready");
    this.startNow(id, initialPrompt, checkout.path, spec);
  }

  /** Re-push a live isolated checkout's runtime state.
   *
   *  A start on an ALREADY-running session means the caller has no state for it
   *  — a reconnected app whose per-checkout view was built after the
   *  connect-time replay had already gone by. Returning silently left it
   *  waiting for a frame nobody would send again. `main` needs none of this:
   *  its view exists before the first frame. */
  private reannounceCheckout(checkoutId: string): void {
    if (checkoutId === "main") return;
    try {
      this.opts.announceCheckoutRuntime?.(checkoutId);
    } catch (err) {
      // Best-effort: a re-push must never fail the start. Logged rather than
      // swallowed — MessageBus deliberately propagates a throwing deliver() so
      // a subscriber bug stays visible, and a silent catch here is exactly the
      // "waiting for agent with no diagnostic" this re-push exists to end.
      log.warn(`re-announce for checkout ${checkoutId} failed: ${err}`);
    }
  }

  // --- worktree.setup ---

  /**
   * Answer the user's `session:setup` verb.
   *
   * Only two things refuse: an unknown session, and a rerun of a run that is
   * still going (a second runner would fight the first for the checkout).
   * Everything else is a no-op rather than an error — the app can only send
   * these from a view that may be a frame behind the state it is acting on, and
   * a cancel that lands just after the run finished asked for the state it
   * already has.
   */
  async applySetupAction(id: string, action: "skip" | "cancel" | "rerun"): Promise<void> {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    const setup = this.setups.get(id);
    if (action === "rerun") return this.rerunSetup(entry, setup);
    if (!setup || setup.state !== "running") return;
    if (action === "skip") {
      // The run itself is untouched: the banner keeps reporting it, and the
      // services it holds back are still its to release when it ends. Skip
      // answers "I know the deps are cached", not "stop".
      setup.gateReleased = true;
      this.notifyObservers();
      this.firePendingStart(id);
      return;
    }
    await this.cancelSetupRun(entry, setup);
  }

  /** This session's run while it is still holding starts back, else undefined. */
  private setupGate(sessionId: string): SetupRuntime | undefined {
    const setup = this.setups.get(sessionId);
    return setup?.state === "running" && !setup.gateReleased ? setup : undefined;
  }

  /** Register a fresh run's state. The runner is started separately and
   *  strictly later; `terminalId` stays unset until the runner reports the PTY
   *  it actually spawned, so the app never offers a log it cannot replay. */
  private beginSetup(
    sessionId: string,
    holdsServices: boolean,
    pendingStart?: { initialPrompt?: string },
  ): SetupRuntime {
    const setup: SetupRuntime = {
      runId: this.nextSetupRunId++,
      state: "running",
      stepIndex: 0,
      stepCount: 0,
      startedAt: Date.now(),
      pendingStart,
      // Survives across reruns so a second one can still re-arm the start.
      lastQueuedPrompt: pendingStart?.initialPrompt ?? this.setups.get(sessionId)?.lastQueuedPrompt,
      gateReleased: false,
      holdsServices,
    };
    this.setups.set(sessionId, setup);
    return setup;
  }

  /** A coarse transition from the setup runner: step boundaries and terminal
   *  states only. Emitted through the IMMEDIATE notifyObservers path, never the
   *  debounced activity emit — the banner reads "step 2 of 4" from this, and a
   *  750 ms coalesce leaves it a step behind. Live output never comes this way;
   *  it rides the setup terminal's own `terminal:output`. */
  private onSetupProgress(sessionId: string, runId: number, progress: CheckoutSetupProgress): void {
    const entry = this.entries.get(sessionId);
    const setup = this.setups.get(sessionId);
    // The session was deleted, a rerun replaced this run, or a cancel already
    // settled it: a killed process's dying report must not reopen a state the
    // user has been shown, nor land on its own successor.
    if (!entry || !setup || setup.runId !== runId || setup.state !== "running") return;
    setup.state = progress.state;
    setup.stepIndex = progress.stepIndex;
    setup.stepCount = progress.stepCount;
    setup.stepName = progress.stepName;
    setup.exitCode = progress.exitCode;
    setup.message = progress.message;
    // Kept when a later report omits it: the transcript stays reachable after
    // the run ends, which is the point of the expandable log.
    if (progress.terminalId !== undefined) setup.terminalId = progress.terminalId;
    if (progress.state === "running") {
      this.notifyObservers();
      return;
    }
    setup.finishedAt = Date.now();
    setup.gateReleased = true;
    // Before the tail, not after: the badge and banner must settle on the same
    // tick the run ended, while the disk write behind them takes as long as it
    // takes.
    this.notifyObservers();
    void this.settleSetup(entry, setup).catch((err) => {
      log.warn(`settling setup for session ${entry.id} failed: ${err}`);
    });
  }

  /** The tail of a finished run: release the services it held back, fire the
   *  start queued behind it, then stamp the durable marker. In that order — the
   *  queued agent should find its dev server already coming up, and the disk
   *  write is the only part nothing is waiting on. */
  private async settleSetup(entry: PersistedEntry, setup: SetupRuntime): Promise<void> {
    if (setup.holdsServices) {
      setup.holdsServices = false;
      try {
        await this.opts.startDeferredServices?.(entry.checkoutId);
      } catch (err) {
        log.warn(`deferred services for checkout ${entry.checkoutId} failed to start: ${err}`);
      }
    }
    // Everything below belongs to THIS run. `cancelSetupRun` settles only
    // after awaiting a kill, and a `rerun` arriving during that wait mints a
    // new run whose deliberate marker clear this stamp would overwrite —
    // leaving a durable outcome recorded over a run that is still going.
    if (this.setups.get(entry.id) !== setup) return;
    this.firePendingStart(entry.id);
    await this.stampSetupMarker(entry.checkoutId, setup);
  }

  /** Launch the start held behind a run. The gate must already be open — start()
   *  re-enters it and would queue the start straight back. */
  private firePendingStart(sessionId: string): void {
    const setup = this.setups.get(sessionId);
    const pending = setup?.pendingStart;
    if (!setup || !pending) return;
    setup.pendingStart = undefined;
    // Only overwritten by a prompt that exists: `lastQueuedPrompt` is what a
    // rerun re-arms from, and a promptless start must not empty it.
    if (pending.initialPrompt !== undefined) setup.lastQueuedPrompt = pending.initialPrompt;
    this.notifyObservers();
    // There is no requestId left to fail: the app was told `ok` the moment the
    // start was queued, so a spawn that throws corrects itself through the
    // entry's `running` rather than through a reply.
    const failed = (err: unknown): void => log.warn(`queued start for session ${sessionId} failed: ${err}`);
    try {
      const started = this.start(sessionId, pending.initialPrompt);
      if (started) started.catch(failed);
    } catch (err) {
      failed(err);
    }
  }

  /** Kill a run the user cancelled and settle it as `skipped`. */
  private async cancelSetupRun(entry: PersistedEntry, setup: SetupRuntime): Promise<void> {
    // Marked BEFORE the kill, and rather than from the killed run's own dying
    // report — that one says `failed`, and a cancel the user asked for is not a
    // failure. The ordering is what keeps it: the runner reports back from
    // inside `killSetupTree`, and a state still reading `running` would let
    // `onSetupProgress` settle the run as failed and run this tail twice.
    setup.state = "skipped";
    setup.exitCode = undefined;
    setup.message = undefined;
    setup.finishedAt = Date.now();
    setup.gateReleased = true;
    this.notifyObservers();
    await this.killSetupTree(entry.checkoutId);
    // Strictly after the kill: a still-live `bun install` holds the checkout as
    // its cwd, and the services released below start inside it.
    await this.settleSetup(entry, setup);
  }

  /** Kill a live run because the session is going away. Quiet on purpose: no
   *  durable marker (the checkout is being reclaimed), no deferred services
   *  (there will be no runtime to serve them) and no queued start (there will be
   *  no session to start). */
  private async cancelSetupForDelete(entry: PersistedEntry): Promise<void> {
    const setup = this.setups.get(entry.id);
    if (!setup || setup.state !== "running") return;
    // Settled without an emit — the delete flow's own emits cover it. Settled
    // BEFORE the kill, because the runner reports back from inside it: a state
    // still reading `running` sends the killed run's dying report straight
    // through `onSetupProgress` into `settleSetup`, which starts the checkout's
    // `services:` inside a worktree `git worktree remove` is about to take and
    // stamps a durable marker for a checkout being reclaimed.
    setup.state = "skipped";
    setup.finishedAt = Date.now();
    setup.gateReleased = true;
    // Dropped rather than fired: there is no session to start. It must not
    // SURVIVE either — a delete Git refuses leaves this row alive, and an entry
    // still reporting `pendingStart` is one the app's bootstrap never
    // auto-starts again. The prompt stays in `lastQueuedPrompt` for a rerun.
    setup.pendingStart = undefined;
    await this.killSetupTree(entry.checkoutId);
  }

  /** Hand back the `services:` a settled run is still holding. `settleSetup` is
   *  the usual releaser; this is for the run that never reaches it — cancelled
   *  for a delete Git then refused, which leaves the session, its runtime and
   *  its deferral alive with nothing left able to clear them. */
  private async releaseSetupHold(entry: PersistedEntry): Promise<void> {
    const setup = this.setups.get(entry.id);
    if (!setup?.holdsServices) return;
    setup.holdsServices = false;
    try {
      await this.opts.startDeferredServices?.(entry.checkoutId);
    } catch (err) {
      log.warn(`deferred services for checkout ${entry.checkoutId} failed to start: ${err}`);
    }
  }

  /** Awaited, never fatal: until the kill has walked the tree a `bun install`
   *  still holds the checkout as its cwd, which is what makes `git worktree
   *  remove` fail on Windows. A cancel that could not land must not become a
   *  refusal — the caller is either deleting the session or has already been
   *  told the run is over. */
  private async killSetupTree(checkoutId: string): Promise<void> {
    try {
      await this.opts.cancelCheckoutSetup?.(checkoutId);
    } catch (err) {
      log.warn(`cancelling setup for checkout ${checkoutId} failed: ${err}`);
    }
  }

  /** Start a fresh run against the current config, resetting the transcript. */
  private async rerunSetup(entry: PersistedEntry, previous: SetupRuntime | undefined): Promise<void> {
    if (previous?.state === "running") throw new Error("workspace setup is already running");
    if (!isManagedCheckoutKind(entry.checkoutKind)) {
      throw new Error(`session has no managed workspace to set up: ${entry.id}`);
    }
    if (this.deleting.has(entry.id)) {
      throw new WorktreeError("WORKTREE_DELETE_IN_PROGRESS", "This isolated session is being deleted.");
    }
    const run = this.opts.runCheckoutSetup;
    if (!run) throw new Error("this bridge cannot run workspace setup");
    // `resolveCheckout`, not the manager's bare `recordFor`: it is the wrapper
    // that warms the checkout runtime, and without a warm one
    // `registerSetupTerminal` no-ops — the transcript then routes to main and
    // its retained scrollback outlives every sweep able to release it. A rerun
    // off a recovered `interrupted` state is exactly that cold case.
    const checkout = await this.opts.resolveCheckout?.(entry.checkoutId)
      ?? await this.opts.worktreeManager?.recordFor(this.opts.projectId, entry.checkoutId);
    if (!checkout) throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree is no longer available.");
    // The record outliving the directory is the case that matters: a worktree
    // removed out of band leaves `resolveSetup` unable to find the checkout's
    // own antgrid.yaml, and a run with no steps reports `done` — stamping a
    // durable success over a checkout that has no files in it at all.
    if (!existsSync(checkout.path)) {
      throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree is no longer available.");
    }
    // Cleared BEFORE the run rather than overwritten after it: a bridge that
    // dies mid-rerun must come back `interrupted`, and the previous run's `done`
    // would claim otherwise.
    await this.stampSetupMarker(entry.checkoutId, undefined);
    // The prompt carries over so re-run-setup → restart-agent does not make the
    // user retype it. The gate does not: a fresh run gates afresh, and the
    // release the user gave the previous one said nothing about this one. An
    // agent already launched keeps running — the gate only holds new starts.
    // Only when the agent is stopped: a live agent already received this prompt,
    // and re-arming would deliver it twice.
    const requeue = previous?.lastQueuedPrompt !== undefined && !this.isRunning(entry)
      ? { initialPrompt: previous.lastQueuedPrompt }
      : undefined;
    const setup = this.beginSetup(entry.id, false, requeue);
    this.notifyObservers();
    run(checkout, entry.id, (progress) => this.onSetupProgress(entry.id, setup.runId, progress));
  }

  /** Record how a run ENDED, in the project's checkouts.json. `running` can
   *  never be written and neither can `interrupted`, which is only ever derived
   *  from a marker's absence: a bridge that dies mid-run must come back
   *  interrupted rather than permanently preparing. Passing no outcome clears
   *  the marker, which is how a rerun says the last one no longer describes this
   *  checkout. */
  private async stampSetupMarker(
    checkoutId: string,
    outcome?: { state: SetupState; finishedAt?: number; exitCode?: number },
  ): Promise<void> {
    const durable: DurableSetupState | undefined = DURABLE_SETUP_STATES.find((state) => state === outcome?.state);
    if (outcome && !durable) return;
    try {
      // update(), never get()-then-put(): the row may be reclaimed while the run
      // is finishing, and a read-modify-write spanning two lock acquisitions
      // would resurrect a checkout whose directory Git has already removed.
      await this.checkoutStore().update(checkoutId, (record) => ({
        ...record,
        setupState: durable,
        setupFinishedAt: durable ? (outcome?.finishedAt ?? Date.now()) : undefined,
        setupExitCode: durable ? outcome?.exitCode : undefined,
      }));
    } catch (err) {
      log.warn(`could not record the setup outcome for checkout ${checkoutId}: ${err}`);
    }
  }

  /** Report where setup left off for the managed checkouts this bridge just
   *  inherited. A marker is the outcome of a finished run; its absence means the
   *  bridge died mid-run, which is `interrupted`. Deliberately NOT an automatic
   *  rerun: a setup step can be expensive or destructive and the user did not
   *  ask for one on this launch.
   *
   *  Fire-and-forget off the constructor — the read is async and the session
   *  list is usable without it, so it lands as one extra session:updated instead
   *  of blocking every project's load. */
  private async recoverSetupStates(): Promise<void> {
    const managed = Array.from(this.entries.values())
      .filter((entry) => isManagedCheckoutKind(entry.checkoutKind));
    if (managed.length === 0) return;
    let records: CheckoutRecord[];
    try {
      records = await this.checkoutStore().list();
    } catch (err) {
      log.warn("checkout setup markers unreadable: %s", err);
      return;
    }
    const byCheckout = new Map(records.map((record) => [record.id, record]));
    let recovered = false;
    for (const entry of managed) {
      // A run started while this read was in flight owns the slot.
      if (this.setups.has(entry.id)) continue;
      const record = byCheckout.get(entry.checkoutId);
      // No marker AND nothing to have run: this checkout predates the project's
      // setup block (or the feature itself), so there was never a run to
      // interrupt. Reporting one would banner every isolated session that
      // existed before the upgrade.
      // No record at all is the same answer: an unreadable or truncated
      // checkouts.json must not banner every isolated session in the project as
      // `interrupted`, with a "Run setup" button `rerunSetup` can only answer
      // with WORKTREE_MISSING.
      if (!record) continue;
      if (!record.setupState && this.opts.checkoutDeclaresSetup?.(record) === false) continue;
      // `done` is deliberately NOT re-seeded. A finished run offers no action,
      // and `startedAt` can only fall back to the session's creation time — so
      // a recovered success re-announces "Workspace ready" for every isolated
      // session on every launch, with only an in-memory dismissal against it.
      // Absent state is the correct report for a checkout already provisioned.
      if (record.setupState === "done") continue;
      this.setups.set(entry.id, {
        // No runner behind a recovered state, so no report may ever land on it.
        runId: 0,
        state: record.setupState ?? "interrupted",
        // The step counts died with the run; only its outcome was durable.
        stepIndex: 0,
        stepCount: 0,
        exitCode: record.setupExitCode,
        // No terminal either: the transcript died with the PTY that wrote it,
        // so the app must not offer a log it cannot replay.
        startedAt: entry.createdAt,
        finishedAt: record.setupFinishedAt,
        gateReleased: true,
        holdsServices: false,
      });
      recovered = true;
    }
    if (recovered) this.notifyObservers();
  }

  /** The project's durable checkout metadata. Minted per call rather than held:
   *  CheckoutStore serializes its read-modify-write against every other holder
   *  of the same path through a static, path-keyed lock, so a cached instance
   *  would buy nothing and would only race WorktreeManager's own. `storeDir` is
   *  the ~/.antgrid root the manager derives its store from too. */
  private checkoutStore(): CheckoutStore {
    return new CheckoutStore(this.opts.storeDir, this.opts.projectId);
  }

  private startNow(id: string, initialPrompt?: string, checkoutPath = this.projectPath, sessionAgentSpec = this.agentSpec): void {
    const entry = this.entries.get(id);
    if (!entry) throw new Error(`session not found: ${id}`);
    if (entry.archived) throw new Error(`cannot start archived session: ${id}`);
    if (entry.mode === "chat") {
      // Chat sessions have no PTY. Delegate to the structured manager; the
      // persisted agentSessionId (claude session / codex threadId / opencode
      // sessionID) resumes the prior conversation, through the same liveness
      // pre-flight the PTY path uses. Tool defaults to codex — chat is offered
      // only for chat-capable tools, gated app-side and re-checked in startChat.
      const chatAlreadyRunning = this.runningChat.has(id);
      this.runningChat.add(id);
      const chatTool = entry.tool ?? "codex";
      const resumeId = entry.conversationStart === "fork" ? undefined : this.resumeIdFor(chatTool, entry);
      this.noteConversationStart(entry, resumeId !== undefined);
      this.opts.onStartChat?.({
        sessionId: id,
        tool: chatTool,
        resumeId,
        config: entry.config,
        initialPrompt: this.forkInitialPrompt(entry, initialPrompt),
      });
      entry.lastUsedAt = Date.now();
      this.completeForkLaunch(entry);
      this.changed();
      if (chatAlreadyRunning) this.reannounceCheckout(entry.checkoutId);
      return;
    }
    if (this.tm.has(id)) {
      log.warn(`session ${id} already running`);
      this.reannounceCheckout(entry.checkoutId);
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
    // Provider-native fork args are one-shot like the transcript handoff. They
    // create a fresh provider session and therefore replace, never combine
    // with, resume args.
    const nativeForkArgs = entry.forkNativeArgs ?? [];
    if (nativeForkArgs.length > 0 && initialPrompt?.trim()) {
      throw new Error("This provider-native fork starts immediately; send a prompt after the fork opens.");
    }
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
      // Resume the slot's last-active conversation (held in resumeArgs, appended
      // LAST in the spawn block so it lands after any per-session args — required
      // for codex's `resume` subcommand).
      resumeArgs = entry.conversationStart === "fork" ? [] : this.resumeArgsFor(entry.tool, entry);
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
      if (agentSpec(sessionAgentSpec.name)?.augmentsDefaultSpec) {
        const aug = augmentAgentLaunch(sessionAgentSpec.name, this.opts.storeDir, this.opts.cursorDir);
        baseArgs = [...baseArgs, ...aug.args];
        launchEnv = { ...launchEnv, ...aug.env };
        notificationsInjected = aug.notificationsInjected;
        resumeArgs = entry.conversationStart === "fork" ? [] : this.resumeArgsFor(sessionAgentSpec.name, entry);
      }
    }
    if (!base) {
      // No per-session spec and the first-run wizard hasn't supplied an
      // agent.tool/command yet (placeholder `{command:""}`); refuse rather
      // than spawning a default shell.
      throw new Error("agent.tool or agent.command not configured");
    }
    // After the throw: a launch that never happened has started no conversation
    // and must not release the title of the one still recorded here.
    this.noteConversationStart(entry, resumeArgs.length > 0);

    // One-shot first prompt, appended LAST (after resume tokens — codex's
    // `resume <uuid>` is a subcommand and the positional prompt must follow it).
    // Built once: the PTY fallback below hands the same string to the terminal.
    const launchPrompt = this.forkInitialPrompt(entry, initialPrompt) ?? "";
    const promptArgs = isCustomLine
      ? []
      : initialPromptArgv(entry.tool ?? sessionAgentSpec.name, launchPrompt);

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
      const resumeAfterRaw =
        agentSpec(entry.tool ?? sessionAgentSpec.name)?.resumeIsSubcommand === true;
      // Native fork args obey the same rule for the same reason: codex's `fork`
      // is a subcommand exactly as its `resume` is, so placing it before the
      // user's raw args hands the user's global flags to the subcommand.
      const conversationArgs = [...resumeArgs, ...nativeForkArgs].map(shellQuoteArg);
      const beforeRaw = resumeAfterRaw ? [] : conversationArgs;
      const afterRaw = resumeAfterRaw ? conversationArgs : [];
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
      : [...baseArgs, ...resumeArgs, ...nativeForkArgs, ...promptArgs];

    // Geometry is left to TerminalManager, which spawns at whatever size the
    // pane's driver last reported (80x24 only for the first terminal of a
    // fresh host). The app's `terminal:resize` still corrects it once the
    // viewed terminal's cell metrics settle. Do NOT defer the spawn until that
    // resize arrives: the tab never mounts without a PTY, so the resize never
    // fires, so the PTY never spawns — an earlier revision deadlocked exactly
    // there.
    this.tm.spawn({
      terminalId: id,
      name: entry.name,
      command,
      args: spawnArgs, // [] when args were folded into `command`; default flags otherwise
      cwd: sessionAgentSpec.workingDir ? resolve(checkoutPath, sessionAgentSpec.workingDir) : checkoutPath,
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
      hookAliveProbeAgent: injectsHookAliveProbe(entry.tool ?? sessionAgentSpec.name)
        ? entry.tool ?? sessionAgentSpec.name
        : undefined,
    });
    // Some registry agents have no verified launch-argv form for an opening
    // prompt. Their PTY still buffers input during startup, which gives every
    // registered terminal agent the same transcript-fork capability without
    // inventing unsupported CLI flags.
    if (entry.conversationStart === "fork" && entry.forkTranscript && promptArgs.length === 0) {
      this.tm.write(id, `${launchPrompt}\r`);
    }
    entry.lastUsedAt = Date.now();
    // Transcript forks have been handed to the spawned process. Native forks
    // wait for setAgentSession() to receive their newly minted provider id —
    // but for ONE launch only. A CLI predating the fork flag, or a source
    // conversation the provider has since pruned, never reports an id, and
    // holding the argv indefinitely re-forks the source on every start while
    // the forced-empty resumeArgs stop the session ever holding a conversation
    // of its own. The second launch drops it and starts fresh instead.
    if (!this.awaitingNativeForkIdentity(entry)) this.completeForkLaunch(entry);
    else if (entry.forkNativeAttempted) this.completeForkLaunch(entry);
    else entry.forkNativeAttempted = true;
    this.changed();
  }

  /** Sessions sharing one MANAGED checkout. `main` is not a shared workspace —
   *  every ordinary session carries `checkoutId: "main"`, so counting it would
   *  report every project with two plain sessions as shared, exactly the trap
   *  `isCheckoutDeleting` asserts against. */
  private membersForCheckout(checkoutId: string): PersistedEntry[] {
    if (checkoutId === "main") return [];
    return Array.from(this.entries.values()).filter((entry) => entry.checkoutId === checkoutId);
  }

  /** `membersForCheckout(...).length` without the array. `toWire` runs once per
   *  entry on a list that is rebuilt on every observer emit, so materializing a
   *  copy of the session map per row makes that emit O(n²). */
  private countMembersForCheckout(checkoutId: string): number {
    if (checkoutId === "main") return 0;
    let count = 0;
    for (const entry of this.entries.values()) {
      if (entry.checkoutId === checkoutId) count++;
    }
    return count;
  }

  /** Delete one attached member without reclaiming the checkout it shares.
   *  Caller holds `withCheckoutMembership` for this checkout. */
  private async deleteAttachedMemberLocked(entry: PersistedEntry): Promise<boolean> {
    if (this.deleting.has(entry.id)) {
      throw new WorktreeError("WORKTREE_DELETE_IN_PROGRESS", "This session is already being deleted.");
    }
    // `null`, not the checkout id: this delete reclaims NOTHING, and flagging
    // the checkout would make agent-core refuse every checkout-variable verb —
    // keystrokes, file reads, git — for the SIBLINGS that keep working in it,
    // under a message saying their workspace is being deleted.
    this.markDeleting(entry, null);
    try {
      // Checked, as deleteManaged does: dropSession() tombstones the terminal,
      // so forgetting a member whose agent never died leaves that process alive
      // inside the shared worktree with no row and nothing able to kill it.
      if (!await this.stopAndAwait(entry.id)) {
        throw new WorktreeError("WORKTREE_DELETE_FAILED", "The session did not stop before it could be detached.");
      }
      const survivors = this.membersForCheckout(entry.checkoutId)
        .filter((candidate) => candidate.id !== entry.id)
        // A visible member first: handing the workspace to an archived row
        // strands the worktree and its branch behind a session the default
        // list never shows.
        .sort((a, b) =>
          Number(a.archived) - Number(b.archived)
          || b.lastUsedAt - a.lastUsedAt || b.createdAt - a.createdAt || a.id.localeCompare(b.id));
      const successor = survivors[0];
      if (!successor) throw new Error("No checkout member remains to own this workspace.");
      await this.checkoutStore().update(entry.checkoutId, (record) =>
        record.sessionId === entry.id ? { ...record, sessionId: successor.id } : record,
      );
      this.dropSession(entry.id);
      this.clearDeleting(entry.id);
      // Emit owed even when the flush fails: the flag is already cleared, so the
      // catch below can no longer emit and the app's last view of this row would
      // stay `deleting: true` forever.
      try {
        await this.flushNowOrThrow();
      } finally {
        this.notifyObservers();
      }
      return true;
    } catch (error) {
      if (this.clearDeleting(entry.id)) this.notifyObservers();
      throw error;
    }
  }

  /** Returns [initialPrompt] UNCHANGED for a non-fork start — `undefined` must
   *  stay `undefined`, not collapse to `""`: it is what every existing caller
   *  passes to `onStartChat` for "no opening prompt". */
  private forkInitialPrompt(entry: PersistedEntry, initialPrompt?: string): string | undefined {
    if (!entry.forkTranscript) return initialPrompt;
    const extra = initialPrompt?.trim();
    return [
      "Start a fresh conversation using this captured transcript as context. Continue the work; do not resume its native session.",
      "<antgrid-fork-transcript>",
      entry.forkTranscript,
      "</antgrid-fork-transcript>",
      extra,
    ].filter((part): part is string => !!part).join("\n\n");
  }

  private completeForkLaunch(entry: PersistedEntry): void {
    if (entry.conversationStart !== "fork") return;
    // The handoff survives a bridge restart between create and launch, but no
    // longer than the first successful spawn. A later stop/start is a normal
    // fresh conversation and must not replay the old transcript.
    entry.forkTranscript = undefined;
    entry.forkNativeArgs = undefined;
    entry.forkNativeAttempted = undefined;
    entry.conversationStart = "fresh";
  }

  private awaitingNativeForkIdentity(entry: PersistedEntry): boolean {
    return entry.conversationStart === "fork" && (entry.forkNativeArgs?.length ?? 0) > 0;
  }

  /** Initiates teardown; it is NOT complete when this returns. The chat branch
   *  hands back the driver's teardown promise so a caller that restarts this
   *  slot on another runtime can wait it out (see stopAndAwait); every existing
   *  caller ignores it, exactly as before. */
  stop(id: string): void | Promise<void> {
    const entry = this.entries.get(id);
    // Cleared for the same reason archive() clears it: the kill below cannot
    // reach a start that has not happened yet, so a session stopped while its
    // checkout is still provisioning would launch its agent anyway the moment
    // setup settled. The prompt stays in `lastQueuedPrompt` for a rerun.
    const queued = this.setups.get(id);
    const unqueued = queued?.pendingStart !== undefined;
    if (queued) queued.pendingStart = undefined;
    if (entry?.mode === "chat") {
      this.runningChat.delete(id);
      const torndown = this.opts.onStopChat?.(id);
      this.changed();
      return torndown;
    }
    if (!this.tm.has(id)) {
      if (unqueued) this.changed();
      return;
    }
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
    if (!wasChat) {
      // Both signals, not just the exit. `taskkill /T` runs off the event loop
      // now, so the leader can die — and its exit be delivered — while the kill
      // is still walking the rest of the tree; back when the kill was
      // synchronous the exit could not be observed until the tree was gone.
      // `deleteManaged` sweeps the checkout directory the moment this resolves,
      // and one surviving grandchild is a Windows sharing violation.
      // Read before the await: the exit handler drops the session from the map.
      const treeKilled = this.tm.treeKilled(id);
      return this.awaitTerminalExit(id, timeoutMs).then(async (exited) => {
        await treeKilled;
        return exited;
      });
    }
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
    // Either timer being armed, or a fired timer's write still queued on the
    // lock, means a write is pending. Disarm both (a stray
    // timer must not outlive teardown and keep the event loop alive) and do a
    // single final write so the last activity bump survives. The activity
    // timer's wire emit is intentionally dropped — peers re-read persisted
    // lastUsedAt on reconnect.
    //
    // Stays synchronous and off withSessionsFile: teardownServices calls this
    // without awaiting it, so the write has to land on this tick or the last
    // bump is lost on every clean shutdown. Safe without the lock only because
    // the publish itself never suspends — nothing can be half-done to interleave
    // with.
    const dirty = this.flushTimer !== null || this.activityEmitTimer !== null || this.flushQueued;
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
    await withSessionsFile(this.path, async () => {
      writePersistedAtomic(this.path, Array.from(this.entries.values()));
    });
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
    const memberCount = this.countMembersForCheckout(e.checkoutId);
    return {
      id: e.id,
      name: e.name,
      createdAt: e.createdAt,
      lastUsedAt: e.lastUsedAt,
      archived: e.archived,
      running: this.isRunning(e),
      deleting: this.deleting.has(e.id),
      tool: e.tool,
      command: e.command,
      forkSupported: !e.command && !!agentSpec(e.tool ?? this.agentSpec.name),
      forkedFromSessionId: e.forkedFromSessionId,
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
      sharedWorkspace: memberCount > 1,
      // Floored at 1: `main` counts no members, and the wire schema requires a
      // positive integer.
      workspaceMemberCount: Math.max(memberCount, 1),
      setup: this.setupWire(e.id),
    };
  }

  /** The wire view of a session's `worktree.setup` run, absent for a session
   *  that has none. `pendingStart` is derived rather than carried: the queue
   *  itself lives in memory here, and the entry only reports that it exists. */
  private setupWire(sessionId: string): SessionEntry["setup"] {
    const setup = this.setups.get(sessionId);
    if (!setup) return undefined;
    return {
      state: setup.state,
      stepIndex: setup.stepIndex,
      stepCount: setup.stepCount,
      stepName: setup.stepName,
      terminalId: setup.terminalId,
      exitCode: setup.exitCode,
      message: setup.message,
      pendingStart: setup.pendingStart !== undefined,
      startedAt: setup.startedAt,
      finishedAt: setup.finishedAt,
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
    return agentSpec(name)?.augmentsDefaultSpec ? name : undefined;
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

  /** `"<source> fork"`, numbered on collision the way [nextDefaultName] numbers
   *  slots. The suffix is stripped from the source first, so a fork of a fork
   *  reads "Auth fork 2" rather than "Auth fork fork". */
  private forkName(sourceName: string): string {
    const base = sourceName.replace(/ fork(?: \d+)?$/, "").trim() || sourceName;
    const taken = new Set(Array.from(this.entries.values(), (e) => e.name));
    let candidate = `${base} fork`;
    // Terminates: every miss consumes one of the finitely many taken names.
    for (let n = 2; taken.has(candidate); n++) candidate = `${base} fork ${n}`;
    return candidate;
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
      // Queued behind the awaited writers rather than firing into the middle of
      // one. Safe only because flush() snapshots `entries` when it RUNS, so a
      // queued flush publishes current state — never the set as of when it was
      // armed. flushNow() deliberately stays off the lock (see there).
      this.flushQueued = true;
      void withSessionsFile(this.path, async () => {
        this.flushQueued = false;
        this.flush();
      });
    }, FLUSH_DEBOUNCE_MS);
  }

  /** Must keep swallowing I/O errors — it runs from a timer nobody awaits, and
   *  its counterpart flushNowOrThrow is the one that reports them. Reads
   *  `entries` here rather than taking a snapshot at the call site: see
   *  scheduleFlush. */
  private flush(): void {
    try {
      writePersistedAtomic(this.path, Array.from(this.entries.values()));
    } catch (err) {
      log.error("failed to persist sessions.json: %s", err);
    }
  }
}
