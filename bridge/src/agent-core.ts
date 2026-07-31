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
import { createMessage, HandlerConfigureWire, type AbMessage, type RpcRequest, type SessionEntry } from "./protocol";
import { parseTunnelMessage } from "./tunnel-protocol";
import { startApiServer, type ApiServerHandle, type SessionTitleBody } from "./api-server";
import { MessageBus } from "./message-bus";
import { resolveAbDir } from "./antgrid-dir";
import { computeProjectId } from "./project-id";
import { loadPairedPhones, type PairedPhonesStore } from "./paired-phones";
import { ConfigController } from "./config-controller";
import { detectInstalledTools } from "./tool-detector";
import { SessionManager } from "./session-manager";
import { SessionNamer } from "./session-namer";
import { resolveStructuredTitle } from "./agents/title-dispatch";
import { generateSessionTitle } from "./agents/title-generate";
import { agentSpec, BY_HOOK_NAME } from "./agents/registry";
import { HandlerEngine } from "./handler/engine";
import { createDispatchAdapter, createPtyAdapter } from "./handler/session-adapter";
import { createStructuredAdapter } from "./handler/structured-adapter";
import { dispatchRpc } from "./rpc/methods";
import { StructuredAgentManager } from "./structured/structured-manager";
import { parseCodexVersion } from "./codex/codex-version";
import { TOOL_UPDATE_SPECS, createToolUpdateChecker, execToolUpdate, execToolVersion, runToolUpdate, updateSpecFor } from "./agent-update";
import { getGitStatus, gitCommit, gitDiscard, type GitFileEntry } from "./git";

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
  /** Stream-gating state. The transport's peer-online/offline callbacks flip
   *  `peerOnline` to suppress the heavy stream while the paired phone is gone. */
  readonly connState: ConnState;
  /** Delete a session via the live SessionManager (kills its PTY, flushes
   *  sessions.json, emits session:updated). Returns false if sessions aren't
   *  initialized yet (pre-handshake). The control-plane delete RPC calls this
   *  for a warm core so the on-disk file and in-memory state stay consistent. */
  deleteSession(id: string): boolean;
  /** Live session list with true per-session `running` (via SessionManager's
   *  in-memory PTY/chat sets), for the control-plane `sessions.list` peek when a
   *  warm core owns the project — the disk-only `readPersisted` reports every
   *  session not-running. Returns null before sessions are initialized
   *  (pre-handshake), signalling the caller to fall back to the on-disk list. */
  listSessions(includeArchived: boolean): SessionEntry[] | null;
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
   *  on a fresh turn. Bridge-internal — never surfaces to the app. */
  onTurnStart?: () => void;
  /** Relay base URL of the machine socket this core attaches to. Host-supplied
   *  in remote mode: only a standalone agent with an explicit `relayUrl:` in its
   *  antgrid.yaml can learn it from config, so without this a host-spawned
   *  remote core has no relay coordinate to put in its banner/connect URI. */
  relayUrl?: string;
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
  const runningCommands = new Map<string, ChildProcess>();

  function nextKeypair(): EphemeralKeypair {
    return generateEphemeralKeypair();
  }

  // "Is this a REMOTE peer?" signal, not an authorization input. Wired by the
  // remote/promotion transports to RelayClient.currentPeerPubkey(); unset (null)
  // in local mode, where there is no relay peer.
  let peerPubkeyProvider: (() => string | null) | null = null;
  function setPeerPubkeyProvider(fn: (() => string | null) | null) {
    peerPubkeyProvider = fn;
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
    if (msg.type === "tunnel:http-request" && tunnelManager) {
      tunnelManager.onHttpRequest(msg).catch((err) =>
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
        void structured?.handleAgentMessage(msg);
        return;
      case "agent:cancel":
      case "agent:set-config":
      case "agent:session-action":
        void structured?.handleAgentMessage(msg);
        return;
    }
    if (!manager) return;
    switch (msg.type) {
      case "terminal:input":
        manager.write(msg.terminalId, msg.data);
        // Typing into a session counts as activity — float it up the drawer.
        // No-ops for non-session terminals (service PTYs).
        sessions?.touch(msg.terminalId);
        // A user reply resets the handler's runaway guard; a submitted line
        // (data carrying CR/LF) also clears the pending escalations.
        handlerEngine.onUserReply(msg.terminalId, msg.data);
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
        const savedService = getServices().find((s) => s.name === msg.terminalId);
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
          terminalId: msg.terminalId,
          name: msg.name ?? savedName,
          command: msg.command ?? savedCommand,
          args: msg.args ?? savedArgs,
          cwd: msg.cwd ?? savedCwd ?? project.path,
          env: msg.env ?? savedEnv,
          type: savedService ? "service" : undefined,
        });
        sendStatus();
        break;
      }
      case "terminal:stop":
        manager.kill(msg.terminalId);
        sendStatus();
        break;
      case "terminal:resize":
        manager.resize(
          msg.terminalId,
          msg.clientId,
          msg.cols,
          msg.rows,
          msg.baseDriverClientId,
        );
        break;
      case "file:read": {
        const fw = fileWatchers.get(msg.projectId);
        if (fw) {
          fw.handleFileReadRequest(msg.path);
        } else {
          log.warn("file:read for unknown projectId: %s", msg.projectId);
        }
        break;
      }
      case "file:upload-start":
        uploadManager?.handleStart(msg);
        break;
      case "file:upload-chunk":
        uploadManager?.handleChunk(msg);
        break;
      case "file:upload-done":
        uploadManager?.handleDone(msg);
        break;
      case "file:search": {
        const fs = fileSearchers.get(msg.projectId);
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
        const fs = fileSearchers.get(msg.projectId);
        if (fs) {
          fs.cancel(msg.requestId);
        }
        break;
      }
      case "git:diff": {
        handleGitDiffRequest(msg.projectId, msg.path).catch((err) =>
          log.error("git:diff handler failed: %s", err)
        );
        break;
      }
      case "git:list-branches": {
        handleGitListBranches(msg.projectId).catch((err) =>
          log.error("git:list-branches handler failed: %s", err)
        );
        break;
      }
      case "git:checkout": {
        handleGitCheckout(msg.projectId, msg.branch).catch((err) =>
          log.error("git:checkout handler failed: %s", err)
        );
        break;
      }
      case "git:commit": {
        handleGitCommit(msg.projectId, msg.message, msg.files).catch((err) =>
          log.error("git:commit handler failed: %s", err)
        );
        break;
      }
      case "git:discard": {
        handleGitDiscard(msg.projectId, msg.files).catch((err) =>
          log.error("git:discard handler failed: %s", err)
        );
        break;
      }
      case "command:run": {
        const cmdConfig = config.commands?.find((c) => c.name === msg.commandName);
        if (!cmdConfig) {
          log.warn("command:run for unknown command: %s", msg.commandName);
          sendAb(createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: 1,
          }));
          break;
        }

        // Reject unconfirmed runs of commands marked confirm: true
        if (cmdConfig.confirm && !msg.confirmed) {
          log.warn("command:run rejected — '%s' requires confirmation", msg.commandName);
          sendAb(createMessage("command:output", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            data: "Error: command requires confirmation (confirmed: true)\n",
          }));
          sendAb(createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: 1,
          }));
          break;
        }

        const args = cmdConfig.args ?? [];
        const cwd = cmdConfig.workingDir ?? project.path;
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
        runningCommands.set(cmdKey, proc);

        const streamOutput = (stream: NodeJS.ReadableStream) => {
          stream.on("data", (chunk: Buffer) => {
            sendAb(createMessage("command:output", {
              projectId: msg.projectId,
              commandName: msg.commandName,
              data: chunk.toString(),
            }));
          });
        };

        if (proc.stdout) streamOutput(proc.stdout);
        if (proc.stderr) streamOutput(proc.stderr);

        proc.on("close", (code) => {
          runningCommands.delete(cmdKey);
          sendAb(createMessage("command:done", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            exitCode: code,
          }));
        });

        proc.on("error", (err) => {
          runningCommands.delete(cmdKey);
          sendAb(createMessage("command:output", {
            projectId: msg.projectId,
            commandName: msg.commandName,
            data: `Error: ${err.message}\n`,
          }));
          sendAb(createMessage("command:done", {
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
          start: (id) => { sessions?.start(id); },
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
        emitConfigState();
        break;
      }
      case "config:write": {
        const w = configController.write(msg.config as import("./config").AbConfig);
        sendAb(createMessage("config:write-result", {
          ok: w.ok,
          errors: w.ok ? undefined : w.errors,
        }));
        break;
      }
      case "config:detect-tools": {
        sendAb(createMessage("config:detect-tools-result", {
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
        try {
          const s = sessions.create(msg.name, {
            tool: msg.tool,
            command: msg.command,
            args: msg.args,
            mode: msg.mode,
          });
          sendAb(createMessage("session:result", {
            requestId: msg.requestId, ok: true, session: s,
          }));
        } catch (err) {
          sendAb(createMessage("session:result", {
            requestId: msg.requestId, ok: false, error: String(err),
          }));
        }
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
          try {
            if (verb.type === "session:start") s.start(verb.sessionId, verb.initialPrompt);
            else if (verb.type === "session:stop") s.stop(verb.sessionId);
            else if (verb.type === "session:rename") s.rename(verb.sessionId, verb.name);
            else if (verb.type === "session:archive") s.archive(verb.sessionId);
            else if (verb.type === "session:unarchive") s.unarchive(verb.sessionId);
            else if (verb.type === "session:delete") s.delete(verb.sessionId);
            else if (verb.type === "session:set-mode") await s.setMode(verb.sessionId, verb.mode);
            const entry = s.get(verb.sessionId);
            sendAb(createMessage("session:result", {
              requestId: verb.requestId, ok: true, session: entry,
            }));
          } catch (err) {
            sendAb(createMessage("session:result", {
              requestId: verb.requestId, ok: false, error: String(err),
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
        const snap = manager.getScrollback(msg.terminalId);
        if (!snap) {
          log.warn("snapshot requested for unknown terminal %s", msg.terminalId);
          break;
        }
        sendAb(createMessage("terminal:snapshot", {
          terminalId: msg.terminalId,
          scrollback: snap.text,
          seq: snap.seq,
        }));
        break;
      }
      case "file:tree:snapshot:request": {
        // Single-project agent: only one watcher in the map.
        const fw = [...fileWatchers.values()][0];
        if (!fw) break;
        const { tree, seq } = fw.getTreeSnapshot();
        sendAb(createMessage("file:tree:snapshot", { tree, seq }));
        break;
      }
      case "preview:snapshot:request": {
        if (!tunnelManager) break;
        sendAb(createMessage("preview:snapshot", {
          urls: tunnelManager.getPreviewSnapshot(),
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
    // Kill running command processes
    for (const [key, proc] of runningCommands) {
      proc.kill();
      runningCommands.delete(key);
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
    if (gitBranchInterval) {
      clearInterval(gitBranchInterval);
      gitBranchInterval = null;
    }
  }

  // Outbound senders — initially no-op until a transport is attached.
  let sendAb: (msg: AbMessage) => void = (_m) => {};
  let sendPlain: (data: object) => void = (_d) => {};
  // Replay-cache eviction for torn-down chat sessions; bound with the bus in
  // attachTransport, like sendAb.
  let dropSessionReplay: (sessionId: string) => void = (_s) => {};
  let isShuttingDown = false;

  // Every producer of notification:push sends through here, so the per-session
  // work reduction sees exactly the frames the project-level one folds off the
  // bus (ProjectCore.observeWorkStatus) and the two can't diverge. Folded after
  // the send: the fold re-advertises the session list, which must not nest
  // inside the notification's own publish.
  function sendNotifying(msg: AbMessage): void {
    sendAb(msg);
    sessions?.observeNotification(msg);
  }

  // Eager, factory-scoped (NOT in setupServices): handleAbMessage and startApiServer
  // are wired synchronously and can fire before setupServices resolves. The arrow
  // deps defer their reads, so a later-assigned sendAb/manager/sessions is picked
  // up correctly, same pattern as the existing manager? deps.
  const handlerEngine = new HandlerEngine({
    projectId: project.id,
    projectPath: project.path,
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

  let cachedGitBranch: string | null = null;

  async function refreshGitBranch(): Promise<void> {
    try {
      const proc = Bun.spawn(["git", "rev-parse", "--abbrev-ref", "HEAD"], {
        cwd: project.path,
        stdout: "pipe",
        stderr: "ignore",
      });
      const output = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;
      cachedGitBranch = exitCode === 0 ? output.trim() || null : null;
    } catch {
      cachedGitBranch = null;
    }
  }

  let cachedGitFiles: GitFileEntry[] = [];

  async function refreshGitStatus(): Promise<void> {
    cachedGitFiles = await getGitStatus(project.path);
  }

  function sendGitStatus() {
    sendAb(
      createMessage("git:status", {
        projectId: project.id,
        files: cachedGitFiles,
      })
    );
  }

  async function handleGitListBranches(projectId: string) {
    try {
      const proc = Bun.spawn(["git", "branch", "--no-color"], {
        cwd: project.path,
        stdout: "pipe",
        stderr: "ignore",
      });
      const output = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;
      if (exitCode !== 0) return;

      let current = cachedGitBranch ?? "";
      const branches: string[] = [];
      for (const line of output.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        if (trimmed.startsWith("* ")) {
          const name = trimmed.slice(2);
          current = name;
          branches.push(name);
        } else {
          branches.push(trimmed);
        }
      }

      sendAb(createMessage("git:branches", {
        projectId,
        current,
        branches,
      }));
    } catch {
      // ignore
    }
  }

  async function handleGitCheckout(projectId: string, branch: string) {
    try {
      const proc = Bun.spawn(["git", "switch", branch], {
        cwd: project.path,
        stdout: "pipe",
        stderr: "pipe",
      });
      const stderr = await new Response(proc.stderr).text();
      const exitCode = await proc.exited;

      if (exitCode === 0) {
        sendAb(createMessage("git:checkout-result", {
          projectId,
          branch,
          success: true,
        }));

        // Refresh cached state and notify app
        cachedGitBranch = branch;
        sendStatus();
        await refreshGitStatus();
        sendGitStatus();
      } else {
        sendAb(createMessage("git:checkout-result", {
          projectId,
          branch,
          success: false,
          error: stderr.trim() || "Checkout failed",
        }));
      }
    } catch (err) {
      sendAb(createMessage("git:checkout-result", {
        projectId,
        branch,
        success: false,
        error: String(err),
      }));
    }
  }

  async function handleGitCommit(projectId: string, message: string, files: string[]) {
    const result = await gitCommit(project.path, message, files);
    sendAb(createMessage("git:commit-result", {
      projectId,
      success: result.success,
      ...(result.sha ? { sha: result.sha } : {}),
      ...(result.error ? { error: result.error } : {}),
    }));
    if (result.success) {
      await refreshGitStatus();
      sendGitStatus();
      sendStatus();
    }
  }

  async function handleGitDiscard(projectId: string, files: string[]) {
    // gitDiscard classifies tracked vs untracked from live git state itself —
    // don't thread a (possibly stale) cachedGitFiles snapshot through.
    const result = await gitDiscard(project.path, files);
    sendAb(createMessage("git:discard-result", {
      projectId,
      success: result.success,
      files,
      ...(result.error ? { error: result.error } : {}),
    }));
    if (result.success) {
      await refreshGitStatus();
      sendGitStatus();
      sendStatus();
    }
  }

  async function handleGitDiffRequest(projectId: string, path: string) {
    try {
      // `git diff HEAD` emits nothing for untracked files (they're in neither
      // HEAD nor the index), so a tapped "?" file would render a blank diff.
      // Diff it against /dev/null via `--no-index` to show its full content as
      // additions. (`--no-index` exits 1 when files differ — normal for a new
      // file — so treat 0 and 1 as success.)
      const isUntracked = cachedGitFiles.some(
        (f) => f.path === path && f.status === "?",
      );
      const args = isUntracked
        ? ["diff", "--no-index", "--", "/dev/null", path]
        : ["diff", "HEAD", "--relative", "--", path];
      const proc = Bun.spawn(["git", "-c", "core.quotepath=false", ...args], {
        cwd: project.path,
        stdout: "pipe",
        stderr: "ignore",
      });
      const output = await new Response(proc.stdout).text();
      const exitCode = await proc.exited;
      if (isUntracked ? exitCode > 1 : exitCode !== 0) {
        sendAb(createMessage("git:diff-content", {
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

      sendAb(createMessage("git:diff-content", {
        projectId,
        path,
        diff: output || null,
        additions,
        deletions,
      }));
    } catch {
      sendAb(createMessage("git:diff-content", {
        projectId,
        path,
        diff: null,
        additions: 0,
        deletions: 0,
      }));
    }
  }

  function sendStatus() {
    if (!manager) return;
    // All terminals (agent + services + ad-hoc) flow through `terminals`;
    // the app filters by `type` to route them to the right UI surface.
    // Sessions advertise themselves through `session:updated`; the terminals
    // list now only reflects actually-spawned PTYs (agent or service).
    const terminalsForApp = manager.getStatus();

    // Service status: merge declared services with runtime session info
    const serviceStatus = getServices().map((s) => {
      const live = terminalsForApp.find((t) => t.terminalId === s.name);
      return {
        id: s.name,
        name: s.name,
        running: live?.running ?? false,
        command: s.command,
      };
    });

    // Ports: derive from config.ports, attaching detected URL when available
    const detected = portDetector?.getLastDetections() ?? new Map<number, { url: string; scheme: "http" | "https"; source: "process" | "output" }>();
    const portStatus = (config.ports ?? []).map((p) => {
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

    sendAb(
      createMessage("agent:status", {
        projectId: project.id,
        projectName: agentName,
        hostMachineName: process.env.ANTGRID_HOST_NAME ?? hostname(),
        terminals: terminalsForApp,
        services: serviceStatus,
        commands: config.commands?.map((c) => ({
          name: c.name,
          confirm: c.confirm,
          description: c.description,
          icon: c.icon,
        })),
        ports: portStatus,
        git: cachedGitBranch ? { branch: cachedGitBranch } : undefined,
        agent: {
          tool: config.agent?.tool,
          name: agentName,
          version: VERSION,
          flags: config.agent?.flags,
        },
        needsFirstRun,
      })
    );
  }

  let gitBranchInterval: ReturnType<typeof setInterval> | null = null;

  async function resyncState() {
    log.info("App reconnected, re-syncing existing state");
    // Use cached git state for the immediate resync; refresh in background.
    sendStatus();
    sendGitStatus();
    void Promise.all([refreshGitBranch(), refreshGitStatus()])
      .then(() => {
        sendStatus();
        sendGitStatus();
      })
      // refreshGit* swallow internally today, but guard against a future
      // edit that lets an exception escape silently breaking the re-emit.
      .catch(() => {});

    // Re-send file tree
    for (const fw of fileWatchers.values()) fw.sendFullTree();

    // Re-emit the detected-port list. ports:update is only pushed on change,
    // so a phone that binds after detection would otherwise never see ports
    // found before it connected (preview:snapshot only covers config-declared
    // preview ports, not ad-hoc detections).
    portDetector?.emitCurrent();

    // Re-send terminal scrollback so the app has current output
    if (manager) {
      for (const t of manager.getStatus()) {
        const snap = manager.getScrollback(t.terminalId);
        if (snap && snap.text) {
          sendAb(createMessage("terminal:output", {
            terminalId: t.terminalId,
            data: snap.text,
          }));
        }
      }
    }
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

    pd.onPortsChange = (ports) => {
      sendAb(createMessage("ports:update", { projectId: project.id, ports }));
      tm.onPortsUpdate(ports);
    };

    manager = new TerminalManager((msg: AbMessage) => sendAb(msg), {
      onTerminalOutput: (id, data) => pd.feed(id, data),
      onTerminalExited: (id) => {
        pd.removeTerminal(id);
        sessions?.noteExited(id);
        // Drop buffered title state so a stale title from this run can't leak
        // into a restarted same-id session (start() reuses the entry id).
        namer?.forget(id);
        // Reclaim the handler's per-terminal guard + pending state for the dead
        // terminal. A mode flip keeps the arming: the session outlives the PTY.
        handlerEngine.onTerminalExit(id, { keepArmed: sessions?.isFlipping(id) });
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
      let evt:
        | { terminalId: string; event: "turn_end" | "permission_request" | "question"; detail?: string }
        | null = null;
      // "error" counts as a turn boundary, not just "end_turn": a turn that died
      // leaves the agent idle and blocked, which is precisely when a supervising
      // handler must act. Skipping it let an armed session go silent forever on
      // the one outcome the user most wants to be woken for. "cancelled" stays
      // ignored — the user cancelled it, so they are already present.
      if (msg.type === "agent:turn-end" && (msg.stopReason === "end_turn" || msg.stopReason === "error")) {
        evt = { terminalId: msg.sessionId, event: "turn_end" };
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
        return driver({
          sessionId,
          send,
          projectPath: project.path,
          projectId: project.id,
          chatAugment: () => buildChatSpawnAugment(tool, sessionId, apiServer?.port ?? null, abDir),
          onAgentSession: (agentSessionId) => sessions?.setAgentSession(sessionId, agentSessionId),
          onTitle: (title) => namer?.onStructuredTitle(sessionId, title),
          emitUpdateCheck: () => emitUpdateCheck(tool, sessionId, send),
        });
      },
    });

    // SessionManager owns the persistent list of coding-agent sessions for this
    // project. PTY lifecycle is delegated to `manager` (TerminalManager); the
    // agent.tool config drives the spawn command for every session. A mode:'chat'
    // session bypasses the PTY and rides the chat bridges into `structured`.
    sessions = new SessionManager({
      projectId: project.id,
      storeDir: abDir,
      projectPath: project.path,
      terminalManager: manager,
      agentSpec: agentSpecFromConfig(),
      sendMessage: (msg) => sendAb(msg as AbMessage),
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
      session.onOutput((chunk) => pd.observeOutput(session.terminalId, chunk));
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
    gitBranchInterval = setInterval(async () => {
      const prevBranch = cachedGitBranch;
      const prevFiles = JSON.stringify(cachedGitFiles);
      await Promise.all([refreshGitBranch(), refreshGitStatus()]);
      if (cachedGitBranch !== prevBranch) sendStatus();
      if (JSON.stringify(cachedGitFiles) !== prevFiles) sendGitStatus();
    }, 10_000);

    const fw = new FileWatcher(project, (msg: AbMessage) => sendAb(msg), connState);
    fileWatchers.set(project.id, fw);
    uploadManager = new FileUploadManager({
      projectId: project.id,
      projectPath: project.path,
      send: (msg) => sendAb(msg),
    });
    uploadManager.startSweeper();
    fw.sendFullTree();
    fw.startWatching();

    fileSearchers.set(project.id, new FileSearcher(project.path, project.id, sendAb));
  }

  // Emit current config validity as a config:read-result. Mirrors the
  // `config:read` request handler, and is also pushed on every connect (see
  // onHandshakeComplete): the file watcher fires only on a CHANGE, not on
  // connect, and the app's drawer config-error dot clears only on a config
  // frame — so without this a stale cached dot would persist after the YAML
  // was fixed while disconnected.
  function emitConfigState() {
    const r = configController.read();
    if (r.ok) {
      sendAb(createMessage("config:read-result", { ok: true, config: r.config }));
    } else if (r.missing) {
      sendAb(createMessage("config:read-result", { ok: false }));
    } else {
      sendAb(createMessage("config:read-result", { ok: false, raw: r.raw, error: r.error }));
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
    onTurnStart: (terminalId) => {
      if (terminalId) sessions?.noteTurnStart(terminalId);
      opts.onTurnStart?.();
    },
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
      if (msg.type === "request") {
        if (msg.method === "session.transcriptSnapshot") {
          void handleTranscriptSnapshotRequest(msg).then((res) => bus.publish(res, channel));
          return;
        }
        void dispatchRpc(bus, msg).then((res) => bus.publish(res, channel));
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
    handleTunnelMessage,
    onHandshakeComplete,
    setPlainHook,
    setPeerPubkeyProvider,
    connState,
    deleteSession(id: string): boolean {
      if (!sessions) return false;
      return sessions.delete(id);
    },
    listSessions(includeArchived: boolean): SessionEntry[] | null {
      return sessions ? sessions.list(includeArchived) : null;
    },
  };
}
