import { createMessage, type AbMessage } from "../protocol";
import { isChatCapableTool } from "./chat-capable";
import type { CapCommand } from "./chat-session";
import type { ApprovalPolicy } from "../agents/types";

// Structural type the manager needs from a driver (CodexDriver satisfies it).
export interface StructuredDriver {
  // Resolves with the backend-native session id, or "" when the backend only
  // reports its id asynchronously (e.g. ClaudeDriver: the SDK emits it on
  // system:init, after start() must already have returned — see agents/claude-code/chat-backend.ts).
  // In the "" case the factory wires persistence out-of-band (an onSessionId
  // callback), and the manager must skip persistence for falsy ids — see the
  // `if (agentId)` guard in startChat.
  start(resumeId?: string): Promise<string>;
  // commandId present => slash-command invocation; text carries only the args.
  prompt(text: string, commandId?: string): Promise<void>;
  // Returns whether a live turn was actually interrupted. False means there was
  // nothing to cancel, and the manager answers the client itself — see the
  // agent:cancel case in handleAgentMessage.
  cancel(turnId?: string): Promise<boolean>;
  compact(): Promise<void>;
  revert(target: { turnId?: string; itemId?: string; messageId?: string; partId?: string }): Promise<void>;
  // Store a session-scoped selection (model/effort/mode); applied on the next
  // turn. Unknown keys/ids are ignored (no error round-trip — the absent
  // capabilities echo is the signal).
  setConfig(key: string, value: unknown): void;
  // Re-derive this session's completed-turn transcript from the live backend on
  // demand (no restart). Optional: only chat-capable drivers implement it.
  // Returns [] when there's nothing to backfill, or a turn is actively
  // streaming and can't be safely partial-included.
  getTranscriptSnapshot?(): Promise<AbMessage[]>;
  resolvePermission(permissionId: string, optionId: string): void;
  resolveQuestion(questionId: string, answer: string | string[]): void;
  // Stop one background task (agent:task-stop). Optional for the same reason as
  // getTranscriptSnapshot above: presence IS the capability, so there is no
  // second list to keep in lockstep. The verb is unreachable for a driver that
  // implements nothing — the app only offers a stop for a task the session
  // itself advertised — so the no-op is an invariant, not a silent default.
  stopTask?(taskId: string): Promise<void>;
  // This session's slash commands, or undefined when there is no catalog to
  // offer. Optional for the same reason as stopTask: presence IS the
  // capability, so there is no second list to keep in lockstep.
  commandCatalog?(): CapCommand[] | undefined;
  // May be async: a driver whose backend holds a process-global lock (codex's
  // ~/.codex sqlite) resolves only once that process has fully exited, so a
  // restart doesn't race the dying one for the lock.
  dispose(): void | Promise<void>;
}

export type DriverFactory = (
  sessionId: string,
  tool: string,
  sendMessage: (m: AbMessage) => void,
  resumeId?: string,
  approvalPolicy?: ApprovalPolicy,
) => StructuredDriver;

export interface StructuredAgentManagerOpts {
  driverFactory: DriverFactory;
  sendMessage: (msg: AbMessage) => void;
  // Called after a driver reports its agent-native session id, so the bridge can
  // persist it for resume (SessionManager.setAgentSession). Overwrite-latest.
  onAgentSession: (sessionId: string, agentSessionId: string) => void;
  // Called at teardown, after the empty capabilities frame is published, so the
  // MessageBus can drop the session's replay entry instead of caching the
  // tombstone forever (see MessageBus.dropSessionReplay).
  dropSessionReplay?: (sessionId: string) => void;
  // Called on every app-driven agent:set-config so the bridge can persist the
  // selection (SessionManager.setSessionConfig) for replay on the next start.
  // Overwrite-latest per key. Separate from the driver's own setConfig (which
  // applies it live) — this is only the durable write.
  onSetConfig?: (sessionId: string, key: string, value: string) => void;
  // Called with the text of every user prompt this manager delivers. A chat
  // session has no hook to carry its first message — the bridge itself is what
  // hands a prompt to the driver — so this is the only place one can be named
  // from what the user actually asked for.
  onUserPrompt?: (sessionId: string, text: string) => void;
}

export class StructuredAgentManager {
  private drivers = new Map<string, StructuredDriver>();
  // Race-guard: concurrent startChat calls for one session must not spawn two
  // drivers. Holds the in-flight start so late callers join it rather than
  // racing a second spawn.
  private starting = new Map<string, Promise<StructuredDriver>>();
  // In-flight teardowns, keyed by session. A restart (startChat) awaits its
  // session's pending stop before spawning so it can't race the dying process
  // for a backend-global lock (codex's ~/.codex sqlite).
  private stopping = new Map<string, Promise<void>>();
  // Sessions whose one-shot initial prompt has already been delivered this
  // lifetime. The relay offline-queue can replay a buffered `session:start`, and
  // startChat's idempotent already-running exits would otherwise inject the same
  // prompt as a second user turn. In-memory only (the prompt is never persisted);
  // cleared on teardown so a genuine relaunch may deliver its own prompt.
  private initialPromptDelivered = new Set<string>();
  private readonly factory: DriverFactory;
  private readonly send: (msg: AbMessage) => void;
  private readonly onAgentSession: (sessionId: string, agentSessionId: string) => void;
  private readonly dropSessionReplay?: (sessionId: string) => void;
  private readonly onSetConfig?: (sessionId: string, key: string, value: string) => void;
  private readonly onUserPrompt?: (sessionId: string, text: string) => void;

  constructor(opts: StructuredAgentManagerOpts) {
    this.factory = opts.driverFactory;
    this.send = opts.sendMessage;
    this.onAgentSession = opts.onAgentSession;
    this.dropSessionReplay = opts.dropSessionReplay;
    this.onSetConfig = opts.onSetConfig;
    this.onUserPrompt = opts.onUserPrompt;
  }

  async startChat(opts: { sessionId: string; tool: string; resumeId?: string; config?: Record<string, string>; initialPrompt?: string; approvalPolicy?: ApprovalPolicy }): Promise<void> {
    const { sessionId, tool, resumeId, config, initialPrompt, approvalPolicy = "default" } = opts;
    if (!isChatCapableTool(tool)) {
      throw new Error(`tool "${tool}" does not support chat mode`);
    }
    if (this.drivers.has(sessionId)) {
      // already running — idempotent, but a racing duplicate start still
      // carries the caller's own initialPrompt and must deliver it once.
      await this.deliverInitialPrompt(sessionId, initialPrompt, resumeId);
      return;
    }
    const inflight = this.starting.get(sessionId);
    if (inflight) {
      await inflight;
      await this.deliverInitialPrompt(sessionId, initialPrompt, resumeId);
      return;
    }

    const startPromise = (async () => {
      // A just-issued session:stop may still be tearing down the prior driver.
      // Wait it out so the new codex process spawns only after the old one has
      // exited and released the ~/.codex sqlite lock (else initialize wedges).
      const pendingStop = this.stopping.get(sessionId);
      if (pendingStop) await pendingStop;
      const driver = this.factory(sessionId, tool, this.send, resumeId, approvalPolicy);
      let agentId: string;
      try {
        agentId = await driver.start(resumeId);
      } catch (err) {
        // Register the failed-start teardown the same way stopChat does, so a
        // restart still waits out the dying process for the ~/.codex lock (a bare
        // dispose() here would drop that guarantee — the very race the map closes).
        void this.trackTeardown(sessionId, driver);
        throw err;
      }
      // Restore the last-picked model/mode/effort for this slot. Replayed
      // through the driver's own setConfig so it rides the identical
      // validation + pendingConfig path a live app pick uses — the driver
      // queues each until capability discovery, then applies it, so this is
      // race-free regardless of start/init ordering. Unknown-now ids are
      // silently dropped by the driver (no echo), same as a stale live pick.
      if (config) {
        // Model before effort: an effort pick validates against the CURRENT
        // model (resolveConfigPick in set-config.ts), so replaying a persisted
        // effort before its model would drop it against the default model and
        // lose the selection. Persisted key order is just whatever the user
        // touched first, so sequence it explicitly; any future key keeps its
        // stored order after the known ones.
        const known = ["model", "mode", "effort"];
        const orderedKeys = [
          ...known.filter((k) => k in config),
          ...Object.keys(config).filter((k) => !known.includes(k)),
        ];
        try {
          for (const key of orderedKeys) {
            const value = config[key];
            if (typeof value === "string") driver.setConfig(key, value);
          }
        } catch (err) {
          // All current drivers' setConfig only queues-or-applies and never
          // throws, but start() already succeeded here (the subprocess is
          // live), so a future driver that threw synchronously from setConfig
          // would leave it started-but-unregistered. Tear it down the same way
          // the start() catch above does, rather than leaking a live process.
          void this.trackTeardown(sessionId, driver);
          throw err;
        }
      }
      this.drivers.set(sessionId, driver);
      // Persist the agent-native id for the next resume. A resume that fell back
      // to a fresh session returns the NEW id, so the stale one is replaced.
      if (agentId) this.onAgentSession(sessionId, agentId);
      return driver;
    })();
    this.starting.set(sessionId, startPromise);
    try { await startPromise; }
    finally { this.starting.delete(sessionId); }

    // One-shot first turn for this launch. Delivered through the driver's own
    // prompt() so the transcript records it exactly like an app-sent
    // agent:prompt. After start, so the config replay above (model/effort)
    // applies to this first turn.
    await this.deliverInitialPrompt(sessionId, initialPrompt, resumeId);
  }

  // A prompt failure is surfaced as agent:error but must NOT tear down the
  // just-started driver — the session is live, only the first message was
  // lost, and the app can resend. Called from all three startChat exits so a
  // racing duplicate start still delivers exactly once per call that carried
  // a prompt.
  private async deliverInitialPrompt(
    sessionId: string, initialPrompt: string | undefined, resumeId?: string,
  ): Promise<void> {
    const initial = initialPrompt?.trim();
    if (!initial) return;
    // At-most-once per session lifetime: a replayed session:start must not
    // re-inject the prompt. Marked before the await (not after success) so a
    // duplicate can't slip in while the first prompt() is in flight; a failed
    // delivery is surfaced as agent:error and the app can resend via agent:prompt.
    if (this.initialPromptDelivered.has(sessionId)) return;
    const driver = this.drivers.get(sessionId);
    if (!driver) return;
    this.initialPromptDelivered.add(sessionId);
    // Before the delivery, not after: this is the message the session gets named
    // from, and a prompt() that rejects still tells us what the user asked for.
    //
    // A RESUME is exempt. Its first message continues a conversation that
    // already has a name ("yes, carry on with step 3" names nothing), and the
    // stop that preceded it released the slot's title and its attempt — so
    // without this the resumed session renames itself from the continuation.
    if (!resumeId) this.onUserPrompt?.(sessionId, initial);
    try {
      await driver.prompt(initial);
    } catch (err) {
      this.send(createMessage("agent:error", {
        sessionId,
        error: {
          category: "unknown",
          message: err instanceof Error ? err.message : String(err),
          retryable: true,
        },
      }));
    }
  }

  // Async: resolves once the driver's backend is fully torn down (codex awaits
  // process exit). The `stopping` entry is registered synchronously — before the
  // first await — so an immediately-following startChat sees and joins it.
  stopChat(sessionId: string): Promise<void> {
    // A start may still be in flight: the driver spawns but isn't in `drivers`
    // yet, so the plain lookup below would miss it and the driver would register
    // moments later with nobody to tear it down — an orphan codex holding the
    // ~/.codex lock. Join the in-flight start and tear down what it produced.
    const inflight = this.starting.get(sessionId);
    if (inflight) {
      return inflight.then(
        (driver) => {
          this.drivers.delete(sessionId);
          return this.trackTeardown(sessionId, driver);
        },
        // Start rejected: startChat's catch already tracked the failed-start
        // teardown in `stopping`; await it so the caller sees teardown complete.
        () => this.stopping.get(sessionId) ?? Promise.resolve(),
      );
    }
    const driver = this.drivers.get(sessionId);
    if (!driver) return Promise.resolve();
    this.drivers.delete(sessionId);
    return this.trackTeardown(sessionId, driver);
  }

  // Dispose a driver and record its teardown in `stopping` (keyed by session) so
  // a restart of that session waits it out. Registers synchronously (the set runs
  // before any await), and clears its own entry unless a newer teardown replaced it.
  private trackTeardown(sessionId: string, driver: StructuredDriver): Promise<void> {
    // Clear the session's capabilities: the empty frame tells live apps the
    // selectors are gone, then the replay-cache entry is dropped so a stopped
    // session neither replays stale selectors on app attach nor leaves a
    // tombstone in the cache forever.
    this.send(createMessage("agent:capabilities", { sessionId }));
    this.dropSessionReplay?.(sessionId);
    // End of this session's lifetime — allow a later relaunch to deliver its own
    // one-shot prompt (this teardown is the only driver-removal path).
    this.initialPromptDelivered.delete(sessionId);
    const teardown = Promise.resolve(driver.dispose()).catch(() => {});
    this.stopping.set(sessionId, teardown);
    return teardown.finally(() => {
      if (this.stopping.get(sessionId) === teardown) this.stopping.delete(sessionId);
      // Again, because dispose() itself emits session-scoped frames (a driver
      // clearing its background-task list), which would otherwise re-cache a
      // tombstone the earlier drop had just removed. A restart for this id waits
      // out `stopping`, so nothing live can be dropped here.
      this.dropSessionReplay?.(sessionId);
    });
  }

  /**
   * Dispatch one inbound agent:* control message.
   *
   * `injected` marks a prompt the Handler wrote on the user's behalf rather than
   * one the user sent. It is an option, not a wire field: the frame never leaves
   * this process (the supervisor's adapter builds it in memory), so putting it on
   * the protocol would let a remote client claim it.
   */
  async handleAgentMessage(msg: AbMessage, opts: { injected?: boolean } = {}): Promise<void> {
    try {
      switch (msg.type) {
        case "agent:prompt": {
          const driver = this.drivers.get(msg.sessionId);
          if (!driver) throw new Error("chat session not started");
          // A slash command's `text` is only its arguments, which name nothing —
          // and neither does a supervisor nudge, which is this component talking
          // to itself and would otherwise name the session "continue".
          if (!msg.commandId && !opts.injected && msg.text.trim()) {
            this.onUserPrompt?.(msg.sessionId, msg.text);
          }
          await driver.prompt(msg.text, msg.commandId);
          break;
        }
        case "agent:cancel": {
          let cancelled = false;
          try {
            cancelled = (await this.drivers.get(msg.sessionId)?.cancel(msg.turnId)) ?? false;
          } finally {
            // Nothing live to cancel, but the client thinks `turnId` is running —
            // its turn-end never landed (the relay drops rate-limited frames and
            // never resends), the driver is gone, or cancel() rejected on a dead
            // RPC. Answer authoritatively so the client closes the turn;
            // otherwise its transcript shows a turn that can never end, with a
            // stop button that does nothing. In `finally` because a rejecting
            // cancel is exactly when the client is most likely stuck — the throw
            // still propagates and surfaces as agent:error.
            if (!cancelled && msg.turnId) {
              this.send(createMessage("agent:turn-end", {
                sessionId: msg.sessionId,
                turnId: msg.turnId,
                stopReason: "cancelled",
              }));
            }
          }
          break;
        }
        case "agent:session-action":
          if (msg.action === "compact") await this.drivers.get(msg.sessionId)?.compact();
          if (msg.action === "revert") {
            await this.drivers.get(msg.sessionId)?.revert({
              turnId: msg.turnId,
              itemId: msg.itemId,
              messageId: msg.messageId,
              partId: msg.partId,
            });
          }
          break;
        case "agent:permission-resolve":
          this.drivers.get(msg.sessionId)?.resolvePermission(msg.permissionId, msg.optionId);
          break;
        case "agent:question-resolve":
          this.drivers.get(msg.sessionId)?.resolveQuestion(msg.questionId, msg.answer);
          break;
        case "agent:set-config":
          this.drivers.get(msg.sessionId)?.setConfig(msg.key, msg.value);
          if (typeof msg.value === "string") {
            this.onSetConfig?.(msg.sessionId, msg.key, msg.value);
          }
          break;
        case "agent:task-stop":
          await this.drivers.get(msg.sessionId)?.stopTask?.(msg.taskId);
          break;
        default:
          break;
      }
    } catch (err) {
      // Driver start()/prompt()/cancel() reject on spawn or RPC failure. Without
      // this the caller fire-and-forgets the promise, so the rejection is a silent
      // unhandled rejection and the turn hangs with no feedback — surface it as
      // agent:error instead.
      const sessionId = "sessionId" in msg ? (msg as { sessionId: string }).sessionId : "";
      this.send(createMessage("agent:error", {
        sessionId,
        error: {
          category: "unknown",
          message: err instanceof Error ? err.message : String(err),
          retryable: false,
        },
      }));
    }
  }

  /** Re-derive `sessionId`'s completed-turn transcript from its live driver, for
   *  a client attaching to an already-running chat session with no local
   *  history. Returns [] if the session isn't running or its driver doesn't
   *  implement transcript snapshots. */
  async getTranscriptSnapshot(sessionId: string): Promise<AbMessage[]> {
    const driver = this.drivers.get(sessionId);
    if (!driver?.getTranscriptSnapshot) return [];
    return driver.getTranscriptSnapshot();
  }

  /** `sessionId`'s slash commands, or undefined when none are available — the
   *  session isn't running, its driver reports no catalog, or discovery has
   *  produced nothing yet. All three are the same answer to the one caller that
   *  asks (the Handler): do not claim to know this session's commands. */
  commandCatalog(sessionId: string): CapCommand[] | undefined {
    return this.drivers.get(sessionId)?.commandCatalog?.();
  }

  disposeAll(): Promise<void> {
    // Join in-flight starts, not just `drivers`: a session mid-spawn isn't in
    // `drivers` yet, so a drivers-only sweep would leave its process running (a
    // codex would keep holding the ~/.codex lock) once the start completes and
    // registers moments later. Mirror stopChat — await each start, then dispose
    // what it produced. A rejected start already tracked its own teardown in
    // `stopping` (startChat's catch), captured below.
    const startTeardowns = [...this.starting.values()].map((inflight) =>
      inflight.then(
        (driver) => Promise.resolve(driver.dispose()).catch(() => {}),
        () => {},
      ),
    );
    const driverTeardowns = [...this.drivers.values()].map((d) =>
      Promise.resolve(d.dispose()).catch(() => {}));
    // Await pending teardowns too so we don't resolve before a dying process has
    // released its backend-global lock.
    const pendingStops = [...this.stopping.values()];
    this.drivers.clear();
    this.starting.clear();
    this.stopping.clear();
    this.initialPromptDelivered.clear();
    return Promise.all([
      ...startTeardowns,
      ...driverTeardowns,
      ...pendingStops,
    ]).then(() => {});
  }
}
