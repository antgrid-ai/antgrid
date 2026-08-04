import { z } from "zod";
import { VERSION } from "./version";
import { join } from "node:path";
import { hostname } from "node:os";
import { spawn, type ChildProcess } from "node:child_process";
import { logger } from "./logger";
const log = logger.child({ component: "agent-core" });
import { TerminalManager } from "./terminal-manager";
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
import { resolveAgent, listKnownTools } from "./known-agents";
import { augmentAgentLaunch } from "./agent-launch-augmenter";
import { CHECKOUT_VARIABLE_MESSAGE_TYPES, createMessage, HandlerConfigureWire, type AbMessage, type RpcRequest, type SessionEntry, type WorkStatus } from "./protocol";
import { parseTunnelMessage } from "./tunnel-protocol";
import { startApiServer, type ApiServerHandle, type SessionTitleBody } from "./api-server";
import { MessageBus } from "./message-bus";
import { resolveAbDir } from "./antgrid-dir";
import { computeProjectId } from "./project-id";
import { loadPairedPhones, type PairedPhonesStore } from "./paired-phones";
import { ConfigController } from "./config-controller";
import { detectInstalledTools } from "./tool-detector";
import { SessionManager, type DeleteSessionOptions } from "./session-manager";
import { WorktreeError } from "./worktrees/worktree-manager";
import { WorktreeManager } from "./worktrees/worktree-manager";
import { CheckoutStore } from "./worktrees/checkout-store";
import { resolveProject } from "./worktrees/project-resolver";
import { CheckoutRuntimeRegistry } from "./worktrees/checkout-runtime-registry";
import type { CheckoutRecord } from "./worktrees/checkout-types";
import { SessionNamer } from "./session-namer";
import { resolveStructuredTitle } from "./agents/title-dispatch";
import { generateSessionTitle } from "./agents/title-generate";
import { agentSpec, BY_HOOK_NAME } from "./agents/registry";
import { HandlerEngine, type HandlerEvent } from "./handler/engine";
import { classifyTurnEndError } from "./handler/lifecycle-classify";
import { createDispatchAdapter, createPtyAdapter } from "./handler/session-adapter";
import { createStructuredAdapter } from "./handler/structured-adapter";
import { dispatchRpc } from "./rpc/methods";
import { StructuredAgentManager } from "./structured/structured-manager";
import { parseCodexVersion } from "./codex/codex-version";
import { TOOL_UPDATE_SPECS, createToolUpdateChecker, execToolUpdate, execToolVersion, runToolUpdate, updateSpecFor } from "./agent-update";
import { getGitStatus, gitCommit, gitDiscard, type GitFileEntry } from "./git";
import { listLocalBranches, checkoutLocalBranch } from "./git-branches";
import { WORKTREE_SESSIONS_SUPPORTED } from "./worktree-capability";

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
  configuredTerminalIds: Map<string, string>;
  started: boolean;
}

// Tracks terminal ids that have pinged /hook-alive (codex SessionStart probe).
// Module-level so it lives as long as the process — terminals cleared from this
// Set on exit aren't re-added, keeping the warning one-shot per spawn.
const codexHookAlive = new Set<string>();

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

// Lives with codex's driver (it is codex's app-server quirk, not a core one).
export { codexNotifyOnlyArgs } from "./agents/codex/driver";

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
  /** True when this project has a non-main managed checkout. */
  hasManagedSessions(): boolean;
  /** True when a work-status key is bound to the main checkout (or is not a
   *  session at all). Pre-handshake this answers true — nothing is isolated
   *  yet, so no guard should be narrowed away. */
  isMainCheckoutSession(id: string): boolean;
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
  onAnswer?: (sessionId: string) => void;
  /** This session's status in the owner's work reduction, stamped onto each
   *  `session:updated` entry so the app has a per-session status on the LIVE
   *  session stream rather than only on the advert. The owner must call
   *  {@link AgentCore.refreshSessionWork} when the reduction moves — the list
   *  is otherwise only re-emitted when the sessions themselves change. */
  sessionWorkStatusFor?: (sessionId: string) => WorkStatus | undefined;
  /** Relay base URL of the machine socket this core attaches to. Host-supplied
   *  in remote mode: only a standalone agent with an explicit `relayUrl:` in its
   *  antgrid.yaml can learn it from config, so without this a host-spawned
   *  remote core has no relay coordinate to put in its banner/connect URI. */
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
      mode: "agent",
      terminalCount: (buildAgentTerminalSpec() ? 1 : 0) + getServices().length || 1,
      commandCount: config.commands?.length,
      proxyCount: config.ports?.length,
      projectPath: project.path,
      projectId: project.id,
      ed25519PublicKey: identity.ed25519PublicKey,
    }).catch((err) => log.warn("Banner display failed: %s", err));
  }

  let manager: TerminalManager | null = null;
  let sessions: SessionManager | null = null;
  let namer: SessionNamer | null = null;
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
      configuredTerminalIds: new Map(),
      started: false,
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

  function sendFromRuntime(runtime: CheckoutRuntime, msg: AbMessage): void {
    sendAb({ ...msg, checkoutId: runtime.checkout.id } as AbMessage);
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

  function handleAbMessage(msg: AbMessage) {
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
        handlerEngine.onUserReply(msg.sessionId, "\r");
        // A RESOLVE additionally unblocks the session: the block is gone and the
        // agent resumes on THIS session, so report it now rather than waiting for
        // the driver's next outbound frame — that is what flips the session's dot
        // from "needs you" back to "working" the instant the user replies. A bare
        // prompt is excluded; its driver emits a real `agent:turn-start`. Not
        // onTurnStart either: a resolve that raced a retraction has nothing to
        // resume, and must not open a turn nothing will close.
        if (msg.type !== "agent:prompt") opts.onAnswer?.(msg.sessionId);
        void structured?.handleAgentMessage(msg);
        return;
      case "agent:cancel":
        // Not onUserReply: a cancel is not an answer, so pending escalations
        // stand. It does end a self-resuming park, whose only wake path was the
        // driver's retry loop — the very loop this cancel stops.
        handlerEngine.onTurnCancelled(msg.sessionId);
        void structured?.handleAgentMessage(msg);
        return;
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
        break;
      case "handler:configure": {
        // parseMessageFast (the encrypted/local hot path) validates only the
        // message type — every field below is still untrusted, and validating
        // just the brief is not enough: a `notifyOnly` that arrives absent or
        // non-bool reads as falsy and would arm an auto-injecting session the
        // user asked to be notify-only.
        const parsed = HandlerConfigureWire.safeParse(msg);
        if (parsed.success && parsed.data.armed && parsed.data.brief) {
          const { terminalId, brief, notifyOnly, judgeTool, judgeModel } = parsed.data;
          handlerEngine.arm({ terminalId, brief, notifyOnly, judgeTool, judgeModel });
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
      case "handler:planRequest":
        // Same untrusted-payload rule: a non-string terminalId would spend a full
        // judge spawn planning against an empty context for a slot that can't exist.
        if (typeof msg.terminalId !== "string") {
          logger.warn("handler:planRequest ignored: malformed payload");
          break;
        }
        handlerEngine.plan(msg.terminalId, {
          judgeTool: typeof msg.judgeTool === "string" ? msg.judgeTool : undefined,
          judgeModel: typeof msg.judgeModel === "string" ? msg.judgeModel : undefined,
        }).catch((err) => logger.error("Handler plan failed: %s", err));
        break;
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
        handleGitCommit(runtime, msg.projectId, msg.message, msg.files).catch((err) =>
          log.error("git:commit handler failed: %s", err)
        );
        break;
      }
      case "git:discard": {
        handleGitDiscard(runtime, msg.projectId, msg.files).catch((err) =>
          log.error("git:discard handler failed: %s", err)
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
        const proc = spawn(cmdConfig.command, args, {
          cwd,
          env,
          shell: true,
          stdio: ["ignore", "pipe", "pipe"],
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
        const chatIds = (sessions?.list(true) ?? [])
          .filter((s) => s.mode === "chat" && (s.tool ?? "codex") === spec.tool && s.running)
          .map((s) => s.id);
        log.info("agent:update — quiescing %d %s session(s) to update", chatIds.length, spec.tool);
        void runToolUpdate({
          sessionIds: chatIds,
          // stopChat resolves only once the process has exited (its dispose awaits
          // proc.exited), so awaiting it releases the binary handle + any per-tool
          // lock. start() re-spawns on the fresh binary and resumes the thread.
          stop: (id) => structured?.stopChat(id) ?? Promise.resolve(),
          // Returned, not discarded: an isolated session's start is async and
          // rejects when its worktree has gone, and runToolUpdate's per-session
          // try/catch is what keeps one dead restart from sinking the rest.
          start: (id) => sessions?.start(id),
          execUpdate: () => execToolUpdate(spec),
          installedAfter: async () => parseCodexVersion(await execToolVersion(spec)),
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
      case "session:set-mode": {
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
        // Only set-mode awaits (it waits out the old runtime's teardown before
        // restarting on the new one). Every other verb still runs straight
        // through to its reply without yielding, since an async body runs
        // synchronously until its first await.
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
        if (!sessions) break;
        sessions.focus(msg.sessionId);
        break;
      }
      case "client:focus-state": {
        connState.appFocusPaused = msg.paused;
        log.info("focus-state: paused=%s", msg.paused);
        break;
      }
      case "terminal:snapshot:request": {
        const snap = manager.getScrollback(internalTerminalId(runtime, msg.terminalId));
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
        const fw = runtime.fileWatcher;
        if (!fw) break;
        const { tree, seq } = fw.getTreeSnapshot();
        sendFromRuntime(runtime, createMessage("file:tree:snapshot", { tree, seq }));
        break;
      }
      case "preview:snapshot:request": {
        if (!runtime.tunnelManager) break;
        sendFromRuntime(runtime, createMessage("preview:snapshot", {
          urls: runtime.tunnelManager.getPreviewSnapshot(),
        }));
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

  function teardownServices() {
    for (const runtime of checkoutRuntimes.values()) {
      for (const proc of runtime.runningCommands.values()) proc.kill();
      runtime.runningCommands.clear();
      runtime.configController.stopWatch();
      runtime.fileWatcher?.stop();
      runtime.uploadManager?.stop();
      runtime.portDetector?.stop();
      runtime.tunnelManager?.stop();
      if (runtime.gitBranchInterval) clearInterval(runtime.gitBranchInterval);
      runtime.gitBranchInterval = null;
      runtime.started = false;
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
    void structured?.disposeAll();
    structured = null;
  }

  // Outbound senders — initially no-op until a transport is attached.
  let sendAb: (msg: AbMessage) => void = (_m) => {};
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
  const handlerEngine = new HandlerEngine({
    projectId: project.id,
    projectPath: (terminalId) => checkoutPathFor(terminalId),
    tool: (terminalId) =>
      (terminalId ? sessions?.get(terminalId)?.tool : undefined) ?? config.agent?.tool ?? "claude-code",
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

  async function refreshGitStatus(runtime: CheckoutRuntime = mainRuntime): Promise<void> {
    runtime.cachedGitFiles = await getGitStatus(runtime.checkout.path);
  }

  function sendGitStatus(runtime: CheckoutRuntime = mainRuntime) {
    sendFromRuntime(runtime,
      createMessage("git:status", {
        projectId: project.id,
        files: runtime.cachedGitFiles,
      })
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

  async function handleGitCommit(runtime: CheckoutRuntime, projectId: string, message: string, files: string[]) {
    const result = await gitCommit(runtime.checkout.path, message, files);
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

  async function handleGitDiscard(runtime: CheckoutRuntime, projectId: string, files: string[]) {
    // gitDiscard classifies tracked vs untracked from live git state itself —
    // don't thread a (possibly stale) cachedGitFiles snapshot through.
    const result = await gitDiscard(runtime.checkout.path, files);
    sendFromRuntime(runtime, createMessage("git:discard-result", {
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
      // HEAD nor the index), so a tapped "?" file would render a blank diff.
      // Diff it against /dev/null via `--no-index` to show its full content as
      // additions. (`--no-index` exits 1 when files differ — normal for a new
      // file — so treat 0 and 1 as success.)
      const isUntracked = runtime.cachedGitFiles.some(
        (f) => f.path === path && f.status === "?",
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

  function sendStatus(runtime: CheckoutRuntime = mainRuntime) {
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
      })
    );
  }

  async function resyncState() {
    log.info("App reconnected, re-syncing existing state");
    // Use cached git state for the immediate resync; refresh in background.
    for (const runtime of checkoutRuntimes.values()) {
      sendStatus(runtime);
      sendGitStatus(runtime);
      void Promise.all([refreshGitBranch(runtime), refreshGitStatus(runtime)])
        .then(() => {
          sendStatus(runtime);
          sendGitStatus(runtime);
        })
      // refreshGit* swallow internally today, but guard against a future
      // edit that lets an exception escape silently breaking the re-emit.
        .catch(() => {});
    }

    // Re-send file tree
    for (const runtime of checkoutRuntimes.values()) runtime.fileWatcher?.sendFullTree();

    // Re-emit the detected-port list. ports:update is only pushed on change,
    // so a phone that binds after detection would otherwise never see ports
    // found before it connected (preview:snapshot only covers config-declared
    // preview ports, not ad-hoc detections).
    for (const runtime of checkoutRuntimes.values()) runtime.portDetector?.emitCurrent();

    // Re-send terminal scrollback so the app has current output
    if (manager) {
      for (const t of manager.getStatus()) {
        const snap = manager.getScrollback(t.terminalId);
        if (snap && snap.text) {
          sendTerminalFrame(createMessage("terminal:output", {
            terminalId: terminalOwner(t.terminalId).externalId,
            data: snap.text,
          }));
        }
      }
    }
  }

  async function startCheckoutRuntime(runtime: CheckoutRuntime): Promise<void> {
    if (runtime.started || !manager) return;
    runtime.started = true;
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
      send,
      connState,
    );
    runtime.fileWatcher = fw;
    runtime.fileSearcher = new FileSearcher(runtime.checkout.path, project.id, send);
    runtime.uploadManager = new FileUploadManager({
      projectId: project.id,
      projectPath: runtime.checkout.path,
      send,
    });
    runtime.uploadManager.startSweeper();
    fw.sendFullTree();
    fw.startWatching();

    runtime.configController.watch((result, diff) => {
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

    for (const service of runtime.config.services ?? []) {
      if (service.autoStart === false) continue;
      manager.spawn({
        terminalId: internalTerminalId(runtime, service.name),
        name: service.name,
        command: service.command,
        args: service.args,
        cwd: service.workingDir ?? runtime.checkout.path,
        env: service.env,
        type: "service",
      });
    }
    await Promise.all([refreshGitBranch(runtime), refreshGitStatus(runtime)]);
    sendStatus(runtime);
    sendGitStatus(runtime);
    runtime.gitBranchInterval = setInterval(async () => {
      const branch = runtime.cachedGitBranch;
      const files = JSON.stringify(runtime.cachedGitFiles);
      await Promise.all([refreshGitBranch(runtime), refreshGitStatus(runtime)]);
      if (runtime.cachedGitBranch !== branch) sendStatus(runtime);
      if (JSON.stringify(runtime.cachedGitFiles) !== files) sendGitStatus(runtime);
    }, 10_000);
  }

  async function prepareCheckoutRuntime(checkout: CheckoutRecord): Promise<CheckoutRuntime> {
    const existing = checkoutRuntimes.runtime(checkout.id);
    if (existing) {
      await startCheckoutRuntime(existing);
      return existing;
    }
    const runtimeConfig = loadConfig(undefined, checkout.path);
    const spec = agentSpecForConfig(runtimeConfig);
    const runtime = createCheckoutRuntime(checkout, runtimeConfig, spec);
    await checkoutRuntimes.prepare(checkout, runtimeConfig, spec, runtime);
    await startCheckoutRuntime(runtime);
    return runtime;
  }

  async function teardownCheckoutRuntime(checkoutId: string): Promise<void> {
    const runtime = checkoutRuntimes.runtime(checkoutId);
    if (!runtime || checkoutId === "main") return;
    for (const proc of runtime.runningCommands.values()) proc.kill();
    runtime.runningCommands.clear();
    for (const internalId of runtime.configuredTerminalIds.values()) manager?.kill(internalId);
    runtime.configController.stopWatch();
    runtime.fileWatcher?.stop();
    runtime.uploadManager?.stop();
    runtime.portDetector?.stop();
    runtime.tunnelManager?.stop();
    if (runtime.gitBranchInterval) clearInterval(runtime.gitBranchInterval);
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
      // OSC 0/2 terminal title → auto-name policy. Self-correlated per PTY.
      onTerminalTitle: (id, title) => namer?.onOscTitle(id, title),
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
        evt = { terminalId: msg.sessionId, event: "permission_request", detail: msg.title };
      } else if (msg.type === "agent:question") {
        evt = { terminalId: msg.sessionId, event: "question", detail: msg.prompt };
      } else if (msg.type === "agent:request-retracted") {
        // The blocking prompt is gone — clear its forced escalation instead of
        // leaving a "needs you" row pointing at a prompt that no longer exists.
        handlerEngine.onPromptRetracted(msg.sessionId);
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
      prepareCheckoutRuntime: async (checkout) => { await prepareCheckoutRuntime(checkout); },
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

    // Probe: codex injects a SessionStart hook that pings /hook-alive. If no ping
    // arrives within 10s the trust fingerprint likely drifted — codex's hooks are
    // Untrusted/skipped, so BOTH its plugin notifications and its structured
    // title correlation are dead (same injected hooks.state file, see
    // agent-launch-augmenter.ts). Re-enable the OSC scanner (notifications AND
    // title) as a best-effort fallback so the session isn't permanently muted or
    // nameless, and warn. Only codex arms this (expectsHookAliveProbe);
    // claude/opencode have no /hook-alive probe and must never trip this warning.
    manager.onSessionCreated((session) => {
      if (!session.expectsHookAliveProbe) return;
      const id = session.terminalId;
      setTimeout(() => {
        if (!codexHookAlive.has(id)) {
          session.enableOscNotifications();
          session.enableOscTitle();
          log.warn(
            "codex hooks did not ping /hook-alive for %s — trust fingerprint " +
            "may have drifted; re-enabled OSC scanner (notifications + title) as fallback",
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
    void Promise.all([refreshGitBranch(), refreshGitStatus()])
      .then(() => {
        sendStatus();
        sendGitStatus();
      })
      .catch(() => {});

    // Refresh git branch every 10s and re-send status if it changed
    mainRuntime.gitBranchInterval = setInterval(async () => {
      const prevBranch = mainRuntime.cachedGitBranch;
      const prevFiles = JSON.stringify(mainRuntime.cachedGitFiles);
      await Promise.all([refreshGitBranch(mainRuntime), refreshGitStatus(mainRuntime)]);
      if (mainRuntime.cachedGitBranch !== prevBranch) sendStatus(mainRuntime);
      if (JSON.stringify(mainRuntime.cachedGitFiles) !== prevFiles) sendGitStatus(mainRuntime);
    }, 10_000);

    const fw = new FileWatcher(project, (msg: AbMessage) => sendAb(msg), connState);
    fileWatchers.set(project.id, fw);
    mainRuntime.fileWatcher = fw;
    uploadManager = new FileUploadManager({
      projectId: project.id,
      projectPath: project.path,
      send: (msg) => sendAb(msg),
    });
    uploadManager.startSweeper();
    mainRuntime.uploadManager = uploadManager;
    fw.sendFullTree();
    fw.startWatching();

    const mainSearcher = new FileSearcher(project.path, project.id, (msg) => sendFromRuntime(mainRuntime, msg));
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
    // nothing is armed — the briefing sheet arms with what it was seeded with.
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
      // opencode posts the title inline; Claude/Codex post only correlation
      // ids, so resolve the title from their on-disk session files (async read,
      // off the event loop). resolveStructuredTitle swallows its own errors, so
      // the unawaited promise can't reject.
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
    onHookAlive: (terminalId) => { codexHookAlive.add(terminalId); },
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
      if (source !== "loopback" && sessions?.hasManagedSessions() && !currentPeerCanRouteCheckouts()) {
        log.warn("Dropping inbound %s: remote app lacks checkout routing (project %s)", msg.type, project.id);
        return;
      }
      if (msg.type === "request") {
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
        void checkoutRuntimes.resolve(checkoutId).then(async (checkout) => {
          if (!checkout) {
            log.warn("Rejecting %s for unknown checkout %s (project %s)", msg.type, checkoutId, project.id);
            bus.publish(createMessage("control:result", {
              ok: false,
              error: { code: "UNKNOWN_CHECKOUT", message: "The requested checkout is not available." },
              checkoutId,
            }), channel);
            return;
          }
          if (checkoutId !== "main") await prepareCheckoutRuntime(checkout);
          handleAbMessage({ ...msg, checkoutId } as AbMessage);
        }).catch((error) => log.warn("Checkout lookup failed for %s: %s", checkoutId, error));
        return;
      }
      handleAbMessage(msg);
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
      teardownServices();
      const closed = manager ? await manager.killAllGracefully(5000) : 0;

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
    hasManagedSessions(): boolean {
      return sessions?.hasManagedSessions() ?? false;
    },
    isMainCheckoutSession(id: string): boolean {
      return sessions?.isMainCheckoutSession(id) ?? true;
    },
  };
}
