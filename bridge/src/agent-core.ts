import { z } from "zod";
import { VERSION } from "./version";
import { join } from "node:path";
import { hostname } from "node:os";
import { spawn, type ChildProcess } from "node:child_process";
import { logger } from "./logger";
const log = logger.child({ component: "agent-core" });
import { TerminalManager } from "./terminal-manager";
import { createKeyedLock } from "./keyed-lock";
import { killChildTree, processGroupSpawn } from "./terminal-session";
import { createConnState, type ConnState } from "./conn-state";
import { FileWatcher } from "./file-watcher";
import { FileUploadManager } from "./file-upload";
import { FileSearcher } from "./file-search";
import { PortDetector } from "./port-detector";
import { TunnelManager } from "./tunnel-manager";
import { type DeviceIdentity } from "./device";
import { displayStartupBanner } from "./banner";
import { generateEphemeralKeypair, type EphemeralKeypair } from "./key-exchange";
import { loadConfig, findConfigFile, projectName, type AbConfig } from "./config";
import { buildConfigFromBootstrap, consoleBootstrapIO, writeConfigYaml } from "./bootstrap";
import { resolveAgent, listKnownTools, oscTitleForNaming, isOscTitleUnusable } from "./known-agents";
import { augmentAgentLaunch } from "./agent-launch-augmenter";
import { CHECKOUT_VARIABLE_MESSAGE_TYPES, createMessage, HandlerConfigureWire, HandlerInstructWire, HandlerUndoWire, type AbMessage, type RpcRequest, type SessionEntry, type WorkStatus } from "./protocol";
import { parseTunnelMessage } from "./tunnel-protocol";
import { startApiServer, type ApiServerHandle, type SessionTitleBody } from "./api-server";
import { MessageBus, type InboundSource } from "./message-bus";
import { resolveAbDir } from "./antgrid-dir";
import { computeProjectId } from "./project-id";
import { loadPairedPhones, type PairedPhonesStore } from "./paired-phones";
import { ConfigController } from "./config-controller";
import { detectInstalledTools } from "./tool-detector";
import { SessionManager, isDefaultSessionName, type DeleteSessionOptions } from "./session-manager";
import { WorktreeError } from "./worktrees/worktree-manager";
import { WorktreeManager } from "./worktrees/worktree-manager";
import { CheckoutStore } from "./worktrees/checkout-store";
import { resolveProject } from "./worktrees/project-resolver";
import { CheckoutRuntimeRegistry } from "./worktrees/checkout-runtime-registry";
import type { CheckoutRecord, CheckoutSetupProgress } from "./worktrees/checkout-types";
import { CheckoutSetupRunner } from "./worktrees/checkout-setup";
import { SessionNamer } from "./session-namer";
import { antigravityCliHome } from "./agents/antigravity/title";
import { AntigravityTitleWatcher } from "./agents/antigravity/title-watcher";
import { resolveStructuredTitle } from "./agents/title-dispatch";
import { generateSessionTitle } from "./agents/title-generate";
import { agentSpec, BY_HOOK_NAME, handlerObservable } from "./agents/registry";
import { HandlerEngine, type HandlerEvent } from "./handler/engine";
import { createEntitlementReader, type TierClaimSource } from "./entitlement";
import { classifyTurnEndError } from "./handler/lifecycle-classify";
import { createDispatchAdapter, createPtyAdapter } from "./handler/session-adapter";
import { createStructuredAdapter } from "./handler/structured-adapter";
import { dispatchRpc } from "./rpc/methods";
import { StructuredAgentManager } from "./structured/structured-manager";
import { TOOL_UPDATE_SPECS, createToolUpdateChecker, execToolUpdate, execToolVersion, parseAgentVersion, runAgentUpdate, updateSpecFor } from "./update/specs";
import { getGitStatus, gitCommit, gitDiscard, gitStage, gitUnstage, type GitFileEntry } from "./git";
import { listLocalBranches, checkoutLocalBranch } from "./git-branches";
import { WORKTREE_SESSIONS_SUPPORTED } from "./worktree-capability";

/** Hand the event loop one full turn. `setImmediate` fires in libuv's check
 *  phase, i.e. AFTER poll, so pending loopback accepts and reads are serviced
 *  before we resume — a microtask (`await Promise.resolve()`) would not be.
 *  Placed before each checkout's synchronous file-tree walk: bun runs one JS
 *  thread, a project open walks the repo AND every managed worktree, and back
 *  to back those walks outlast the app's 2s `project:list` liveness ping, which
 *  reaps a healthy host mid-open (see file-watcher.ts's startWatching note). */
const yieldToEventLoop = () => new Promise<void>((r) => setImmediate(r));

type CheckoutAgentSpec = {
  command: string;
  name: string;
  args?: string[];
  workingDir?: string;
};

/** All filesystem-sensitive state for one checkout. Repository-wide session,
 * handler and structured-agent coordinators intentionally live outside it. */
interface CheckoutRuntime {
  checkout: CheckoutRecord;
  config: AbConfig;
  agentSpec: CheckoutAgentSpec;
  configController: ConfigController;
  fileWatcher: FileWatcher | null;
  fileSearcher: FileSearcher | null;
  uploadManager: FileUploadManager | null;
  portDetector: PortDetector | null;
  tunnelManager: TunnelManager | null;
  runningCommands: Map<string, ChildProcess>;
  cachedGitBranch: string | null;
  cachedGitFiles: GitFileEntry[];
  gitBranchInterval: ReturnType<typeof setInterval> | null;
  gitRefreshTimer: ReturnType<typeof setTimeout> | null;
  /** Fire-and-forget `git status` reads still running against this checkout —
   * see [trackGitRefresh] for why teardown has to wait them out. */
  pendingGitRefreshes: Set<Promise<unknown>>;
  /** Start-order tickets for [refreshGitStatus]; `gitStatusApplied` is the
   * highest whose result reached `cachedGitFiles`. */
  gitStatusSeq: number;
  gitStatusApplied: number;
  configuredTerminalIds: Map<string, string>;
  /** True while the `services` block is held back for a `worktree.setup` run.
   * [startDeferredServices] is the only thing that clears it — a service
   * started against a worktree whose dependencies are still installing fails
   * before the user has seen the session. */
  servicesDeferred: boolean;
  started: boolean;
  /** This runtime is being torn down, or already has been. Never cleared — a
   * torn-down runtime is replaced, never revived.
   *
   * Not the mechanism that keeps a build and a teardown apart; that is
   * [withCheckoutRuntimeLock]. This is for the two readers that cannot take
   * that lock and would otherwise touch a checkout mid-delete: `resyncState`,
   * which runs on every app handshake, and the process-wide shutdown sweep.
   * Both walk the registry, and the row survives until the sweep's last line.
   *
   * `started` cannot carry it: that is a claim-the-slot flag set on the way IN,
   * so it reads `true` for a runtime half-built, fully built, or already dead. */
  disposed: boolean;
}

// Tracks terminal ids that have pinged /hook-alive (a SessionStart probe an
// agent's injection may declare). Module-level so it lives as long as the
// process — terminals cleared from this Set on exit aren't re-added, keeping
// the warning one-shot per spawn.
const hookAlivePinged = new Set<string>();

export function buildAgentHello(cfg: AbConfig, version: string): AbMessage {
  return createMessage("agent:hello", {
    tool: cfg.agent?.tool,
    command: cfg.agent?.command,
    version,
    flags: cfg.agent?.flags,
  });
}

// Reuse the terminal-mode title injection for chat spawns: same plugin/config
// args, but correlated to the chat slot id (not a PTY) and pointed at this
// core's api server. ANTGRID_API_PORT is mandatory for the Claude hook runner.
export function buildChatSpawnAugment(
  tool: string,
  slotId: string,
  apiPort: number | null,
  abDir?: string,
): { args: string[]; env: Record<string, string> } {
  const aug = augmentAgentLaunch(tool, abDir);
  return {
    args: aug.args,
    env: {
      ...aug.env,
      ANTGRID_TERMINAL_ID: slotId,
      ...(apiPort != null ? { ANTGRID_API_PORT: String(apiPort) } : {}),
    },
  };
}

/**
 * Whether a `terminal:input` payload submitted a prompt, for the work-status
 * turn inference agents without a pre-turn hook depend on (see work-status.ts).
 *
 * A TUI submits on CR, so that's the signal — but only as the FINAL byte, and
 * never behind ESC: `\x1b\r` is alt+enter, which inserts a newline into a
 * multi-line prompt rather than sending it. Treating that as a submit would open
 * a turn nothing is going to close, which is exactly the stale "working" dot the
 * turn model exists to avoid. Shift+enter under the kitty protocol
 * (`\x1b[13;2u`) carries no CR at all and needs no special case.
 */
export function isSubmitKeystroke(data: string): boolean {
  return data.endsWith("\r") && !data.endsWith("\x1b\r");
}

/**
 * Whether a `terminal:input` payload carried anything BESIDES the submitting CR.
 *
 * A PTY delivers one keystroke per frame, so the CR that submits a prompt almost
 * always arrives alone — which makes {@link isSubmitKeystroke} on its own unable
 * to tell "the user sent a prompt" from "the user pressed enter on an empty
 * prompt, or to dismiss a TUI menu". The latter starts no turn, so nothing will
 * ever close the one it opens. work-status.ts pairs the two: a keystroke-inferred
 * turn needs typed content since the last one (see `typedSessions`).
 *
 * Escape sequences count as content on purpose — arrow-key history recall then
 * enter IS a submit, and the alternative (dropping it) loses a real turn.
 */
export function hasTypedContent(data: string): boolean {
  return data.replace(/\r$/, "").length > 0;
}

/**
 * Whether a `terminal:input` payload was a bare Escape keypress — the
 * interactive interrupt shortcut every agent CLI honors, and the only signal
 * a hook-based session gets that the user meant to abort a running turn.
 *
 * Exactly `\x1b` and nothing else: any longer sequence starting with ESC
 * (arrow keys, function keys, alt+key, kitty-protocol chunks, alt+enter's
 * `\x1b\r`) is content, not an interrupt, and must not be misread as one — a
 * PTY assembles a full escape sequence before writing it, so a lone ESC byte
 * in one frame unambiguously means the user pressed just that key.
 */
export function isInterruptKeystroke(data: string): boolean {
  return data === "\x1b";
}

export interface AgentCore {
  /** Wire up an outbound transport. The bus's inbound handler is set so the
   *  transport can dispatch incoming messages back into core. */
  attachTransport(bus: MessageBus): void;
  /** Tear down all managers and intervals. Caller closes its own transport.
   *  Returns the number of terminals that were closed. */
  shutdown(): Promise<number>;
  /** Identity + transport configuration the caller uses to construct a
   *  RelayClient (or other transports). */
  readonly relayUrl: string | null;
  readonly identity: DeviceIdentity;
  readonly projectId: string;
  readonly abDir: string;
  readonly nextKeypair: () => EphemeralKeypair;
  /** Machine-level phone registry (identity, label, push routing), shared across
   *  projects. Not an authorization store — see remote-access-policy.ts. */
  readonly pairedPhones: PairedPhonesStore;
  /** The owner's work reduction moved: re-emit `session:updated` so the
   *  `workStatus` stamped on each entry (from
   *  {@link BuildAgentCoreOptions.sessionWorkStatusFor}) is current. No-op
   *  before setupServices. */
  refreshSessionWork(): void;
  /** Host-level checkouts bypass the inbound Git handler, so callers use this
   *  to keep the core's branch and file snapshots coherent immediately. */
  refreshGitState(): Promise<void>;
  /** Lifecycle hooks the transport invokes. */
  handleTunnelMessage(raw: unknown): void;
  onHandshakeComplete(): void;
  /** Wire the transport's plaintext (tunnel) sender. The MessageBus only
   *  carries strict AbMessages; tunnel-protocol messages bypass the bus
   *  and are sent through this hook directly. Pass `null` to clear it (the
   *  promotion controller does this on teardown so a dead relay closure
   *  isn't retained). */
  setPlainHook(fn: ((data: object) => void) | null): void;
  /** Wire a provider that returns the Ed25519 pubkey (standard base64) of the
   *  phone currently paired on the transport, or null when there is no relay
   *  peer (e.g. local/loopback transport, or pre-handshake). The mobile-access
   *  gate consults this only to tell a remote peer from the local owner — it
   *  authorizes nothing per phone. The remote transport wires it to
   *  `RelayClient.currentPeerPubkey()`; local mode never sets it (so it stays
   *  null and the gate is skipped). Pass `null` to clear it. */
  setPeerPubkeyProvider(fn: (() => string | null) | null): void;
  /** Current remote app capability; cleared when that transport detaches. */
  setPeerCheckoutRoutingProvider(fn: (() => boolean) | null): void;
  /** Stream-gating state. The transport's peer-online/offline callbacks flip
   *  `peerOnline` to suppress the heavy stream while the paired phone is gone. */
  readonly connState: ConnState;
  /** Delete a session via the live SessionManager (kills its PTY, flushes
   *  sessions.json, emits session:updated). Returns false if sessions aren't
   *  initialized yet (pre-handshake). The control-plane delete RPC calls this
   *  for a warm core so the on-disk file and in-memory state stay consistent. */
  deleteSession(id: string, options?: DeleteSessionOptions): boolean | Promise<boolean>;
  /** Live session list with true per-session `running` (via SessionManager's
   *  in-memory PTY/chat sets), for the control-plane `sessions.list` peek when a
   *  warm core owns the project — the disk-only `readPersisted` reports every
   *  session not-running. Returns null before sessions are initialized
   *  (pre-handshake), signalling the caller to fall back to the on-disk list. */
  listSessions(includeArchived: boolean): SessionEntry[] | null;
  /** True when any of this project's sessions runs somewhere other than main's
   *  working tree, and therefore needs checkout-scoped routing. */
  hasIsolatedSessions(): boolean;
  /** True when a work-status key is bound to the main checkout (or is not a
   *  session at all). Pre-handshake this answers true — nothing is isolated
   *  yet, so no guard should be narrowed away. */
  isMainCheckoutSession(id: string): boolean;
  /** [client]'s socket closed — it stops vouching for whatever it had on
   *  screen. Mirrors the work reduction's own `clientGone`: without it a
   *  desktop that quit, or a phone that dropped off the relay, would keep one
   *  session permanently "on screen" and mute its setup push forever. */
  noteClientGone(client: InboundSource): void;
}

export interface BuildAgentCoreOptions {
  folder: string;
  configPath?: string;
  /**
   * Determines which transport the agent will use.
   * - "local": loopback-only, no relay required
   * - "remote": connects to the relay using the supplied identity + OAuth token
   */
  mode: "local" | "remote";
  /**
   * Always required. In remote mode, populated from the stdin bootstrap payload.
   * In local mode, synthesized with a random UUID.
   */
  identity: DeviceIdentity;
  /** Shared machine-level paired-phones store. When omitted, a machine-level
   *  store is loaded from abDir (single shared file, not per-project). Identity,
   *  labels and push routing only — it carries no authorization. */
  pairedPhones?: PairedPhonesStore;
  /** Whether this machine is reachable from mobile — the sole authorization gate
   *  for a remote phone (see remote-access-policy.ts). Host-supplied; a bare
   *  agent with no host omits it and the gate reads FAIL-CLOSED, so an
   *  unwired core can never be driven by a phone. */
  remoteAccessEnabled?: () => boolean;
  /** Live reading of this machine's device credential, for the entitlement gate
   *  on paid capabilities (see entitlement.ts). Host-supplied. Absent means a
   *  runtime that never had a token — a bare agent, a signed-out desktop, a
   *  test — and reads as UNWIRED, which is allowed: the gate must not brick
   *  local/offline work that no plan charges for. A credentialed machine whose
   *  claim will not read is the fail-closed case, and it is expressed inside
   *  {@link TierClaim}, not by this option's absence. */
  tierClaim?: TierClaimSource;
  /** Fired when a turn-start hook pings the api-server (`POST /turn-start`), so
   *  the owning ProjectCore can reset its control-plane work status to "working"
   *  on a fresh turn. Bridge-internal — never surfaces to the app.
   *  [sessionId] is the session the hook fired for, when it carried one. */
  onTurnStart?: (sessionId?: string) => void;
  /** Fired when the user types into [sessionId]'s PTY, so the owning ProjectCore
   *  can clear a block the hook reported. Bridge-internal, and NOT a turn-start
   *  on its own: typing in an idle session is not work. `submitted` (the input
   *  carried a CR) is a turn-start only for agents that have no pre-turn hook,
   *  and only once `typed` has reported content for that session — a bare enter
   *  submits nothing (see {@link hasTypedContent}). */
  onUserReply?: (
    sessionId: string,
    opts: { submitted: boolean; typed: boolean },
  ) => void;
  /** Fired when the user resolves a permission/question on [sessionId], so the
   *  owning ProjectCore can clear the block and resume the turn. Distinct from
   *  {@link onTurnStart}: it opens a turn only if something was actually
   *  pending. Bridge-internal — never surfaces to the app. */
  onAnswer?: (sessionId: string, requestId?: string) => void;
  /** Fired when the user presses a bare Escape key into [sessionId]'s PTY (see
   *  {@link isInterruptKeystroke}), so the owning ProjectCore can close the
   *  turn the hook model has no other way to end. A hook-based session's only
   *  turn-end signal is its own Stop/completion hook, which most agent CLIs
   *  never fire on a manual interrupt — without this the working dot outlives
   *  an Esc that genuinely aborted the turn. Bridge-internal — never surfaces
   *  to the app, and purely a work-status close: the keystroke itself already
   *  reached the CLI via the normal PTY write and is what actually interrupts
   *  it. A later real turn-end/notification for the same turn is harmless
   *  (closeTurn is idempotent on an already-closed turn). */
  onInterrupt?: (sessionId: string) => void;
  /** Fired when a client says [sessionId] is on screen (`session:focus`), so the
   *  owning ProjectCore can clear its unread mark and record where that client
   *  is looking. [client] is the inbound source — the desktop over loopback vs
   *  the phone over the relay — and the read state is per-client, so the two
   *  never take each other's dots down. Bridge-internal — never surfaces to the
   *  app. */
  onSessionFocus?: (sessionId: string, client: InboundSource) => void;
  /** Fired when a client declares whether it can render this project at all
   *  (`client:focus-state`), so the owning ProjectCore knows THAT client is
   *  looking at nothing here and a turn ending now is unseen by it. Separate
   *  from {@link ConnectionState.appFocusPaused}, which gates the heavy stream
   *  and the fallback push: this one only feeds the work-status read state. */
  onClientFocusState?: (paused: boolean, client: InboundSource) => void;
  /** This session's status in the owner's work reduction, stamped onto each
   *  `session:updated` entry so the app has a per-session status on the LIVE
   *  session stream rather than only on the advert. The owner must call
   *  {@link AgentCore.refreshSessionWork} when the reduction moves — the list
   *  is otherwise only re-emitted when the sessions themselves change. */
  sessionWorkStatusFor?: (sessionId: string) => WorkStatus | undefined;
  /** Relay base URL of the machine socket this core attaches to. Host-supplied
   *  in remote mode: only a standalone agent with an explicit `relayUrl:` in its
   *  antgrid.yaml can learn it from config, so without this a host-spawned
   *  remote core has no relay coordinate to report. */
  relayUrl?: string;
  /** Test-only release-gate override. Production callers omit this and use the
   * central capability constant. */
  worktreeSessionsSupported?: boolean;
}

export async function buildAgentCore(opts: BuildAgentCoreOptions): Promise<AgentCore> {
  // The interactive bootstrap (`consoleBootstrapIO` → @inquirer/prompts) reads
  // stdin. Only the standalone `antgrid init` / `bun run dev` CLI has a TTY;
  // every host-spawned agent (local always, remote when the app starts a
  // project) is headless. Without this gate a host-spawned REMOTE project with
  // no antgrid.yaml deadlocks on the first "Which coding agent?" prompt —
  // core.start() never returns, so the app's project:start times out at 30s
  // ("Could not start project"). Headless → defaults, exactly like local mode.
  const interactive = !!process.stdin.isTTY;

  // Load config (or run interactive bootstrap if none found)
  let config: AbConfig;
  if (opts.configPath || findConfigFile(opts.folder)) {
    config = loadConfig(opts.configPath, opts.folder);
  } else if (opts.mode === "local" || !interactive) {
    log.info(`No antgrid.yaml found; using defaults (${opts.mode} mode, headless)`);
    config = loadConfig(undefined, opts.folder); // returns DEFAULT_CONFIG
  } else {
    console.log("No antgrid.yaml found. Let's set up this workspace.");
    const io = consoleBootstrapIO();
    config = await buildConfigFromBootstrap({ cwd: opts.folder, io });
    const save = await io.confirmSave();
    if (save) {
      writeConfigYaml(join(opts.folder, "antgrid.yaml"), config);
      console.log("Written to antgrid.yaml.");
    }
  }
  const agentName = projectName(config, opts.folder);

  const abDir = resolveAbDir();

  // Identity is always caller-supplied.
  const identity = opts.identity;

  // relayBase is optional: required for remote mode, not for local mode. The
  // host-supplied URL wins — config.relayUrl only exists for a standalone agent
  // that pinned one in its antgrid.yaml.
  const relayBase = opts.relayUrl ?? config.relayUrl ?? null;

  // Lightweight project info used by subsystems
  const project = {
    path: opts.folder,
    name: agentName,
    id: computeProjectId(opts.folder),
  };

  const mainCheckout: CheckoutRecord = {
    id: "main",
    projectId: project.id,
    kind: "main",
    path: project.path,
    branch: null,
    baseRef: null,
    managed: false,
    sessionId: null,
    createdAt: 0,
  };
  const checkoutRuntimes = new CheckoutRuntimeRegistry<
    AbConfig,
    CheckoutAgentSpec,
    CheckoutRuntime
  >(new CheckoutStore(abDir, project.id), mainCheckout);
  const worktreeManager = new WorktreeManager({
    abDir,
    resolveRepoPath: async (projectId) => projectId === project.id ? project.path : undefined,
  });

  // Lazy and memoized, NEVER resolved during setup: it costs a `git` spawn, and
  // a spawn on the boot path delays every core's first frames past the window
  // the app waits for its state snapshot in. Only isolated creation asks.
  let gitRepositoryProbe: Promise<boolean> | null = null;
  function isGitRepository(): Promise<boolean> {
    gitRepositoryProbe ??= resolveProject(project.path)
      .then((resolved) => resolved.isGitRepository)
      .catch(() => false);
    return gitRepositoryProbe;
  }

  const configPath = join(project.path, "antgrid.yaml");
  const configController = new ConfigController(configPath);
  const hasConfigFile = opts.configPath !== undefined || findConfigFile(opts.folder) !== null;
  let needsFirstRun = false;
  // Tool detection is deferred — the first-run wizard requests it on mount
  // via `config:detect-tools`. Running it eagerly here would do up to ~10
  // tools × ~20 PATH dirs × ~4 Windows extensions of sync existsSync/statSync
  // calls before the discovery file is written, blocking app attach.
  // Headless remote-open with no config took the defaults path above (same as
  // local), so it needs the same first-run wizard — otherwise it advertises
  // running with a placeholder, tool-less agent that can't open sessions.
  if (!hasConfigFile && (opts.mode === "local" || !interactive)) {
    needsFirstRun = true;
  }

  // Paired-phone identity/push registry, constructed eagerly so it exists
  // whether the agent runs in local or remote mode.
  const pairedPhones = opts.pairedPhones ?? loadPairedPhones(abDir);
  const remoteAccessEnabled = opts.remoteAccessEnabled ?? (() => false);

  // Resolve synthetic agent terminal (if any)
  interface AgentTerminalSpec {
    terminalId: string;
    name: string;
    command: string;
    args?: string[];
    workingDir?: string;
  }

  function buildAgentTerminalSpec(): AgentTerminalSpec | null {
    if (needsFirstRun) return null;
    if (!config.agent?.tool && !config.agent?.command) return null;
    const tool = config.agent?.tool;
    const knownTools = new Set(listKnownTools());
    let command: string | undefined;
    if (tool && knownTools.has(tool)) {
      command = resolveAgent(tool).bin;
    } else if (config.agent?.command) {
      command = config.agent.command;
    } else if (tool) {
      // tool set but unknown and no explicit command — fall back to tool name
      command = tool;
    }
    if (!command) return null;
    return {
      terminalId: "agent",
      name: tool ?? "agent",
      command,
      args: config.agent?.flags,
      workingDir: config.agent?.workingDir,
    };
  }

  function agentSpecFromConfig(): { command: string; name: string; args?: string[]; workingDir?: string } {
    const spec = buildAgentTerminalSpec();
    if (spec) return { command: spec.command, name: spec.name, args: spec.args, workingDir: spec.workingDir };
    // No agent configured yet (first-run wizard not complete). Use a
    // placeholder; sessions can't be started until config supplies an
    // agent.tool/command. Cold-start logic guards against this.
    return { command: "", name: "agent" };
  }

  function agentSpecForConfig(source: AbConfig): { command: string; name: string; args?: string[]; workingDir?: string } {
    const tool = source.agent?.tool;
    let command = source.agent?.command;
    if (tool && new Set(listKnownTools()).has(tool)) command = resolveAgent(tool).bin;
    if (!command && tool) command = tool;
    return {
      command: command ?? "",
      name: tool ?? "agent",
      args: source.agent?.flags,
      workingDir: source.agent?.workingDir,
    };
  }

  function getServices(): NonNullable<AbConfig["services"]> {
    return config.services ?? [];
  }

  // Shared: generate initial keypair and display banner (same for both modes)
  const initialKeypair = generateEphemeralKeypair();

  // The banner is human-facing. In local mode the agent is spawned headless by
  // the App; banner output goes to a log nobody reads — skip it.
  if (opts.mode === "remote") {
    await displayStartupBanner({
      version: VERSION,
      relayUrl: relayBase,
      identity,
      terminalCount: (buildAgentTerminalSpec() ? 1 : 0) + getServices().length || 1,
      commandCount: config.commands?.length,
      proxyCount: config.ports?.length,
      projectPath: project.path,
      projectId: project.id,
    }).catch((err) => log.warn("Banner display failed: %s", err));
  }

  let manager: TerminalManager | null = null;
  let sessions: SessionManager | null = null;
  let namer: SessionNamer | null = null;
  let antigravityTitleWatcher: AntigravityTitleWatcher | null = null;
  // Slots we've already spent a title-generation spawn on, keyed
  // `<terminalId>:<agentSessionId>`. The /session-title post repeats every turn,
  // so without this a session whose agent never names itself would pay a model
  // call per turn, forever. Keyed by agent session, not slot, so a resume or a
  // fresh thread in the same slot gets one more attempt.
  const titleGenAttempted = new Set<string>();
  let structured: StructuredAgentManager | null = null;
  // Holds this core's api-server handle. Declared before `manager` so the
  // TerminalManager's late-bound getApiPort getter can read `apiServer.port`
  // once the server has started (it starts after the manager is constructed).
  let apiServer: ApiServerHandle | null = null;
  const connState: ConnState = createConnState();
  let configWatchStarted = false;
  const fileWatchers = new Map<string, FileWatcher>();
  let uploadManager: FileUploadManager | null = null;
  const fileSearchers = new Map<string, FileSearcher>();
  let portDetector: PortDetector | null = null;
  let tunnelManager: TunnelManager | null = null;
  // Owner of every terminal id the runtimes have minted, keyed by the id the PTY
  // actually runs under. A configured `terminals:` slot in a non-main checkout
  // runs under a namespaced `<checkoutId>:<name>` id, so neither the session
  // store nor the raw id can say which checkout it belongs to — only the site
  // that minted it can. Session PTYs are keyed by their own id, unnamespaced.
  const terminalOwners = new Map<string, { checkoutId: string; externalId: string }>();
  // What each client last said is on screen (`session:focus`), dropped when it
  // declares it can render nothing here (`client:focus-state`) or when its
  // socket goes away (`noteClientGone`) — the app restates its focus on
  // resume. Read only by the setup push: a run whose
  // banner the user is watching must not also buzz their phone. The work-status
  // read state keeps its own copy in ProjectCore; this one exists because a
  // core has no way back into that reduction.
  const focusedSessionByClient = new Map<InboundSource, string>();

  function createCheckoutRuntime(
    checkout: CheckoutRecord,
    runtimeConfig: AbConfig,
    agentSpec: CheckoutAgentSpec,
  ): CheckoutRuntime {
    return {
      checkout,
      config: runtimeConfig,
      agentSpec,
      configController: checkout.id === "main"
        ? configController
        : new ConfigController(join(checkout.path, "antgrid.yaml")),
      fileWatcher: null,
      fileSearcher: null,
      uploadManager: null,
      portDetector: null,
      tunnelManager: null,
      runningCommands: new Map(),
      cachedGitBranch: null,
      cachedGitFiles: [],
      gitBranchInterval: null,
      gitRefreshTimer: null,
      pendingGitRefreshes: new Set(),
      gitStatusSeq: 0,
      gitStatusApplied: 0,
      configuredTerminalIds: new Map(),
      servicesDeferred: false,
      started: false,
      disposed: false,
    };
  }

  const mainRuntime = createCheckoutRuntime(mainCheckout, config, agentSpecFromConfig());
  checkoutRuntimes.setRuntime("main", mainRuntime);

  function checkoutIdOf(msg: { checkoutId?: string }): string {
    return msg.checkoutId ?? "main";
  }

  function runtimeFor(msg: AbMessage): CheckoutRuntime {
    const checkoutId = "checkoutId" in msg && typeof msg.checkoutId === "string"
      ? msg.checkoutId
      : "main";
    return checkoutRuntimes.runtime(checkoutId) ?? mainRuntime;
  }

  function sendFromRuntime(runtime: CheckoutRuntime, msg: AbMessage, force = false): void {
    const stamped = { ...msg, checkoutId: runtime.checkout.id } as AbMessage;
    if (force) republishAb(stamped); else sendAb(stamped);
  }

  function internalTerminalId(runtime: CheckoutRuntime, terminalId: string): string {
    if (sessions?.get(terminalId) || runtime.checkout.id === "main") return terminalId;
    const namespaced = runtime.configuredTerminalIds.get(terminalId)
      ?? `${runtime.checkout.id}:${terminalId}`;
    runtime.configuredTerminalIds.set(terminalId, namespaced);
    // Re-recorded on every call, not just the first: terminal exit drops the
    // owner row, and a restarted slot reuses the same namespaced id.
    terminalOwners.set(namespaced, { checkoutId: runtime.checkout.id, externalId: terminalId });
    return namespaced;
  }

  /** Filesystem root a supervised slot actually runs in. Falls back to the
   *  project path for a terminal-less (project-wide) caller. */
  function checkoutPathFor(terminalId?: string): string {
    if (!terminalId) return project.path;
    return terminalOwner(terminalId).runtime.checkout.path;
  }

  function terminalOwner(terminalId: string): { runtime: CheckoutRuntime; externalId: string } {
    const owner = terminalOwners.get(terminalId);
    const checkoutId = sessions?.get(terminalId)?.checkoutId ?? owner?.checkoutId ?? "main";
    return {
      runtime: checkoutRuntimes.runtime(checkoutId) ?? mainRuntime,
      externalId: owner?.externalId ?? terminalId,
    };
  }

  function sendTerminalFrame(msg: AbMessage): void {
    const terminalId = "terminalId" in msg && typeof msg.terminalId === "string"
      ? msg.terminalId
      : null;
    if (!terminalId) { sendAb(msg); return; }
    const { runtime, externalId } = terminalOwner(terminalId);
    sendFromRuntime(runtime, { ...msg, terminalId: externalId } as AbMessage);
  }

  function nextKeypair(): EphemeralKeypair {
    return generateEphemeralKeypair();
  }

  // "Is this a REMOTE peer?" signal, not an authorization input. Wired by the
  // remote/promotion transports to RelayClient.currentPeerPubkey(); unset (null)
  // in local mode, where there is no relay peer.
  let peerPubkeyProvider: (() => string | null) | null = null;
  let peerCheckoutRoutingProvider: (() => boolean) | null = null;
  function setPeerPubkeyProvider(fn: (() => string | null) | null) {
    peerPubkeyProvider = fn;
  }
  function setPeerCheckoutRoutingProvider(fn: (() => boolean) | null) {
    peerCheckoutRoutingProvider = fn;
  }

  // Mobile-access gate, shared by every inbound path (bus verbs AND the
  // tunnel/HTTP-proxy path, which bypasses the bus). An account-trusted phone
  // may drive this project only while the machine is mobile-reachable. When no
  // phone pubkey is present (local/loopback transport has no relay peer) the
  // gate is skipped — local control's trust boundary is the loopback socket +
  // token, and the desktop must keep driving its own machine with mobile access
  // off. Fail-closed otherwise: an unwired provider defaults to disabled.
  function currentPhoneAllowed(): boolean {
    const phonePubkey = peerPubkeyProvider?.() ?? null;
    if (!phonePubkey) return true;
    return remoteAccessEnabled();
  }

  function currentPeerCanRouteCheckouts(): boolean {
    return peerCheckoutRoutingProvider?.() === true;
  }

  function handleTunnelMessage(raw: unknown) {
    const msg = parseTunnelMessage(raw as string | object);
    if (!msg) { log.warn("Invalid tunnel message, dropping"); return; }
    // Tunnel verbs proxy arbitrary HTTP to localhost:<port> and return the body,
    // so a phone could otherwise read a project's dev-server/preview data
    // without ever touching the bus dispatch gate. Gate here too.
    if (!currentPhoneAllowed()) {
      log.warn("Dropping tunnel %s: mobile access is disabled (project %s)", msg.type, project.id);
      return;
    }
    const runtime = checkoutRuntimes.runtime(msg.checkoutId);
    if (!runtime) {
      log.warn("Dropping tunnel request for unknown checkout %s", msg.checkoutId);
      return;
    }
    if (msg.type === "tunnel:http-request" && runtime.tunnelManager) {
      runtime.tunnelManager.onHttpRequest(msg).catch((err) =>
        log.error("tunnel:http-request handler failed: %s", err)
      );
    }
  }

  // [client] is who sent this frame — needed only by the work-status read state,
  // which tracks what each client has on screen separately. Everything else in
  // here is authorized at the bus handler and does not care.
  function handleAbMessage(msg: AbMessage, client: InboundSource) {
    switch (msg.type) {
      case "agent:prompt":
      case "agent:permission-resolve":
      case "agent:question-resolve":
        // A human answer from the app — reset the runaway guard and clear
        // pending escalations, mirroring what terminal:input does for PTY
        // slots. The "\r" sentinel exists because onUserReply's CR gate is
        // built for per-keystroke PTY input; an app-routed prompt/resolve IS
        // a submitted answer by definition. The engine's own auto-reply calls
        // structured.handleAgentMessage directly and never passes through
        // here (it must not reset the guard that counts it).
        //
        // Only a RESOLVE retires a `resolve_in_session` escalation, and only the
        // row for the prompt it names: it carries the permissionId/questionId the
        // blocked driver is waiting on. A bare prompt is injected text, which such
        // a prompt cannot consume — clearing its row would blank the "needs you"
        // pill on a session that is still blocked.
        handlerEngine.onUserReply(msg.sessionId, "\r", {
          resolvedPromptId: msg.type === "agent:permission-resolve"
            ? msg.permissionId
            : msg.type === "agent:question-resolve" ? msg.questionId : undefined,
        });
        // A RESOLVE additionally unblocks the session: the block is gone and the
        // agent resumes on THIS session, so report it now rather than waiting for
        // the driver's next outbound frame — that is what flips the session's dot
        // from "needs you" back to "working" the instant the user replies. A bare
        // prompt is excluded; its driver emits a real `agent:turn-start`. Not
        // onTurnStart either: a resolve that raced a retraction has nothing to
        // resume, and must not open a turn nothing will close. Named, for the
        // same reason the escalation above is: one answer unblocks one prompt.
        if (msg.type !== "agent:prompt") {
          opts.onAnswer?.(
            msg.sessionId,
            msg.type === "agent:permission-resolve" ? msg.permissionId : msg.questionId,
          );
        }
        void structured?.handleAgentMessage(msg);
        return;
      case "agent:cancel":
        // Not onUserReply: a cancel is not an answer, so pending escalations
        // stand. It does end a self-resuming park, whose only wake path was the
        // driver's retry loop — the very loop this cancel stops.
        handlerEngine.onTurnCancelled(msg.sessionId);
        void structured?.handleAgentMessage(msg);
        return;
      // Pure routing, deliberately: stopping ONE background task neither answers
      // a prompt (no onUserReply — pending escalations stand) nor ends the turn
      // the task was spawned from (no onTurnCancelled — the agent keeps working).
      case "agent:task-stop":
      case "agent:set-config":
      case "agent:session-action":
        void structured?.handleAgentMessage(msg);
        return;
    }
    if (!manager) return;
    const runtime = runtimeFor(msg);
    switch (msg.type) {
      case "terminal:input":
        manager.write(internalTerminalId(runtime, msg.terminalId), msg.data);
        // Typing into a session counts as activity — float it up the drawer.
        // No-ops for non-session terminals (service PTYs).
        sessions?.touch(msg.terminalId);
        // A user reply resets the handler's runaway guard; a submitted line
        // (data carrying CR/LF) also clears the pending escalations.
        handlerEngine.onUserReply(msg.terminalId, msg.data);
        // ...and answers whatever the hook reported this session as blocked on.
        // A terminal-mode session has no resolve frame — the keystroke IS the
        // answer — so without this its "needs you" dot outlives the block. A
        // SUBMIT additionally means "prompt started", the only turn-start an
        // agent without a pre-turn hook can give us (see work-status.ts).
        opts.onUserReply?.(msg.terminalId, {
          submitted: isSubmitKeystroke(msg.data),
          typed: hasTypedContent(msg.data),
        });
        if (isInterruptKeystroke(msg.data)) opts.onInterrupt?.(msg.terminalId);
        break;
      case "handler:configure": {
        // parseMessageFast (the encrypted/local hot path) validates only the
        // message type — every field below is still untrusted, so every field
        // arming acts on has to be re-parsed, not just the ones the sender
        // happened to fill in: a `notifyOnly` that arrives absent or non-bool
        // reads as falsy and would arm an auto-injecting session the user asked
        // to be notify-only.
        const parsed = HandlerConfigureWire.safeParse(msg);
        if (parsed.success && parsed.data.armed) {
          const { terminalId, goal, backlog, notifyOnly, judgeTool, judgeModel } = parsed.data;
          handlerEngine.arm({ terminalId, goal, backlog, notifyOnly, judgeTool, judgeModel });
        } else if (parsed.success) {
          handlerEngine.disarm(parsed.data.terminalId);
        } else {
          // Reject WITHOUT disarming: a malformed arm/edit must not tear down
          // the live armed session it failed to replace, and refusing to arm
          // already closes the notifyOnly hole. Re-emit status so the sender's
          // UI resyncs to the state that actually holds.
          logger.warn("handler:configure rejected: malformed payload");
          handlerEngine.emitStatus();
        }
        break;
      }
      case "handler:instruct": {
        // Same re-parse discipline as handler:configure above: parseMessageFast
        // validated the type and nothing else, and this text is interpolated into
        // the extraction prompt.
        const parsed = HandlerInstructWire.safeParse(msg);
        if (parsed.success) {
          handlerEngine.instruct({ terminalId: parsed.data.terminalId, text: parsed.data.text });
        } else {
          // Rejected WITHOUT disarming, for the same reason a malformed arm is: a
          // bad instruct must not tear down the live armed session it was meant to
          // add to. Re-emit status so the sender's UI resyncs.
          logger.warn("handler:instruct rejected: malformed payload");
          handlerEngine.emitStatus();
        }
        break;
      }
      case "handler:undo": {
        // Same re-parse discipline as the two above: parseMessageFast validated the
        // type and nothing else, and this id selects a filesystem/git operation.
        const parsed = HandlerUndoWire.safeParse(msg);
        if (parsed.success) {
          // Nothing awaits an inbound frame, and undo() reports its own outcome on
          // the wire, so it carries its own sink.
          void handlerEngine.undo(parsed.data.snapshotId).catch((err) => {
            logger.warn("handler:undo failed: %s", err);
          });
        } else {
          // Rejected WITHOUT disarming, for the same reason a malformed arm is: a
          // bad undo must not tear down the live armed session it names nothing in.
          // Re-emit status so the sender's UI resyncs.
          logger.warn("handler:undo rejected: malformed payload");
          handlerEngine.emitStatus();
        }
        break;
      }
      case "terminal:start": {
        const savedService = (runtime.config.services ?? []).find((s) => s.name === msg.terminalId);
        const isSession = !!sessions?.get(msg.terminalId);
        if (isSession) {
          // Sessions are started via session:start (which goes through pending).
          // A stray terminal:start for a session is ignored.
          break;
        }
        const savedCommand = savedService?.command;
        const savedArgs = savedService?.args;
        const savedCwd = savedService?.workingDir;
        const savedEnv = savedService?.env;
        const savedName = savedService?.name;
        manager.spawn({
          terminalId: internalTerminalId(runtime, msg.terminalId),
          name: msg.name ?? savedName,
          command: msg.command ?? savedCommand,
          args: msg.args ?? savedArgs,
          cwd: msg.cwd ?? savedCwd ?? runtime.checkout.path,
          env: msg.env ?? savedEnv,
          type: savedService ? "service" : undefined,
        });
        sendStatus();
        break;
      }
      case "terminal:stop":
        manager.kill(internalTerminalId(runtime, msg.terminalId));
        sendStatus();
        break;
      case "terminal:resize":
        manager.resize(
          internalTerminalId(runtime, msg.terminalId),
          msg.clientId,
          msg.cols,
          msg.rows,
          msg.baseDriverClientId,
        );
        break;
      case "file:read": {
        const fw = runtime.fileWatcher;
        if (fw) {
          fw.handleFileReadRequest(msg.path);
        } else {
          log.warn("file:read for unknown projectId: %s", msg.projectId);
        }
        break;
      }
      case "file:upload-start":
        runtime.uploadManager?.handleStart(msg);
        break;
      case "file:upload-chunk":
        runtime.uploadManager?.handleChunk(msg);
        break;
      case "file:upload-done":
        runtime.uploadManager?.handleDone(msg);
        break;
      case "file:search": {
        const fs = runtime.fileSearcher;
        if (fs) {
          fs.search({
            projectId: msg.projectId,
            query: msg.query,
            caseSensitive: msg.caseSensitive,
            regex: msg.regex,
            wholeWord: msg.wholeWord,
            requestId: msg.requestId,
          }).catch((err) => log.error("file:search handler failed: %s", err));
        } else {
          log.warn("file:search for unknown projectId: %s", msg.projectId);
        }
        break;
      }
      case "file:search-cancel": {
        const fs = runtime.fileSearcher;
        if (fs) {
          fs.cancel(msg.requestId);
        }
        break;
      }
      case "git:diff": {
        handleGitDiffRequest(runtime, msg.projectId, msg.path).catch((err) =>
          log.error("git:diff handler failed: %s", err)
        );
        break;
      }
      case "git:list-branches": {
        handleGitListBranches(runtime, msg.projectId).catch((err) =>
          log.error("git:list-branches handler failed: %s", err)
        );
        break;
      }
      case "git:checkout": {
        handleGitCheckout(runtime, msg.projectId, msg.branch).catch((err) =>
          log.error("git:checkout handler failed: %s", err)
        );
        break;
      }
      case "git:commit": {
        handleGitCommit(runtime, msg.projectId, msg.message).catch((err) =>
          log.error("git:commit handler failed: %s", err)
        );
        break;
      }
      case "git:discard": {
        handleGitDiscard(runtime, msg.projectId, msg.files, msg.includeStaged === true).catch((err) =>
          log.error("git:discard handler failed: %s", err)
        );
        break;
      }
      case "git:stage": {
        handleGitStage(runtime, msg.projectId, msg.files).catch((err) =>
          log.error("git:stage handler failed: %s", err)
        );
        break;
      }
      case "git:unstage": {
        handleGitUnstage(runtime, msg.projectId, msg.files).catch((err) =>
          log.error("git:unstage handler failed: %s", err)
        );
        break;
      }
      case "command:run": {
        const cmdConfig = runtime.config.commands?.find((c) => c.name === msg.commandName);
        if (!cmdConfig) {
          log.warn("command:run for unknown command: %s", msg.commandName);
          sendFromRuntime(runtime, createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: 1,
          }));
          break;
        }

        // Reject unconfirmed runs of commands marked confirm: true
        if (cmdConfig.confirm && !msg.confirmed) {
          log.warn("command:run rejected — '%s' requires confirmation", msg.commandName);
          sendFromRuntime(runtime, createMessage("command:output", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            data: "Error: command requires confirmation (confirmed: true)\n",
          }));
          sendFromRuntime(runtime, createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: 1,
          }));
          break;
        }

        const args = cmdConfig.args ?? [];
        const cwd = cmdConfig.workingDir ?? runtime.checkout.path;
        const env = cmdConfig.env ? { ...process.env, ...cmdConfig.env } : undefined;

        // Commands are defined in the local config file, not supplied by remote clients.
        // shell: true is safe here because command strings come from antgrid.yaml.
        // That wrapper is also why the spawn must lead its own process group:
        // the handle below is the shell, and teardown has to reach past it to
        // the command actually sitting in the checkout.
        const proc = spawn(cmdConfig.command, args, {
          cwd,
          env,
          shell: true,
          stdio: ["ignore", "pipe", "pipe"],
          ...processGroupSpawn(),
        });

        const cmdKey = `${msg.projectId}:${msg.commandName}`;
        runtime.runningCommands.set(cmdKey, proc);

        const streamOutput = (stream: NodeJS.ReadableStream) => {
          stream.on("data", (chunk: Buffer) => {
            sendFromRuntime(runtime, createMessage("command:output", {
              projectId: msg.projectId,
              commandName: msg.commandName,
              data: chunk.toString(),
            }));
          });
        };

        if (proc.stdout) streamOutput(proc.stdout);
        if (proc.stderr) streamOutput(proc.stderr);

        proc.on("close", (code) => {
          runtime.runningCommands.delete(cmdKey);
          sendFromRuntime(runtime, createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: code,
          }));
        });

        proc.on("error", (err) => {
          runtime.runningCommands.delete(cmdKey);
          sendFromRuntime(runtime, createMessage("command:output", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            data: `Error: ${err.message}\n`,
          }));
          sendFromRuntime(runtime, createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: 1,
          }));
        });

        log.info("Command '%s' started for project '%s'", msg.commandName, msg.projectId);
        break;
      }
      case "agent:update": {
        // In-app self-update. Reaches here only through the mobile-access gate, so no
        // extra authz. Dispatch by canonical tool id; a tool with no known self-
        // updater fails soft with a message (never touches an install).
        const spec = updateSpecFor(msg.tool);
        if (!spec) {
          sendAb(createMessage("agent:updateResult", {
            tool: msg.tool, sessionId: msg.sessionId, ok: false,
            output: `In-app update is not supported for ${msg.tool}.`,
          }));
          break;
        }
        // Quiesce EVERY live chat session of THIS tool, not just the requesting
        // one: the update replaces one machine-global binary, and any peer left
        // running would hold it (a Windows in-use failure). Snapshot the ids now,
        // before we stop them, so we know exactly what to bring back afterward.
        // Via agentKeyFor, not `s.tool`: a SessionEntry carries `tool` only when
        // it OVERRODE the project's agent.tool, so every default-spec session
        // reads as untooled. A literal default here quiesces the wrong agent's
        // sessions, and the ones actually holding the binary keep holding it.
        const chatIds = (sessions?.list(true) ?? [])
          .filter((s) => s.mode === "chat" && agentKeyFor(s.id) === spec.tool && s.running)
          .map((s) => s.id);
        log.info("agent:update — quiescing %d %s session(s) to update", chatIds.length, spec.tool);
        void runAgentUpdate({
          sessionIds: chatIds,
          // stopChat resolves only once the process has exited (its dispose awaits
          // proc.exited), so awaiting it releases the binary handle + any per-tool
          // lock. start() re-spawns on the fresh binary and resumes the thread.
          stop: (id) => structured?.stopChat(id) ?? Promise.resolve(),
          // Returned, not discarded: an isolated session's start is async and
          // rejects when its worktree has gone, and runAgentUpdate's per-session
          // try/catch is what keeps one dead restart from sinking the rest.
          start: (id) => sessions?.start(id),
          execUpdate: () => execToolUpdate(spec),
          installedAfter: async () => parseAgentVersion(await execToolVersion(spec)),
        }).then((outcome) => {
          sendAb(createMessage("agent:updateResult", {
            tool: spec.tool, sessionId: msg.sessionId, ok: outcome.ok,
            exitCode: outcome.exitCode,
            installed: outcome.installed ?? undefined,
            // Bound the tail so a chatty updater can't bloat the encrypted frame.
            output: outcome.output.slice(-4_000) || undefined,
          }));
        });
        break;
      }
      case "config:read": {
        emitConfigState(runtime);
        break;
      }
      case "config:write": {
        const w = runtime.configController.write(msg.config as import("./config").AbConfig);
        sendFromRuntime(runtime, createMessage("config:write-result", {
          ok: w.ok,
          errors: w.ok ? undefined : w.errors,
        }));
        break;
      }
      case "config:detect-tools": {
        sendFromRuntime(runtime, createMessage("config:detect-tools-result", {
          tools: detectInstalledTools(),
        }));
        break;
      }
      case "session:list": {
        if (!sessions) {
          // Pre-handshake or post-disconnect: respond rather than leave the
          // app's pending request hanging until its own timeout fires.
          sendAb(createMessage("session:list:result", {
            requestId: msg.requestId,
            sessions: [],
          }));
          break;
        }
        sendAb(createMessage("session:list:result", {
          requestId: msg.requestId,
          sessions: sessions.list(msg.includeArchived ?? false),
        }));
        break;
      }
      case "session:create": {
        if (!sessions) {
          sendAb(createMessage("session:result", {
            requestId: msg.requestId, ok: false, error: "agent not ready",
          }));
          break;
        }
        void (async () => {
          try {
            const s = await sessions.create(msg.name, {
              tool: msg.tool,
              command: msg.command,
              args: msg.args,
              mode: msg.mode,
              isolation: msg.isolation ?? "shared",
              baseBranch: msg.baseBranch,
            });
            sendAb(createMessage("session:result", {
              requestId: msg.requestId, ok: true, session: s, checkoutId: s.checkoutId,
            }));
          } catch (err) {
            sendAb(createMessage("session:result", {
              requestId: msg.requestId,
              ok: false,
              error: err instanceof Error ? err.message : "Could not create the session.",
              ...(err instanceof WorktreeError ? { errorCode: err.code } : {}),
            }));
          }
        })();
        break;
      }
      case "session:start":
      case "session:stop":
      case "session:rename":
      case "session:archive":
      case "session:unarchive":
      case "session:delete":
      case "session:set-mode":
      case "session:setup": {
        // Bound to consts so the switch's narrowing and the not-null check below
        // survive into the async closure.
        const verb = msg;
        const s = sessions;
        if (!s) {
          sendAb(createMessage("session:result", {
            requestId: verb.requestId, ok: false, error: "agent not ready",
          }));
          break;
        }
        // Only set-mode (it waits out the old runtime's teardown before
        // restarting on the new one) and setup (a cancel waits out the setup
        // process tree) await. Every other verb still runs straight through to
        // its reply without yielding, since an async body runs synchronously
        // until its first await.
        void (async () => {
          const checkoutId = s.get(verb.sessionId)?.checkoutId ?? "main";
          try {
            if (verb.type === "session:start") await s.start(verb.sessionId, verb.initialPrompt);
            else if (verb.type === "session:stop") s.stop(verb.sessionId);
            else if (verb.type === "session:rename") s.rename(verb.sessionId, verb.name);
            else if (verb.type === "session:archive") s.archive(verb.sessionId);
            else if (verb.type === "session:unarchive") s.unarchive(verb.sessionId);
            else if (verb.type === "session:delete") await s.delete(verb.sessionId, {
              force: verb.force,
              removeCheckout: verb.removeCheckout,
              deleteBranch: verb.deleteBranch,
            });
            else if (verb.type === "session:set-mode") await s.setMode(verb.sessionId, verb.mode);
            else if (verb.type === "session:setup") await s.applySetupAction(verb.sessionId, verb.action);
            const entry = s.get(verb.sessionId);
            sendAb(createMessage("session:result", {
              requestId: verb.requestId, ok: true, session: entry, checkoutId,
            }));
          } catch (err) {
            sendAb(createMessage("session:result", {
              requestId: verb.requestId,
              ok: false,
              error: err instanceof Error ? err.message : "Session operation failed.",
              ...(err instanceof WorktreeError ? { errorCode: err.code } : {}),
              checkoutId,
            }));
          }
        })();
        break;
      }
      case "session:focus": {
        // No requestId on session:focus — silent break is correct.
        // The work-status read state is told FIRST and unconditionally: it is
        // keyed by session id across the whole project, so it must not be lost
        // to a runtime that has no session manager (or has not built one yet).
        opts.onSessionFocus?.(msg.sessionId, client);
        focusedSessionByClient.set(client, msg.sessionId);
        if (!sessions) break;
        sessions.focus(msg.sessionId);
        break;
      }
      case "client:focus-state": {
        connState.appFocusPaused = msg.paused;
        if (msg.paused) focusedSessionByClient.delete(client);
        opts.onClientFocusState?.(msg.paused, client);
        log.info("focus-state: paused=%s", msg.paused);
        break;
      }
      case "terminal:snapshot:request": {
        // Same wrong-checkout guard as the tree and preview requests below, and
        // for the same reason: every checkout runtime sees this frame, so
        // without it one request is answered N times and the app applies
        // whichever reply lands last — another checkout's scrollback, under a
        // seq that then filters the right one's output.
        if (runtime.checkout.id !== checkoutIdOf(msg)) break;
        const snap = manager.getReplaySnapshot(internalTerminalId(runtime, msg.terminalId));
        if (!snap) {
          log.warn("snapshot requested for unknown terminal %s", msg.terminalId);
          break;
        }
        sendFromRuntime(runtime, createMessage("terminal:snapshot", {
          terminalId: msg.terminalId,
          scrollback: snap.text,
          seq: snap.seq,
        }));
        break;
      }
      case "file:tree:snapshot:request": {
        // Answer only the checkout that ASKED. `runtimeFor` falls back to
        // mainRuntime for an id with no runtime yet (an isolated session's
        // bundle is built before its runtime is prepared), and sendFromRuntime
        // restamps the reply with the RESOLVED runtime's id — so a fallback
        // answer is filtered out by the requester and force-pushes main's
        // picture to everyone else instead.
        if (runtime.checkout.id !== checkoutIdOf(msg)) break;
        const fw = runtime.fileWatcher;
        if (!fw) break;
        const { tree, seq } = fw.getTreeSnapshot();
        sendFromRuntime(runtime, createMessage("file:tree:snapshot", { tree, seq }));
        // The app asks for this on every (re)connect and on a pull-to-refresh,
        // and the git decorations belong to the same picture as the tree —
        // answering with a tree alone left the changes list showing whatever
        // the replay cache last held. Forced, not merely unconditional: the
        // request means the app doubts what it has, and a doubted status is
        // usually byte-identical to the cached one — which the bus's dedup
        // drops before any subscriber, leaving a pull-to-refresh with no answer
        // and no way to ever get one.
        trackGitRefresh(
          runtime,
          refreshGitStatus(runtime)
            .then(() => sendGitStatus(runtime, true))
            .catch(() => {}),
        );
        break;
      }
      case "preview:snapshot:request": {
        // Same wrong-checkout guard as the tree request above.
        if (runtime.checkout.id !== checkoutIdOf(msg)) break;
        if (!runtime.tunnelManager) break;
        sendFromRuntime(runtime, createMessage("preview:snapshot", {
          urls: runtime.tunnelManager.getPreviewSnapshot(),
        }));
        // The snapshot carries only config-declared proxies; ad-hoc detections
        // ride `ports:update`, which is pushed on CHANGE alone. Same pairing as
        // the tree request's git status: a caller asking for the preview
        // picture has no other way to learn about a port found before it was
        // listening (an isolated session's bundle is built a round trip after
        // its runtime detected them, and nothing re-pushes a stable set).
        runtime.portDetector?.emitCurrent();
        break;
      }
      case "push:register": {
        const peerPubkey = peerPubkeyProvider?.() ?? null;
        if (!peerPubkey) { log.warn("push:register with no peer pubkey; ignoring"); break; }
        const phone = pairedPhones.get(peerPubkey);
        if (!phone) { log.warn("push:register from unknown phone; ignoring"); break; }
        if (msg.pushToken === "") {
          // Clear signal (sign-out): stop pushing to this phone.
          pairedPhones.upsert({
            ...phone,
            pushToken: undefined,
            pushProvider: undefined,
            pushPubkey: undefined,
            pushUpdatedAt: new Date().toISOString(),
          });
          log.info("Cleared push token for phone %s", phone.phoneDeviceId);
          break;
        }
        pairedPhones.upsert({
          ...phone,
          pushToken: msg.pushToken,
          pushProvider: msg.provider,
          pushPubkey: msg.pushPubkey,
          pushUpdatedAt: new Date().toISOString(),
        });
        log.info("Registered push token for phone %s", phone.phoneDeviceId);
        break;
      }
    }
  }

  async function teardownServices() {
    const pending: Promise<void>[] = [];
    for (const runtime of checkoutRuntimes.values()) {
      for (const proc of runtime.runningCommands.values()) {
        pending.push(killChildTree(proc));
      }
      runtime.runningCommands.clear();
      runtime.configController.stopWatch();
      runtime.fileWatcher?.stop();
      runtime.uploadManager?.stop();
      runtime.portDetector?.stop();
      runtime.tunnelManager?.stop();
      if (runtime.gitBranchInterval) clearInterval(runtime.gitBranchInterval);
      runtime.gitBranchInterval = null;
      if (runtime.gitRefreshTimer) clearTimeout(runtime.gitRefreshTimer);
      runtime.gitRefreshTimer = null;
      runtime.started = false;
      // Shutdown does NOT take the runtime lock — it cannot, it is the thing
      // every lock holder would be waiting behind — so this is what stops a
      // `startCheckoutRuntime` parked on a suspension from resuming and
      // re-arming a watcher the core has already stopped. It also spawns
      // through `manager`, nulled two lines below.
      runtime.disposed = true;
    }
    manager?.killAll();
    manager = null;
    for (const fw of fileWatchers.values()) fw.stop();
    fileWatchers.clear();
    uploadManager?.stop();
    uploadManager = null;
    portDetector?.stop();
    portDetector = null;
    tunnelManager?.stop();
    tunnelManager = null;
    sessions?.flushNow();
    sessions = null;
    namer?.dispose();
    namer = null;
    antigravityTitleWatcher?.stop();
    antigravityTitleWatcher = null;
    void structured?.disposeAll();
    structured = null;
    await Promise.all(pending);
  }

  // Outbound senders — initially no-op until a transport is attached.
  let sendAb: (msg: AbMessage) => void = (_m) => {};
  /** Same wire as [sendAb] but bypasses the bus's payload-equality dedup. Only
   *  the explicit re-sync paths use it — see MessageBus.republish. */
  let republishAb: (msg: AbMessage) => void = (_m) => {};
  let sendPlain: (data: object) => void = (_d) => {};
  // Replay-cache eviction for torn-down chat sessions; bound with the bus in
  // attachTransport, like sendAb.
  let dropSessionReplay: (sessionId: string) => void = (_s) => {};
  let dropCheckoutReplay: (checkoutId: string) => void = (_c) => {};
  let isShuttingDown = false;

  // Kept as the single funnel for notification:push producers even though it now
  // only forwards: the work reduction folds these off the bus
  // (ProjectCore.observeWorkStatus), so a producer that bypassed sendAb entirely
  // is the one mistake that would still lose the signal.
  function sendNotifying(msg: AbMessage): void {
    sendAb(msg);
  }

  // Eager, factory-scoped (NOT in setupServices): handleAbMessage and startApiServer
  // are wired synchronously and can fire before setupServices resolves. The arrow
  // deps defer their reads, so a later-assigned sendAb/manager/sessions is picked
  // up correctly, same pattern as the existing manager? deps.
  // Which agent this slot ACTUALLY runs, or undefined when the project names
  // only a custom `agent.command` — an arbitrary binary attributable to no spec.
  const agentKeyFor = (terminalId?: string): string | undefined =>
    (terminalId ? sessions?.get(terminalId)?.tool : undefined) ?? config.agent?.tool;
  // Judging needs *a* CLI to spawn, so an unattributable slot still resolves to
  // one. Observability must NOT: reporting the default agent's hooks for a
  // binary we cannot identify is the "armed and quiet" lie observability exists
  // to end, so it answers from the real key and unknown reads as unsupported.
  const toolFor = (terminalId?: string): string => agentKeyFor(terminalId) ?? "claude-code";
  const handlerEngine = new HandlerEngine({
    projectId: project.id,
    projectPath: (terminalId) => checkoutPathFor(terminalId),
    tool: toolFor,
    // Handler is a paid capability. The predicate is built once and reads the
    // credential live on every call; the registry it consults is the single
    // place the queued capabilities (devcontainer, …) get added.
    entitlement: createEntitlementReader(opts.tierClaim),
    observable: (terminalId) => handlerObservable(
      agentKeyFor(terminalId),
      sessions?.get(terminalId)?.mode === "chat" ? "chat" : "terminal",
    ),
    agentSessionId: (terminalId) => sessions?.get(terminalId)?.agentSessionId,
    abDir,
    adapter: createDispatchAdapter({
      isChat: (id) => sessions?.get(id)?.mode === "chat",
      pty: createPtyAdapter({
        write: (terminalId, data) => manager?.write(terminalId, data),
        getRecentOutput: (terminalId) => manager?.getScrollback(terminalId)?.text ?? "",
        getTranscriptPath: (terminalId) => sessions?.getAgentTranscriptPath(terminalId),
      }),
      chat: createStructuredAdapter({
        // Through handleAgentMessage, not driver.prompt directly: a dead or
        // missing driver then surfaces as agent:error instead of a silent
        // throw. This path never re-enters handleAbMessage, so an auto-reply
        // cannot reset the runaway guard that counts it.
        prompt: (id, text) => {
          // requestId is required by AgentPromptMessage; drivers use it only
          // for send-correlation, so a fresh UUID is sufficient.
          void structured?.handleAgentMessage(createMessage("agent:prompt", {
            sessionId: id, requestId: crypto.randomUUID(), text,
          }));
        },
        getTranscriptPath: (id) => sessions?.getAgentTranscriptPath(id),
        getSnapshot: (id) => structured?.getTranscriptSnapshot(id) ?? Promise.resolve([]),
      }),
    }),
    sendAb: (msg) => sendAb(msg),
    sendPush: (message, terminalId) => sendNotifying(createMessage("notification:push", {
      notificationType: "task_complete", message, sessionId: terminalId, projectId: project.id,
    })),
  });

  /** Provisions a freshly cut worktree — copies the untracked files a `git
   *  worktree add` cannot bring and runs the project's install steps — before
   *  its agent and its services start. Eager and factory-scoped like
   *  [handlerEngine]: the terminal reads defer, so whatever `manager` exists
   *  when a run actually spawns is the one it uses. */
  const setupRunner = new CheckoutSetupRunner({
    projectPath: project.path,
    terminals: {
      spawn: (spawnConfig) => {
        if (!manager) throw new Error("terminal manager is not ready");
        return manager.spawn(spawnConfig);
      },
      killAndAwaitTree: (terminalId) => manager?.killAndAwaitTree(terminalId) ?? Promise.resolve(),
    },
  });

  /** Put the setup transcript under the checkout's runtime so
   *  [teardownCheckoutRuntime] reaches it with killAndAwaitTree before `git
   *  worktree remove` runs: on Windows a live `bun install` holding the
   *  checkout as its cwd aborts that sweep mid-tree and strands the session
   *  undeletable. Mapped to itself rather than namespaced, because the session
   *  entry hands the app this exact id — translating it on the way out would
   *  point the app's snapshot request at a terminal nobody has. */
  /** Setup transcripts this process has spawned, live or finished.
   *
   *  Separate from `CheckoutSetupRunner.runs`, which is emptied by `finish()`
   *  — and `finish()` runs BEFORE the PTY's exit on every kill path, because
   *  `killAndAwaitTree` resolves on `killProcessTree` + `pty.kill()` returning,
   *  which is strictly earlier than node-pty dispatching `onExit`. So a
   *  cancelled, timed-out or rerun-over run reaches `onTerminalExited` with
   *  `handleExit` already answering false, and only this set still knows what
   *  the terminal was. Emptied with the rest of the checkout in
   *  `sweepCheckoutRuntime`. */
  const setupTerminalIds = new Set<string>();

  function registerSetupTerminal(checkoutId: string, terminalId: string): void {
    checkoutRuntimes.runtime(checkoutId)?.configuredTerminalIds.set(terminalId, terminalId);
    terminalOwners.set(terminalId, { checkoutId, externalId: terminalId });
    setupTerminalIds.add(terminalId);
  }

  /** Below this a run finished while the user was still on the create flow, and
   *  a push would be noise on every project whose setup is a cache hit. */
  const SETUP_PUSH_MIN_MS = 20_000;

  /** One push per run, and only for a run nobody watched to the end. A cancel
   *  says nothing: the user is the one who ended it. */
  function notifySetupSettled(sessionId: string, progress: CheckoutSetupProgress, elapsedMs: number): void {
    if (progress.state !== "done" && progress.state !== "failed") return;
    if (elapsedMs < SETUP_PUSH_MIN_MS) return;
    if (isSessionOnScreen(sessionId)) return;
    const name = sessions?.get(sessionId)?.name;
    sendNotifying(createMessage("notification:push", {
      notificationType: progress.state === "done" ? "task_complete" : "error",
      message: progress.state === "done"
        ? "Workspace is ready."
        : progress.message ?? "Workspace setup failed.",
      sessionId,
      ...(name ? { sessionTitle: name } : {}),
      projectId: project.id,
    }));
  }

  function isSessionOnScreen(sessionId: string): boolean {
    for (const focused of focusedSessionByClient.values()) {
      if (focused === sessionId) return true;
    }
    return false;
  }

  async function refreshGitBranch(runtime: CheckoutRuntime = mainRuntime): Promise<void> {
    try {
      const proc = Bun.spawn(["git", "rev-parse", "--abbrev-ref", "HEAD"], {
        cwd: runtime.checkout.path,
        stdout: "pipe",
        stderr: "ignore",
      });
      const output = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;
      runtime.cachedGitBranch = exitCode === 0 ? output.trim() || null : null;
    } catch {
      runtime.cachedGitBranch = null;
    }
  }

  // Results are applied in START order, never arrival order. Four triggers can
  // now overlap on one checkout (the 10s backstop poll, the watcher debounce,
  // a tree-snapshot request and a post-mutation refresh), and a slower earlier
  // `git status` finishing last would otherwise overwrite the newer snapshot —
  // and get pushed and cached for replay as if it were current.
  async function refreshGitStatus(runtime: CheckoutRuntime = mainRuntime): Promise<void> {
    const ticket = ++runtime.gitStatusSeq;
    let files: GitFileEntry[];
    try {
      files = await getGitStatus(runtime.checkout.path);
    } catch {
      // `Bun.spawn` throws SYNCHRONOUSLY when cwd is gone, which is the normal
      // state once the checkout has been removed under an in-flight refresh.
      // Matching [refreshGitBranch], which has always caught: letting this
      // propagate rejects whatever awaited it — including a session start,
      // which then badges the session `failed` with an unrelated cause.
      return;
    }
    if (ticket < runtime.gitStatusApplied) return;
    runtime.gitStatusApplied = ticket;
    runtime.cachedGitFiles = files;
  }

  // Coalescing window for a watcher-driven git refresh. Long enough that a
  // save storm (an agent rewriting a dozen files, a formatter sweeping the
  // tree) costs one `git status` rather than a dozen, short enough that the
  // Git view moves while the user is still looking at what caused it.
  const GIT_REFRESH_DEBOUNCE_MS = 250;

  // Every git refresh below is fire-and-forget, so teardown has to be able to
  // find the ones still running: `git status` is a child process holding the
  // checkout as its cwd, and on Windows that handle keeps the directory locked
  // after the core has otherwise stopped — an isolated session's worktree
  // cannot be removed while one is in flight.
  //
  // Tracked PER RUNTIME, not once for the core: deleting a session tears down
  // only that checkout while the rest of the process keeps running, so a
  // core-wide set would leave [teardownCheckoutRuntime] with nothing it could
  // wait on that wasn't also every other checkout's traffic.
  //
  // Settled either way, so a rejected refresh is neither leaked from the set
  // nor reported as an unhandled rejection by the tracking itself.
  function trackGitRefresh(runtime: CheckoutRuntime, work: Promise<unknown>): void {
    runtime.pendingGitRefreshes.add(work);
    const forget = () => void runtime.pendingGitRefreshes.delete(work);
    void work.then(forget, forget);
  }

  function awaitGitRefreshes(runtime: CheckoutRuntime): Promise<unknown> {
    return Promise.allSettled([...runtime.pendingGitRefreshes]);
  }

  // Re-reads git status after the file watcher saw the tree move, and pushes
  // it only if it actually changed.
  ///
  // The 10s poll below is a BACKSTOP, not the mechanism: it exists for the
  // changes no watcher sees (a `git add` or `git stash` run in another
  // terminal touches only `.git/`, which the ignore rules exclude). Leaving
  // the poll as the only trigger is what made a diff take up to ten seconds
  // to appear after the agent finished writing — worst on a phone or tablet,
  // where the Git view is opened deliberately, right after the agent stops.
  function scheduleGitRefresh(runtime: CheckoutRuntime) {
    if (runtime.gitRefreshTimer) return;
    runtime.gitRefreshTimer = setTimeout(() => {
      runtime.gitRefreshTimer = null;
      trackGitRefresh(
        runtime,
        (async () => {
          const before = JSON.stringify(runtime.cachedGitFiles);
          try {
            await refreshGitStatus(runtime);
          } catch {
            return;
          }
          if (JSON.stringify(runtime.cachedGitFiles) !== before) sendGitStatus(runtime);
        })(),
      );
    }, GIT_REFRESH_DEBOUNCE_MS);
  }

  function sendGitStatus(runtime: CheckoutRuntime = mainRuntime, force = false) {
    sendFromRuntime(runtime,
      createMessage("git:status", {
        projectId: project.id,
        files: runtime.cachedGitFiles,
      }),
      force,
    );
  }

  async function handleGitListBranches(runtime: CheckoutRuntime, projectId: string) {
    try {
      const catalog = await listLocalBranches(runtime.checkout.path);
      if (!catalog.isRepository) return;

      sendFromRuntime(runtime, createMessage("git:branches", {
        projectId,
        current: catalog.current ?? runtime.cachedGitBranch ?? "",
        branches: catalog.branches,
      }));
    } catch {
      // ignore
    }
  }

  async function handleGitCheckout(runtime: CheckoutRuntime, projectId: string, branch: string) {
    try {
      const res = await checkoutLocalBranch(runtime.checkout.path, branch);
      sendFromRuntime(runtime, createMessage("git:checkout-result", {
        projectId,
        branch,
        success: true,
      }));

      // Refresh cached state and notify app
      runtime.cachedGitBranch = res.current;
      sendStatus(runtime);
      await refreshGitStatus(runtime);
      sendGitStatus(runtime);
    } catch (err: any) {
      sendFromRuntime(runtime, createMessage("git:checkout-result", {
        projectId,
        branch,
        success: false,
        error: err?.message || String(err),
      }));
    }
  }

  async function handleGitCommit(runtime: CheckoutRuntime, projectId: string, message: string) {
    const result = await gitCommit(runtime.checkout.path, message);
    sendFromRuntime(runtime, createMessage("git:commit-result", {
      projectId,
      success: result.success,
      ...(result.sha ? { sha: result.sha } : {}),
      ...(result.error ? { error: result.error } : {}),
    }));
    if (result.success) {
      await refreshGitStatus(runtime);
      sendGitStatus(runtime);
      sendStatus(runtime);
    }
  }

  async function handleGitDiscard(
    runtime: CheckoutRuntime,
    projectId: string,
    files: string[],
    includeStaged: boolean,
  ) {
    // gitDiscard classifies tracked vs untracked from live git state itself —
    // don't thread a (possibly stale) cachedGitFiles snapshot through.
    const result = await gitDiscard(runtime.checkout.path, files, { includeStaged });
    sendFromRuntime(runtime, createMessage("git:discard-result", {
      projectId,
      success: result.success,
      files,
      ...(result.error ? { error: result.error } : {}),
    }));
    // Refreshed on BOTH outcomes, unlike the single-command stage/unstage
    // handlers below: a discard is several git invocations and the later ones
    // can fail after the index has already been reset, so a failed one still
    // moves the tree. Nothing else would correct the view — an index-only
    // mutation touches `.git/`, which the watcher ignores, leaving the 10s
    // backstop poll to show the user files that are no longer staged.
    await refreshGitStatus(runtime);
    sendGitStatus(runtime);
    sendStatus(runtime);
  }

  async function handleGitStage(runtime: CheckoutRuntime, projectId: string, files: string[]) {
    const result = await gitStage(runtime.checkout.path, files);
    sendFromRuntime(runtime, createMessage("git:stage-result", {
      projectId,
      success: result.success,
      files,
      ...(result.error ? { error: result.error } : {}),
    }));
    if (result.success) {
      await refreshGitStatus(runtime);
      sendGitStatus(runtime);
      sendStatus(runtime);
    }
  }

  async function handleGitUnstage(runtime: CheckoutRuntime, projectId: string, files: string[]) {
    const result = await gitUnstage(runtime.checkout.path, files);
    sendFromRuntime(runtime, createMessage("git:unstage-result", {
      projectId,
      success: result.success,
      files,
      ...(result.error ? { error: result.error } : {}),
    }));
    if (result.success) {
      await refreshGitStatus(runtime);
      sendGitStatus(runtime);
      sendStatus(runtime);
    }
  }

  async function handleGitDiffRequest(runtime: CheckoutRuntime, projectId: string, path: string) {
    try {
      // `git diff HEAD` emits nothing for untracked files (they're in neither
      // HEAD nor the index), so a tapped "U" file would render a blank diff.
      // Diff it against /dev/null via `--no-index` to show its full content as
      // additions. (`--no-index` exits 1 when files differ — normal for a new
      // file — so treat 0 and 1 as success.)
      const isUntracked = runtime.cachedGitFiles.some(
        (f) => f.path === path && f.status === "U",
      );
      const args = isUntracked
        ? ["diff", "--no-index", "--", "/dev/null", path]
        : ["diff", "HEAD", "--relative", "--", path];
      const proc = Bun.spawn(["git", "-c", "core.quotepath=false", ...args], {
        cwd: runtime.checkout.path,
        stdout: "pipe",
        stderr: "ignore",
      });
      const output = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;
      if (isUntracked ? exitCode > 1 : exitCode !== 0) {
        sendFromRuntime(runtime, createMessage("git:diff-content", {
          projectId,
          path,
          diff: null,
          additions: 0,
          deletions: 0,
        }));
        return;
      }

      let additions = 0;
      let deletions = 0;
      for (const line of output.split("\n")) {
        if (line.startsWith("+") && !line.startsWith("+++")) additions++;
        if (line.startsWith("-") && !line.startsWith("---")) deletions++;
      }

      sendFromRuntime(runtime, createMessage("git:diff-content", {
        projectId,
        path,
        diff: output || null,
        additions,
        deletions,
      }));
    } catch {
      sendFromRuntime(runtime, createMessage("git:diff-content", {
        projectId,
        path,
        diff: null,
        additions: 0,
        deletions: 0,
      }));
    }
  }

  /** [force] re-sends an unchanged snapshot past the bus dedup. Set it only on
   *  the paths that exist BECAUSE a client is missing this state. */
  function sendStatus(runtime: CheckoutRuntime = mainRuntime, force = false) {
    if (!manager) return;
    // All terminals (agent + services + ad-hoc) flow through `terminals`;
    // the app filters by `type` to route them to the right UI surface.
    // Sessions advertise themselves through `session:updated`; the terminals
    // list now only reflects actually-spawned PTYs (agent or service).
    const terminalsForApp = manager.getStatus().flatMap((terminal) => {
      const owner = terminalOwner(terminal.terminalId);
      return owner.runtime === runtime
        ? [{ ...terminal, terminalId: owner.externalId }]
        : [];
    });

    // Service status: merge declared services with runtime session info
    const serviceStatus = (runtime.config.services ?? []).map((s) => {
      const live = terminalsForApp.find((t) => t.terminalId === s.name);
      return {
        id: s.name,
        name: s.name,
        running: live?.running ?? false,
        command: s.command,
      };
    });

    // Ports: derive from config.ports, attaching detected URL when available
    const detected = runtime.portDetector?.getLastDetections() ?? new Map<number, { url: string; scheme: "http" | "https"; source: "process" | "output" }>();
    const portStatus = (runtime.config.ports ?? []).map((p) => {
      const hit = detected.get(p.port);
      return hit
        ? {
            port: p.port,
            name: p.name,
            onDetect: p.onDetect,
            url: hit.url,
            scheme: hit.scheme,
            source: hit.source,
          }
        : {
            port: p.port,
            name: p.name,
            onDetect: p.onDetect,
            source: "declared" as const,
          };
    });

    sendFromRuntime(runtime,
      createMessage("agent:status", {
        projectId: project.id,
        projectName: agentName,
        hostMachineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
        terminals: terminalsForApp,
        services: serviceStatus,
        commands: runtime.config.commands?.map((c) => ({
          name: c.name,
          confirm: c.confirm,
          description: c.description,
          icon: c.icon,
        })),
        ports: portStatus,
        git: runtime.cachedGitBranch ? { branch: runtime.cachedGitBranch } : undefined,
        agent: {
          tool: runtime.config.agent?.tool,
          name: agentName,
          version: VERSION,
          flags: runtime.config.agent?.flags,
        },
        needsFirstRun,
      }),
      force,
    );
  }

  async function resyncState() {
    log.info("App reconnected, re-syncing existing state");
    // Use cached git state for the immediate resync; refresh in background.
    for (const runtime of checkoutRuntimes.values()) {
      // A resync runs on every app handshake, independent of any delete, and
      // the registry still lists a checkout whose teardown is in flight — the
      // row goes last. Everything below would hand that dying checkout two
      // fresh `git` children cwd'd inside it, so the sweep that follows finds
      // holders it never saw. See the same guard on the two loops below.
      if (runtime.disposed) continue;
      // Forced: a resync exists because a client believes it has nothing, and
      // for an idle checkout the snapshot is byte-identical to the cached one —
      // exactly what the bus's dedup drops before any subscriber sees it.
      sendStatus(runtime, true);
      sendGitStatus(runtime, true);
      trackGitRefresh(
        runtime,
        Promise.all([refreshGitBranch(runtime), refreshGitStatus(runtime)])
          .then(() => {
            sendStatus(runtime);
            sendGitStatus(runtime);
          })
        // refreshGit* swallow internally today, but guard against a future
        // edit that lets an exception escape silently breaking the re-emit.
          .catch(() => {}),
      );
    }

    // Re-send the file tree. Forced for the same reason as the status/git pair
    // above: an idle project's tree is byte-identical to the cached one, so the
    // ordinary dedup would drop the very re-push this resync exists to perform.
    for (const runtime of checkoutRuntimes.values()) {
      await yieldToEventLoop();
      // Re-tested after the yield, not just on entry: `sendFullTree` walks the
      // whole tree synchronously and `stop()` does not disable it, so a
      // teardown that started during the yield would be walking a directory
      // Git is removing.
      if (runtime.disposed) continue;
      runtime.fileWatcher?.sendFullTree({ force: true });
    }

    // Re-emit the detected-port list. ports:update is only pushed on change,
    // so a phone that binds after detection would otherwise never see ports
    // found before it connected (preview:snapshot only covers config-declared
    // preview ports, not ad-hoc detections).
    for (const runtime of checkoutRuntimes.values()) {
      if (runtime.disposed) continue;
      runtime.portDetector?.emitCurrent();
    }

    // Re-send terminal scrollback so the app has current output
    if (manager) {
      for (const t of manager.getStatus()) {
        const snap = manager.getReplaySnapshot(t.terminalId);
        if (snap && snap.text) {
          sendTerminalFrame(createMessage("terminal:output", {
            // The INTERNAL id: sendTerminalFrame owns the external rewrite, and
            // handing it an already-externalised one makes its own owner lookup
            // miss and stamp an isolated checkout's replay as main's.
            terminalId: t.terminalId,
            data: snap.text,
          }));
        }
      }
    }
  }

  async function startCheckoutRuntime(
    runtime: CheckoutRuntime,
    opts?: { deferServices?: boolean },
  ): Promise<void> {
    if (runtime.started || !manager) return;
    runtime.started = true;
    runtime.servicesDeferred = opts?.deferServices ?? false;
    const runtimeId = runtime.checkout.id;
    const send = (msg: AbMessage) => sendFromRuntime(runtime, msg);
    const pd = new PortDetector({
      ports: (runtime.config.ports ?? []).map((p) => ({ port: p.port, name: p.name })),
    });
    runtime.portDetector = pd;
    const previewPorts = new Set(
      (runtime.config.ports ?? []).filter((p) => p.onDetect !== "ignore").map((p) => p.port),
    );
    const relayHost = relayBase ? new URL(relayBase).host : "";
    const tm = new TunnelManager({
      projectId: project.id,
      portLabels: pd.getPortLabels(),
      previewPorts,
      sendTunnel: (data) => sendPlain({ ...data, checkoutId: runtimeId }),
      sendEncrypted: send,
      relayHost,
      connState,
    });
    runtime.tunnelManager = tm;
    pd.onPortsChange = (ports) => {
      send(createMessage("ports:update", { projectId: project.id, ports }));
      tm.onPortsUpdate(ports);
    };
    pd.onDetection((event) => {
      const declared = (runtime.config.ports ?? []).find((p) => p.port === event.port);
      if (declared?.onDetect === "ignore") return;
      send(createMessage("port:detected", {
        port: event.port,
        url: event.url,
        scheme: event.scheme,
        source: event.source,
        sourceSessionId: event.sourceSessionId,
        attributes: { name: declared?.name, onDetect: declared?.onDetect ?? "notify" },
      }));
    });

    const fw = new FileWatcher(
      { id: project.id, path: runtime.checkout.path, name: project.name },
      (msg, opts) => sendFromRuntime(runtime, msg, opts?.force),
      connState,
      () => scheduleGitRefresh(runtime),
    );
    runtime.fileWatcher = fw;
    runtime.fileSearcher = new FileSearcher(runtime.checkout.path, project.id, send, [abDir]);
    runtime.uploadManager = new FileUploadManager({
      projectId: project.id,
      projectPath: runtime.checkout.path,
      send,
    });
    runtime.uploadManager.startSweeper();
    await yieldToEventLoop();
    // A shutdown can still land here — it does not take the runtime lock, and
    // by this point it has already nulled `manager`. The delete path cannot:
    // [withCheckoutRuntimeLock] holds teardown behind this whole function.
    if (runtime.disposed || !manager) return;
    fw.sendFullTree();
    fw.startWatching();

    runtime.configController.watch((result, diff) => {
      // stopWatch() has already run for a torn-down runtime, but a callback
      // debounced before it can still land — and this one spawns PTYs into the
      // checkout and re-registers the runtime, undoing the teardown.
      if (runtime.disposed) return;
      if (!result.ok) {
        if (!result.missing) send(createMessage("config:changed", {
          agentRestartRequired: false, invalid: true, error: result.error,
        }));
        return;
      }
      for (const name of diff.servicesRemoved) {
        manager?.kill(internalTerminalId(runtime, name));
      }
      for (const changed of [...diff.servicesAdded, ...diff.servicesModified]) {
        const service = result.config.services?.find((candidate) => candidate.name === changed.name);
        if (!service || !manager) continue;
        // A setup step that edits antgrid.yaml must not spawn what the deferral
        // is holding back; [startDeferredServices] starts the whole block from
        // the config this callback is about to assign.
        if (runtime.servicesDeferred) continue;
        const terminalId = internalTerminalId(runtime, service.name);
        if (diff.servicesModified.some((candidate) => candidate.name === changed.name)) {
          manager.kill(terminalId);
        }
        manager.spawn({
          terminalId,
          name: service.name,
          command: service.command,
          args: service.args,
          cwd: service.workingDir ?? runtime.checkout.path,
          env: service.env,
          type: "service",
        });
      }
      Object.assign(runtime.config, result.config);
      runtime.agentSpec = agentSpecForConfig(result.config);
      void checkoutRuntimes.prepare(runtime.checkout, runtime.config, runtime.agentSpec, runtime);
      send(createMessage("config:changed", {
        config: result.config,
        agentRestartRequired: diff.agentRestartRequired,
      }));
      sendStatus(runtime);
    });

    if (!runtime.servicesDeferred) startCheckoutServices(runtime);
    const refreshed = Promise.all([refreshGitBranch(runtime), refreshGitStatus(runtime)]);
    // Tracked, not merely awaited: both spawn `git` children holding the
    // checkout as their cwd, and `awaitGitRefreshes` is what teardown waits on
    // before `git worktree remove` runs. Every other refresh site is tracked;
    // this one was the exception only because it is awaited inline.
    trackGitRefresh(runtime, refreshed);
    await refreshed;
    if (runtime.disposed) return;
    sendStatus(runtime);
    sendGitStatus(runtime);
    runtime.gitBranchInterval = setInterval(() => {
      const branch = runtime.cachedGitBranch;
      const files = JSON.stringify(runtime.cachedGitFiles);
      trackGitRefresh(
        runtime,
        Promise.all([refreshGitBranch(runtime), refreshGitStatus(runtime)])
          .then(() => {
            if (runtime.cachedGitBranch !== branch) sendStatus(runtime);
            if (JSON.stringify(runtime.cachedGitFiles) !== files) sendGitStatus(runtime);
          })
          .catch(() => {}),
      );
    }, 10_000);
  }

  /** Spawn the checkout's `services` block. Manual-start slots stay listed in
   *  status rather than running, same as the main project's own pass. */
  function startCheckoutServices(runtime: CheckoutRuntime): void {
    for (const service of runtime.config.services ?? []) {
      if (service.autoStart === false) continue;
      manager?.spawn({
        terminalId: internalTerminalId(runtime, service.name),
        name: service.name,
        command: service.command,
        args: service.args,
        cwd: service.workingDir ?? runtime.checkout.path,
        env: service.env,
        type: "service",
      });
    }
  }

  /** Release the `services` a `deferServices` preparation held back. Called
   *  once a `worktree.setup` run reaches a terminal state, whatever that state
   *  is: a failed setup still gets its dev server, because `onFailure: warn`
   *  means the session runs regardless. */
  async function startDeferredServices(checkoutId: string): Promise<void> {
    const runtime = checkoutRuntimes.runtime(checkoutId);
    if (!runtime?.servicesDeferred) return;
    runtime.servicesDeferred = false;
    startCheckoutServices(runtime);
    // `agent:status` is what carries services[].running to the app, and the
    // checkout's last push happened while they were still held back.
    sendStatus(runtime);
  }

  /** Serializes a checkout's runtime lifecycle. Building a runtime and tearing
   * one down both suspend repeatedly, and everything they touch — a recursive
   * watcher, `services:` PTYs, `git` children — holds the checkout directory
   * open. `deleteManaged` runs `git worktree remove` the instant teardown
   * resolves, so the two interleaving is what strands a session undeletable: on
   * Windows one handle opened by a resuming start aborts Git's sweep mid-tree,
   * and the runtime is out of the registry by then, so no later teardown can
   * find that handle to close it. Measured in the field as 131 watcher starts
   * against 31 stops. */
  const withCheckoutRuntimeLock = createKeyedLock();

  function prepareCheckoutRuntime(
    checkout: CheckoutRecord,
    opts?: { deferServices?: boolean },
  ): Promise<CheckoutRuntime> {
    return withCheckoutRuntimeLock(checkout.id, async () => {
      const existing = checkoutRuntimes.runtime(checkout.id);
      if (existing) {
        await startCheckoutRuntime(existing, opts);
        return existing;
      }
      const runtimeConfig = loadConfig(undefined, checkout.path);
      const spec = agentSpecForConfig(runtimeConfig);
      const runtime = createCheckoutRuntime(checkout, runtimeConfig, spec);
      await checkoutRuntimes.prepare(checkout, runtimeConfig, spec, runtime);
      await startCheckoutRuntime(runtime, opts);
      return runtime;
    });
  }

  /** Release every holder a checkout runtime owns. Returns the watcher's close
   * promise: chokidar's `close()` is asynchronous and resolves only once its
   * per-directory `fs.watch()` subscriptions are gone, so a caller about to
   * delete the directory has to wait on it. Everything else stops
   * synchronously. */
  function stopCheckoutServices(runtime: CheckoutRuntime): Promise<void> {
    runtime.configController.stopWatch();
    const watcherClosed = runtime.fileWatcher?.stop() ?? Promise.resolve();
    runtime.uploadManager?.stop();
    runtime.portDetector?.stop();
    runtime.tunnelManager?.stop();
    if (runtime.gitBranchInterval) clearInterval(runtime.gitBranchInterval);
    runtime.gitBranchInterval = null;
    if (runtime.gitRefreshTimer) clearTimeout(runtime.gitRefreshTimer);
    runtime.gitRefreshTimer = null;
    return watcherClosed;
  }

  function teardownCheckoutRuntime(checkoutId: string): Promise<void> {
    // Under the lock, so a build already in flight for this checkout finishes
    // before the sweep starts and every holder it opened is visible to it.
    return withCheckoutRuntimeLock(checkoutId, async () => {
      const runtime = checkoutRuntimes.runtime(checkoutId);
      if (!runtime || checkoutId === "main") return;
      // For the readers that do NOT take the lock — `resyncState`, which runs on
      // every app handshake, and the process-wide shutdown sweep. Both walk the
      // registry, and the row survives until this function's last line.
      runtime.disposed = true;
      await sweepCheckoutRuntime(runtime, checkoutId);
    });
  }

  async function sweepCheckoutRuntime(runtime: CheckoutRuntime, checkoutId: string): Promise<void> {
    const pending: Promise<void>[] = [];
    for (const proc of runtime.runningCommands.values()) {
      pending.push(killChildTree(proc));
    }
    runtime.runningCommands.clear();
    const ownedTerminalIds = [...runtime.configuredTerminalIds.values()];
    for (const internalId of ownedTerminalIds) {
      if (manager) pending.push(manager.killAndAwaitTree(internalId));
    }
    // Stops run while the kills are in flight — they are the only holders left
    // once the trees are gone.
    pending.push(stopCheckoutServices(runtime));
    // Both waits guard the same sweep, and both are placed after the timers are
    // cleared so nothing new can be scheduled behind them: `deleteManaged` runs
    // `git worktree remove` the moment this resolves, and on Windows either an
    // abandoned `git status` still holding the checkout as its cwd (see
    // [trackGitRefresh]) or a single surviving child of a killed terminal is
    // enough to abort that sweep mid-tree and strand the session undeletable.
    // This is the one place a tree kill must be WAITED on rather than issued.
    await Promise.all([...pending, awaitGitRefreshes(runtime)]);
    // Nothing can name these ids again once the runtime is gone, and the setup
    // transcript among them is retained past its own exit on purpose — so this
    // is the only site that can release it.
    for (const internalId of ownedTerminalIds) {
      manager?.forget(internalId);
      // The owner row too: a retained setup transcript keeps its own past exit
      // so `sendStatus` can still route it, and this is where that ends.
      terminalOwners.delete(internalId);
      setupTerminalIds.delete(internalId);
    }
    dropCheckoutReplay(checkoutId);
    await checkoutRuntimes.remove(checkoutId);
  }

  async function setupServices() {
    // If services are already running (app reconnected), just re-sync state
    if (manager) {
      await resyncState();
      return;
    }

    const pd = new PortDetector({
      ports: (config.ports ?? []).map((p) => ({ port: p.port, name: p.name })),
    });
    portDetector = pd;
    mainRuntime.portDetector = pd;

    const previewPorts = new Set<number>();
    for (const p of config.ports ?? []) {
      if (p.onDetect !== "ignore") previewPorts.add(p.port);
    }

    // In local mode there is no relay; preview tunneling is not available,
    // so an empty host is fine — TunnelManager only uses it to format URLs.
    const relayHost = relayBase ? new URL(relayBase).host : "";
    const tm = new TunnelManager({
      projectId: project.id,
      portLabels: pd.getPortLabels(),
      previewPorts,
      sendTunnel: (data) => sendPlain(data),
      sendEncrypted: (msg) => sendAb(msg),
      relayHost,
      connState,
    });
    tunnelManager = tm;
    mainRuntime.tunnelManager = tm;

    pd.onPortsChange = (ports) => {
      sendAb(createMessage("ports:update", { projectId: project.id, ports }));
      tm.onPortsUpdate(ports);
    };

    manager = new TerminalManager((msg: AbMessage) => sendTerminalFrame(msg), {
      onTerminalOutput: (id, data) => terminalOwner(id).runtime.portDetector?.feed(id, data),
      onTerminalExited: (id) => {
        terminalOwner(id).runtime.portDetector?.removeTerminal(id);
        // A setup transcript belongs to no session, so its exit settles the run
        // and takes none of the session-scoped cleanup below. Its owner row
        // stays, too: the scrollback is retained on purpose, and `sendStatus`
        // routes a terminal by that row — dropping it would advertise the
        // finished transcript on MAIN and prune it from the checkout bundle the
        // banner's "View setup log" reads, exactly when the run has failed.
        // Released with the rest of the checkout in `teardownCheckoutRuntime`.
        if (setupRunner.handleExit(id) || setupTerminalIds.has(id)) return;
        sessions?.noteExited(id);
        // Drop buffered title state so a stale title from this run can't leak
        // into a restarted same-id session (start() reuses the entry id).
        namer?.forget(id);
        // Reclaim the handler's per-terminal guard + pending state for the dead
        // terminal. A mode flip keeps the arming: the session outlives the PTY.
        handlerEngine.onTerminalExit(id, { keepArmed: sessions?.isFlipping(id) });
        queueMicrotask(() => terminalOwners.delete(id));
      },
      // A notification (osc9/osc777) means the session did something worth
      // surfacing — float it up the drawer. No-ops for non-session terminals.
      onTerminalNotification: (id) => sessions?.touch(id),
      // OSC 0/2 terminal title → auto-name policy. Translate an agent's raw OSC
      // title to a usable session name: most agents publish a good name (claude →
      // "Claude Code", cursor → "Cursor Agent"), but antigravity's agy publishes
      // its executable path — we substitute the display name until the plugin hook
      // supplies the real conversation title.
      onTerminalTitle: (id, title) => {
        // Every title on a live setup transcript is a step marker, so it goes to
        // the runner and NOWHERE else — the namer would otherwise read setup
        // progress as the session's conversation name.
        if (setupRunner.handleTitle(id, title)) return;
        // A non-session PTY (a config `terminals:` slot) is attributable to no
        // agent, so its raw title passes through untouched.
        const session = sessions?.get(id);
        if (!session) {
          namer?.onOscTitle(id, title);
          return;
        }
        // agentKeyFor, not the wire `tool`: the latter is undefined for a
        // default-spec (antgrid.yaml) session, which would read agy's exe-path
        // OSC title as a usable name (undefined tool ⇒ not oscTitleUnusable) and
        // let the terminal clobber the hook-resolved title.
        const tool = agentKeyFor(id);
        // oscTitleForNaming maps agy's exe-path title to the "Antigravity"
        // placeholder. That placeholder may only label a still-default slot: on
        // resume the good persisted name is already set, but the OSC title fires
        // before the hook/watcher re-resolve, so applying it would clobber the
        // name back to "Antigravity" and persist it.
        if (isOscTitleUnusable(tool) && !isDefaultSessionName(session.name)) return;
        namer?.onOscTitle(id, oscTitleForNaming(tool, title));
      },
    }, connState, () => apiServer?.port ?? null);

    // One update-checker per tool for this project, built straight from the spec
    // table so a new tool needs only an `update` field in agents/registry.ts —
    // not a bespoke checker wired here. Each shares a latest-version cache across the project's
    // sessions of that tool (concurrent starts collapse onto one npm fetch).
    // Advisory-only signal; every checker swallows its own errors.
    const updateCheckers = new Map(
      Object.values(TOOL_UPDATE_SPECS).map((spec) => [spec.tool, createToolUpdateChecker(spec)]),
    );
    // Fire-and-forget "a newer <tool> exists" nudge for one session's start.
    // Never blocks or fails session start. No-op for a tool with no spec.
    const emitUpdateCheck = (tool: string, sessionId: string, send: (m: AbMessage) => void) => {
      void updateCheckers.get(tool)?.().then((upd) => {
        if (upd) send(createMessage("agent:updateAvailable", {
          tool, installed: upd.installed, latest: upd.latest, sessionId,
        }));
      });
    };

    // StructuredAgentManager is constructed BEFORE `sessions` so the chat
    // bridges below can reference it directly. Its factory depends only on
    // project/config/spawnCodex/spawnOpencode, not on `sessions`; the one back-
    // reference (onAgentSession → sessions) is a closure that resolves at call
    // time, after `sessions` is assigned. Both stay hoisted `let` bindings.
    //
    // Chat-mode Handler event source: structured drivers emit turn/permission/
    // question frames in-process, so tap the outbound funnel instead of relying
    // on injected hooks. The PTY path keeps its hook POSTs; onHandlerEvent
    // drops hook events for chat slots so claude/codex chat spawns (which reuse
    // the terminal-mode plugin) don't fire every turn_end twice.
    const observeChatFrameForHandler = (msg: AbMessage) => {
      let evt: HandlerEvent | null = null;
      // "error" counts as a turn boundary, not just "end_turn": a turn that died
      // leaves the agent idle and blocked, which is precisely when a supervising
      // handler must act. Skipping it let an armed session go silent forever on
      // the one outcome the user most wants to be woken for. "cancelled" stays
      // ignored — the user cancelled it, so they are already present.
      if (msg.type === "agent:turn-end" && (msg.stopReason === "end_turn" || msg.stopReason === "error")) {
        // A limit or outage REPLACES the turn boundary: parking is the answer,
        // and judging the failed turn on top would spend a judge call the
        // provider is refusing anyway.
        const lifecycle = msg.stopReason === "error" && msg.error
          ? classifyTurnEndError(msg.error, Date.now())
          : null;
        evt = lifecycle
          ? { terminalId: msg.sessionId, ...lifecycle }
          : { terminalId: msg.sessionId, event: "turn_end" };
      } else if (msg.type === "agent:permission-request") {
        evt = { terminalId: msg.sessionId, event: "permission_request", detail: msg.title, promptId: msg.permissionId };
      } else if (msg.type === "agent:question") {
        evt = { terminalId: msg.sessionId, event: "question", detail: msg.prompt, promptId: msg.questionId };
      } else if (msg.type === "agent:request-retracted") {
        // The blocking prompt is gone — clear its forced escalation instead of
        // leaving a "needs you" row pointing at a prompt that no longer exists.
        handlerEngine.onPromptRetracted(msg.sessionId, msg.permissionId ?? msg.questionId);
      }
      if (evt) {
        handlerEngine.handleEvent(evt).catch((err) => logger.error("Handler chat event failed: %s", err));
      }
    };
    structured = new StructuredAgentManager({
      sendMessage: (msg) => {
        observeChatFrameForHandler(msg);
        sendAb(msg);
      },
      dropSessionReplay: (sessionId) => dropSessionReplay(sessionId),
      onAgentSession: (sessionId, agentSessionId) => sessions?.setAgentSession(sessionId, agentSessionId),
      onSetConfig: (sessionId, key, value) => sessions?.setSessionConfig(sessionId, key, value),
      driverFactory: (sessionId, tool, send) => {
        // Chat mode is gated on isChatCapableTool, which IS "the spec has a
        // driver" — so an unreachable tool here means the two disagreed.
        const driver = agentSpec(tool)?.driver;
        if (!driver) throw new Error(`tool "${tool}" has no chat driver`);
        const sessionCheckoutId = sessions?.get(sessionId)?.checkoutId ?? "main";
        const sessionRuntime = checkoutRuntimes.runtime(sessionCheckoutId) ?? mainRuntime;
        return driver({
          sessionId,
          send,
          projectPath: sessionRuntime.checkout.path,
          projectId: project.id,
          chatAugment: () => buildChatSpawnAugment(tool, sessionId, apiServer?.port ?? null, abDir),
          onAgentSession: (agentSessionId) => sessions?.setAgentSession(sessionId, agentSessionId),
          onTitle: (title) => namer?.onStructuredTitle(sessionId, title),
          onLifecycle: (evt) => {
            handlerEngine.handleEvent({ terminalId: sessionId, ...evt })
              .catch((err) => logger.error("Handler lifecycle event failed: %s", err));
          },
          emitUpdateCheck: () => emitUpdateCheck(tool, sessionId, send),
        });
      },
    });

    // SessionManager owns the persistent list of coding-agent sessions for this
    // project. PTY lifecycle is delegated to `manager` (TerminalManager); the
    // agent.tool config drives the spawn command for every session. A mode:'chat'
    // session bypasses the PTY and rides the chat bridges into `structured`.
    mainRuntime.started = true;
    await checkoutRuntimes.prepare(mainCheckout, config, agentSpecFromConfig(), mainRuntime);
    sessions = new SessionManager({
      projectId: project.id,
      storeDir: abDir,
      projectPath: project.path,
      terminalManager: manager,
      agentSpec: agentSpecFromConfig(),
      worktreeSessionsSupported:
        opts.worktreeSessionsSupported ?? WORKTREE_SESSIONS_SUPPORTED,
      worktreeManager,
      isGitRepository,
      prepareCheckoutRuntime: async (checkout, prepareOpts) => {
        await prepareCheckoutRuntime(checkout, prepareOpts);
      },
      startDeferredServices,
      runCheckoutSetup: (checkout, sessionId, onProgress) => {
        const startedAt = Date.now();
        setupRunner.start(checkout, sessionId, (progress) => {
          // Before the report, and off the runner's own id rather than a
          // computed one: a checkout with no setup block never spawns a PTY,
          // and registering an id nothing runs under makes every delete warn.
          if (progress.terminalId) registerSetupTerminal(checkout.id, progress.terminalId);
          // Reported before the push so the entry it reads — the session title
          // included — is the one the session manager has just settled.
          onProgress(progress);
          notifySetupSettled(sessionId, progress, Date.now() - startedAt);
        });
      },
      cancelCheckoutSetup: (checkoutId) => setupRunner.cancel(checkoutId),
      checkoutDeclaresSetup: (checkout) => {
        // A config that will not parse cannot say there is nothing to run, so
        // the doubt is reported as "declares" and the user gets the banner.
        try {
          const setup = setupRunner.resolveSetup(checkout);
          // An EMPTY `steps` list is a declaration of nothing, and the same
          // answer `begin()` gives it. The nudge writes exactly that block for
          // a project it cannot fingerprint (`buildStarterWorktreeSetup`), so
          // reading it as "declares" would defer services for a run that only
          // ever reports `done`, and stamp that durably.
          return !!setup && setup.steps.length > 0;
        } catch { return true; }
      },
      announceCheckoutRuntime: (checkoutId) => {
        const runtime = checkoutRuntimes.runtime(checkoutId);
        if (!runtime) return;
        // Forced, for the same reason as resyncState: an announce for an
        // already-warm runtime carries the state the app is waiting for and is
        // identical to what the replay cache holds.
        sendStatus(runtime, true);
        sendGitStatus(runtime, true);
      },
      teardownCheckoutRuntime,
      resolveCheckout: async (checkoutId) => {
        const checkout = await checkoutRuntimes.resolve(checkoutId);
        if (checkout && checkoutId !== "main") await prepareCheckoutRuntime(checkout);
        return checkout;
      },
      resolveAgentSpec: async (checkoutId) => {
        const known = checkoutRuntimes.agentSpec(checkoutId);
        if (known) return known;
        const checkout = await checkoutRuntimes.resolve(checkoutId);
        if (!checkout) return agentSpecFromConfig();
        const checkoutConfig = loadConfig(undefined, checkout.path);
        const spec = agentSpecForConfig(checkoutConfig);
        await prepareCheckoutRuntime(checkout);
        return spec;
      },
      sendMessage: (msg) => sendAb(msg as AbMessage),
      sessionWorkStatusFor: opts.sessionWorkStatusFor,
      onStartChat: (opts) => {
        // startChat rejects on a non-chat-capable tool or a driver spawn/start
        // failure. Catch it — otherwise it's a silent unhandled rejection and the
        // app sees a chat session that never comes alive with no reason. Surface
        // it as agent:error so the transcript can show the failure.
        structured?.startChat(opts).catch((err) => {
          sendAb(createMessage("agent:error", {
            sessionId: opts.sessionId,
            error: {
              category: "unknown",
              message: err instanceof Error ? err.message : String(err),
              retryable: false,
            },
          }));
        });
      },
      onStopChat: (id) => {
        // Mirrors onTerminalExited for PTYs: reclaim guard + pending state and
        // auto-disarm — a stopped driver can't be supervised. Same flip
        // exemption: swapping runtimes is not the session ending.
        handlerEngine.onTerminalExit(id, { keepArmed: sessions?.isFlipping(id) });
        // Returned, not discarded: it settles only once the driver's backend is
        // gone and has released the agent's process lock (codex's ~/.codex
        // sqlite), which anything restarting this slot has to wait out.
        return structured?.stopChat(id);
      },
    });

    // Policy unit that turns title signals (OSC-2 + injected hook/plugin POSTs)
    // into session names, honoring manual-rename precedence via applyAutoName.
    namer = new SessionNamer({
      applyAutoName: (id, name) => sessions?.applyAutoName(id, name),
    });

    // agy fires no hook on a `/rename` or when it writes its own generated
    // conversation name, so neither would reach the sidebar until the next turn.
    // Watch agy's title sources and route the current best name through the namer
    // (same debounce + manual-wins precedence as every other title signal).
    // No-ops if agy isn't installed.
    antigravityTitleWatcher = new AntigravityTitleWatcher(
      antigravityCliHome(),
      (conversationId, title) => {
        const slot = sessions?.findSlotByAgentSession(conversationId);
        if (slot) namer?.onStructuredTitle(slot, title);
      },
    );
    antigravityTitleWatcher.start();

    sessions.onChange(() => {
      if (!sessions) return;
      sendAb(createMessage("session:updated", {
        sessions: sessions.list(true),
      }));
    });

    // Forward each session's raw PTY output to the port detector's URL observer.
    // The replay loop in onSessionCreated covers any sessions already in the map.
    manager.onSessionCreated((session) => {
      // Session PTYs run under their own id, so record ownership here — the
      // session entry is gone by the time a delete's trailing frames resolve.
      // A configured terminal is already recorded by internalTerminalId under
      // its namespaced id; re-stamping it would lose its external id.
      if (!terminalOwners.has(session.terminalId)) {
        terminalOwners.set(session.terminalId, {
          checkoutId: sessions?.get(session.terminalId)?.checkoutId ?? "main",
          externalId: session.terminalId,
        });
      }
      session.onOutput((chunk) => {
        terminalOwner(session.terminalId).runtime.portDetector?.observeOutput(
          session.terminalId,
          chunk,
        );
      });
    });

    // Probe: an agent whose injection declares /hook-alive (see the spec's
    // hooks.posts) pings it from a SessionStart hook. If no ping arrives within
    // 10s the trust fingerprint likely drifted — the agent's hooks are
    // Untrusted/skipped, so BOTH its plugin notifications and its structured
    // title correlation are dead (same injected hooks.state file, see
    // agent-launch-augmenter.ts). Re-enable the OSC scanner (notifications AND
    // title) as a best-effort fallback so the session isn't permanently muted or
    // nameless, and warn. An agent that declares no probe never arms this and
    // must never trip the warning.
    manager.onSessionCreated((session) => {
      const agent = session.hookAliveProbeAgent;
      if (!agent) return;
      const id = session.terminalId;
      setTimeout(() => {
        if (!hookAlivePinged.has(id)) {
          session.enableOscNotifications();
          session.enableOscTitle();
          log.warn(
            "%s hooks did not ping /hook-alive for %s — trust fingerprint " +
            "may have drifted; re-enabled OSC scanner (notifications + title) as fallback",
            agent,
            id,
          );
        }
      }, 10_000).unref?.();
    });

    // Forward URL detections to the app as port:detected messages.
    pd.onDetection((event) => {
      const declared = (config.ports ?? []).find((p) => p.port === event.port);
      if (declared?.onDetect === "ignore") return;
      sendAb(createMessage("port:detected", {
        port: event.port,
        url: event.url,
        scheme: event.scheme,
        source: event.source,
        sourceSessionId: event.sourceSessionId,
        attributes: {
          name: declared?.name,
          onDetect: declared?.onDetect ?? "notify",
        },
      }));
    });

    // Start services (respecting autoStart; manual-start ones stay listed in status)
    for (const s of getServices()) {
      if (s.autoStart === false) continue;
      manager.spawn({
        terminalId: s.name,
        name: s.name,
        command: s.command,
        args: s.args,
        cwd: s.workingDir ?? project.path,
        env: s.env,
        type: "service",
      });
    }

    if (!configWatchStarted) {
      configWatchStarted = true;
      configController.watch((result, diff) => {
        if (!result.ok) {
          if (result.missing) return;
          sendAb(createMessage("config:changed", {
            agentRestartRequired: false,
            invalid: true,
            error: result.error,
          }));
          return;
        }
        for (const name of diff.servicesRemoved) {
          manager?.kill(name);
        }
        for (const svc of diff.servicesAdded) {
          const def = result.config.services?.find((s) => s.name === svc.name);
          if (!def || !manager) continue;
          manager.spawn({
            terminalId: def.name,
            name: def.name,
            command: def.command,
            args: def.args,
            cwd: def.workingDir ?? project.path,
            env: def.env,
            type: "service",
          });
        }
        for (const svc of diff.servicesModified) {
          const def = result.config.services?.find((s) => s.name === svc.name);
          if (!def || !manager) continue;
          manager.kill(def.name);
          manager.spawn({
            terminalId: def.name,
            name: def.name,
            command: def.command,
            args: def.args,
            cwd: def.workingDir ?? project.path,
            env: def.env,
            type: "service",
          });
        }
        Object.assign(config, {
          ports: result.config.ports,
          commands: result.config.commands,
          agent: result.config.agent,
          services: result.config.services,
        });
        needsFirstRun = false;
        // Push the latest spec into SessionManager so the next `start()` (or
        // pending session that materializes) uses the new command/flags.
        const newSpec = buildAgentTerminalSpec();
        if (newSpec && sessions) {
          sessions.setAgentSpec({
            command: newSpec.command,
            name: newSpec.name,
            args: newSpec.args,
            workingDir: newSpec.workingDir,
          });
          // First-run mode may have left a placeholder "default" terminal alive;
          // kill it once the wizard provides an agent block to avoid a stale
          // placeholder terminal persisting in the workspace.
          if (manager?.has("default")) manager.kill("default");
        }
        // diff.agentRestartRequired: stop any running sessions so the next
        // start() uses the updated spec.
        if (diff.agentRestartRequired && sessions) {
          for (const s of sessions.list(false)) {
            if (s.running) sessions.stop(s.id);
          }
        }
        // Post-wizard auto-create removed: the app's New Session page owns first
        // session creation now (per-session agent selection). The wizard still
        // updates the default spec via setAgentSpec above.
        sendAb(createMessage("config:changed", {
          config: result.config,
          agentRestartRequired: diff.agentRestartRequired,
        }));
        sendStatus();
      });
    }

    // Send the initial status immediately with no git data — `git rev-parse`
    // and `git diff HEAD` can take 200–600ms on Windows with a cold FS cache,
    // and the App tolerates a missing `git` block (the branch chip just
    // lights up a tick later). Kick off the refresh in the background and
    // re-send when it lands.
    sendStatus();
    sendGitStatus();
    trackGitRefresh(
      mainRuntime,
      Promise.all([refreshGitBranch(), refreshGitStatus()])
        .then(() => {
          sendStatus();
          sendGitStatus();
        })
        .catch(() => {}),
    );

    // Refresh git branch every 10s and re-send status if it changed
    mainRuntime.gitBranchInterval = setInterval(() => {
      const prevBranch = mainRuntime.cachedGitBranch;
      const prevFiles = JSON.stringify(mainRuntime.cachedGitFiles);
      trackGitRefresh(
        mainRuntime,
        Promise.all([refreshGitBranch(mainRuntime), refreshGitStatus(mainRuntime)])
          .then(() => {
            if (mainRuntime.cachedGitBranch !== prevBranch) sendStatus(mainRuntime);
            if (JSON.stringify(mainRuntime.cachedGitFiles) !== prevFiles) {
              sendGitStatus(mainRuntime);
            }
          })
          .catch(() => {}),
      );
    }, 10_000);

    const fw = new FileWatcher(
      project,
      (msg: AbMessage, opts) => (opts?.force ? republishAb(msg) : sendAb(msg)),
      connState,
      () => scheduleGitRefresh(mainRuntime),
    );
    fileWatchers.set(project.id, fw);
    mainRuntime.fileWatcher = fw;
    uploadManager = new FileUploadManager({
      projectId: project.id,
      projectPath: project.path,
      send: (msg) => sendAb(msg),
    });
    uploadManager.startSweeper();
    mainRuntime.uploadManager = uploadManager;
    await yieldToEventLoop();
    fw.sendFullTree();
    fw.startWatching();

    const mainSearcher = new FileSearcher(
      project.path,
      project.id,
      (msg) => sendFromRuntime(mainRuntime, msg),
      [abDir],
    );
    fileSearchers.set(project.id, mainSearcher);
    mainRuntime.fileSearcher = mainSearcher;
  }

  // Emit current config validity as a config:read-result. Mirrors the
  // `config:read` request handler, and is also pushed on every connect (see
  // onHandshakeComplete): the file watcher fires only on a CHANGE, not on
  // connect, and the app's drawer config-error dot clears only on a config
  // frame — so without this a stale cached dot would persist after the YAML
  // was fixed while disconnected.
  function emitConfigState(runtime: CheckoutRuntime = mainRuntime) {
    const r = runtime.configController.read();
    if (r.ok) {
      sendFromRuntime(runtime, createMessage("config:read-result", { ok: true, config: r.config }));
    } else if (r.missing) {
      sendFromRuntime(runtime, createMessage("config:read-result", { ok: false }));
    } else {
      sendFromRuntime(runtime, createMessage("config:read-result", { ok: false, raw: r.raw, error: r.error }));
    }
  }

  function onHandshakeComplete() {
    log.info("app:ready / owner-connect — emitting hello and (re)syncing state");
    // Re-emit hello on every handshake; app-side notifiers are
    // latest-wins, so this is a no-op when unchanged and self-healing
    // otherwise.
    sendAb(buildAgentHello(config, VERSION));
    // Re-sync the config-error dot on every connect (see emitConfigState).
    emitConfigState();
    // Seed the app's Handler defaults (judge overrides, notify-only) even when
    // nothing is armed — arming is one tap and carries no payload, so it arms
    // with whatever this snapshot seeded.
    handlerEngine.emitStatus();
    // Sessions are no longer auto-created on connect; the app routes the user
    // to the New Session page when the list is empty so they pick an agent.
    // Existing sessions are still restored + listed by session:list.
    void setupServices().catch((err) => log.error("setupServices failed: %s", err));
  }

  /**
   * Last resort for a session no agent will name: ask the agent's own headless
   * CLI. Gated hard, because it costs a model spawn — only when the native read
   * gave us nothing better than the user's opening prompt (see ResolvedTitle),
   * once per agent session, and never for a session the user already renamed.
   *
   * Fire-and-forget by design: /session-title is posted from a hook the agent is
   * blocking on, so the reply must not wait on a judge spawn.
   */
  async function maybeGenerateTitle(body: SessionTitleBody, fallback?: string): Promise<void> {
    const tool = body.agent ? BY_HOOK_NAME[body.agent] : undefined;
    if (!tool || !body.sessionId) return;
    if (sessions && !sessions.isAutoNameable(body.terminalId)) return;
    const key = `${body.terminalId}:${body.sessionId}`;
    // Claim the slot BEFORE awaiting: two turns can end while the first spawn is
    // still running, and both would otherwise pass the check.
    if (titleGenAttempted.has(key)) return;
    titleGenAttempted.add(key);
    const title = await generateSessionTitle({
      tool,
      cwd: project.path,
      transcriptPath: body.transcriptPath,
      agentSessionId: body.sessionId,
      fallbackContext: fallback,
    });
    // Re-check: the spawn takes tens of seconds, and the user may have renamed
    // the session (or Claude may have written its own title) in that window.
    if (!title || (sessions && !sessions.isAutoNameable(body.terminalId))) return;
    log.info("generated a session title for %s (%s)", body.terminalId, tool);
    namer?.onStructuredTitle(body.terminalId, title);
  }

  // Start local API server for MCP/hook integration (works in both modes)
  apiServer = startApiServer({
    manager: () => manager,
    config: () => config,
    project: () => project,
    sendAb: (msg) => sendNotifying(msg),
    sessionName: (terminalId) => sessions?.get(terminalId)?.name,
    onHandlerEvent: (body) => {
      // Chat slots are fed by the in-process driver tap (observeChatFrameForHandler);
      // the reused title plugin's hooks still POST here for claude/codex chat
      // spawns — drop those or every turn_end fires twice.
      if (sessions?.get(body.terminalId)?.mode === "chat") return;
      handlerEngine.handleEvent({
        terminalId: body.terminalId, event: body.event,
        transcriptPath: body.transcriptPath, sessionId: body.sessionId,
        resetsAt: body.resetsAt, errorClass: body.errorClass,
      }).catch((err) => log.error("Handler event failed: %s", err));
    },
    onSessionTitle: async (body) => {
      // Persist the agent's native resume id for this slot every turn
      // (overwrite-latest), independent of title resolution. terminalId is the
      // slot id (stamped as ANTGRID_TERMINAL_ID at spawn).
      if (!body.titleOnly) {
        sessions?.setAgentSession(body.terminalId, body.sessionId, body.transcriptPath);
      }
      // opencode posts the title inline; Claude/Codex/Antigravity post only
      // correlation ids, so resolve the title from their on-disk session files
      // (async read, off the event loop). resolveStructuredTitle swallows its own
      // errors, so the unawaited promise can't reject.
      if (body.title) {
        namer?.onStructuredTitle(body.terminalId, body.title);
        return;
      }
      const resolved = await resolveStructuredTitle(body.agent, {
        sessionId: body.sessionId,
        transcriptPath: body.transcriptPath,
      });
      // Apply the native read first either way: even a first-message title beats
      // "Session 3" while generation is in flight, and it's what we keep if
      // generation fails.
      if (resolved) namer?.onStructuredTitle(body.terminalId, resolved.title);
      if (!resolved || resolved.kind === "first-message") {
        void maybeGenerateTitle(body, resolved?.title);
      }
    },
    onHookAlive: (terminalId) => { hookAlivePinged.add(terminalId); },
    onTurnStart: (terminalId) => opts.onTurnStart?.(terminalId),
  });

  const TranscriptSnapshotParams = z.object({ sessionId: z.string() });

  // Intercepted before the generic dispatchRpc registry — like sessions.list/
  // sessions.delete's own special-casing — because it needs `structured`
  // (StructuredAgentManager) in closure scope, which rpc/methods.ts's registry
  // doesn't have access to. Runs through the SAME mobile-access gate as every
  // other inbound verb (see the currentPhoneAllowed() check in attachTransport);
  // no separate authz here.
  async function handleTranscriptSnapshotRequest(msg: RpcRequest): Promise<AbMessage> {
    const parsed = TranscriptSnapshotParams.safeParse(msg.params ?? {});
    if (!parsed.success) {
      return createMessage("response", {
        requestId: msg.requestId,
        ok: false,
        error: {
          code: "E_BAD_PARAMS",
          message: parsed.error.issues.map((i) => `${i.path.join(".") || "(root)"}: ${i.message}`).join("; "),
        },
      });
    }
    const frames = (await structured?.getTranscriptSnapshot(parsed.data.sessionId)) ?? [];
    return createMessage("response", { requestId: msg.requestId, ok: true, result: { frames } });
  }

  function attachTransport(bus: MessageBus) {
    sendAb = (m) => bus.publish(m, "control");
    republishAb = (m) => bus.republish(m, "control");
    dropSessionReplay = (sessionId) => bus.dropSessionReplay(sessionId);
    dropCheckoutReplay = (checkoutId) => bus.dropCheckoutReplay(checkoutId);
    // Plaintext (tunnel) sender bypasses the bus — see setPlainHook.
    sendPlain = (data) => busPlainHook?.(data);
    bus.setInboundHandler((msg, channel, source) => {
      // Mobile-access gate: the single chokepoint through which both RPC
      // requests and plain Ab messages enter the core dispatch. Drops EVERY
      // inbound verb while the machine is not mobile-reachable, so an
      // account-trusted phone sees nothing. This sits at the VERB layer by
      // design (not the pairing/handshake layer): the phone connects and
      // completes the handshake, but the data plane is inert until the machine
      // switch is on. See currentPhoneAllowed() for the local-mode / no-peer
      // skip rationale. The tunnel/HTTP-proxy path is gated separately in
      // handleTunnelMessage (it bypasses this bus).
      //
      // Only RELAY-origin frames are gated. Loopback frames are the desktop
      // owner (trusted by the loopback socket + token); after promotion the
      // loopback session and the relay slot share this one handler, so without
      // the source check a promoted core would gate the desktop's own input on
      // the machine switch and silently drop the user's local typing.
      if (source !== "loopback" && !currentPhoneAllowed()) {
        log.warn(
          "Dropping inbound %s: mobile access is disabled (project %s)",
          msg.type,
          project.id,
        );
        return;
      }
      if (source !== "loopback" && sessions?.hasIsolatedSessions() && !currentPeerCanRouteCheckouts()) {
        log.warn("Dropping inbound %s: remote app lacks checkout routing (project %s)", msg.type, project.id);
        return;
      }
      if (msg.type === "request") {
        if (msg.method === "state.snapshot") {
          // The snapshot is the app's PULL, and for a relay app it is the only
          // thing its per-checkout terminal tabs are ever built from:
          // `terminal:started` is not a replay type, and a stream attach runs
          // no `resyncState` — only a loopback owner connect does. Nothing
          // else republishes a checkout's status when a PTY spawns, so the
          // cache `dispatchRpc` is about to read can be arbitrarily old, and
          // replaying a terminal-less status DELETES the tabs the app has.
          // Recomputing here is what makes the answer no older than the pull.
          // Same failure, same fix, as the machine control plane's own
          // `state.snapshot` intercept (`host-server.ts`); an unchanged
          // payload is a cheap no-op, since the bus dedups on it.
          for (const runtime of checkoutRuntimes.values()) {
            if (runtime.disposed) continue;
            sendStatus(runtime);
          }
        }
        if (msg.method === "session.transcriptSnapshot") {
          void handleTranscriptSnapshotRequest(msg).then((res) => bus.publish(res, channel));
          return;
        }
        void dispatchRpc(bus, msg).then((res) => bus.publish(res, channel));
        return;
      }
      // Explicit checkout IDs never fall back to main. The asynchronous store
      // lookup also covers a resumed managed session after an agent restart.
      if (CHECKOUT_VARIABLE_MESSAGE_TYPES.has(msg.type)) {
        const checkoutId = (msg as { checkoutId?: string }).checkoutId ?? "main";
        // A checkout-scoped verb cannot simply skip its prepare while the
        // checkout is being deleted: `runtimeFor` ends in `?? mainRuntime`, so a
        // skipped prepare answers the request out of MAIN's working tree —
        // reading, and for the write verbs editing, the wrong repository. It is
        // refused instead, per frame like the UNKNOWN_CHECKOUT arm below, and
        // logged: a silent refusal leaves a failed delete with no trace of what
        // held the directory. Loopback is NOT exempt — a desktop driving its own
        // machine is exactly what opened the watcher that broke the removal.
        const refuseDeleting = (): boolean => {
          if (sessions?.isCheckoutDeleting(checkoutId) !== true) return false;
          log.warn("Refusing %s for checkout %s: its delete is in flight (project %s)", msg.type, checkoutId, project.id);
          bus.publish(createMessage("control:result", {
            ok: false,
            verb: msg.type,
            error: { code: "CHECKOUT_DELETING", message: "This session's workspace is being deleted." },
            checkoutId,
          }), channel);
          return true;
        };
        if (refuseDeleting()) return;
        void checkoutRuntimes.resolve(checkoutId).then(async (checkout) => {
          if (!checkout) {
            log.warn("Rejecting %s for unknown checkout %s (project %s)", msg.type, checkoutId, project.id);
            bus.publish(createMessage("control:result", {
              ok: false,
              verb: msg.type,
              error: { code: "UNKNOWN_CHECKOUT", message: "The requested checkout is not available." },
              checkoutId,
            }), channel);
            return;
          }
          // Re-checked after the store lookup: a delete that started during that
          // await would otherwise have its checkout re-prepared right here.
          if (refuseDeleting()) return;
          if (checkoutId !== "main") await prepareCheckoutRuntime(checkout);
          handleAbMessage({ ...msg, checkoutId } as AbMessage, source);
        }).catch((error) => log.warn("Checkout lookup failed for %s: %s", checkoutId, error));
        return;
      }
      handleAbMessage(msg, source);
    });
  }

  // Plaintext (tunnel) sender wired by the caller after transport construction.
  let busPlainHook: ((data: object) => void) | null = null;
  function setPlainHook(fn: ((data: object) => void) | null) {
    busPlainHook = fn;
  }

  return {
    attachTransport,
    async shutdown() {
      if (isShuttingDown) return 0;
      isShuttingDown = true;

      apiServer?.stop();
      // Before teardownServices, which force-kills through `killAll()` and then
      // nulls `manager` — sequenced after it this could only ever see an empty
      // map, so no session was ever asked to exit on its own and the line below
      // reported 0 for a machine that had just killed a dozen agents.
      const closed = manager ? await manager.killAllGracefully(5000) : 0;
      teardownServices();
      // After the timers are cleared, so nothing new can be scheduled behind
      // this — see [trackGitRefresh] for why an in-flight one has to be
      // waited out rather than abandoned.
      await Promise.all([...checkoutRuntimes.values()].map(awaitGitRefreshes));

      log.info("Antgrid Agent stopped. %d terminal(s) closed.", closed);
      return closed;
    },
    relayUrl: relayBase,
    identity,
    projectId: project.id,
    abDir,
    nextKeypair,
    pairedPhones,
    refreshSessionWork(): void {
      sessions?.refreshWorkStatus();
    },
    async refreshGitState(): Promise<void> {
      await Promise.all([refreshGitBranch(), refreshGitStatus()]);
      sendStatus();
      sendGitStatus();
    },
    handleTunnelMessage,
    onHandshakeComplete,
    setPlainHook,
    setPeerPubkeyProvider,
    setPeerCheckoutRoutingProvider,
    connState,
    deleteSession(id: string, options?: DeleteSessionOptions): boolean | Promise<boolean> {
      if (!sessions) return false;
      return sessions.delete(id, options);
    },
    listSessions(includeArchived: boolean): SessionEntry[] | null {
      return sessions ? sessions.list(includeArchived) : null;
    },
    hasIsolatedSessions(): boolean {
      return sessions?.hasIsolatedSessions() ?? false;
    },
    isMainCheckoutSession(id: string): boolean {
      return sessions?.isMainCheckoutSession(id) ?? true;
    },
    noteClientGone(client: InboundSource): void {
      focusedSessionByClient.delete(client);
    },
  };
}
