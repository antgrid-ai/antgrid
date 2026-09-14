import { createMessage, type AbMessage } from "../protocol";
import { isChatCapableTool } from "../agent-runtime";
import type { AgentRuntime } from "antgrid-agents/runtime";
import { createAgentRunScope, AgentOutputEventSchema, type OwnedAgentRunScope, type AgentOutputEvent } from "antgrid-agents/contracts";
import type { CapCommand } from "antgrid-agents/structured/chat-session";
import type { ApprovalPolicy } from "antgrid-agents/contracts";

import type { StructuredDriver, DriverRunContext } from "antgrid-agents/contracts";
export type { StructuredDriver, DriverRunContext } from "antgrid-agents/contracts";
export type ChatStartOutcome = "ready" | "cancelled";

export type DriverFactory = (
  sessionId: string,
  tool: string,
  sendMessage: (m: AbMessage) => void,
  resumeId?: string,
  approvalPolicy?: ApprovalPolicy,
  run?: DriverRunContext,
) => StructuredDriver;

export interface StructuredAgentManagerOpts {
  agentRuntime?: AgentRuntime;
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
  private readonly supportsChat: (tool: string) => boolean;
  private drivers = new Map<string, StructuredDriver>();
  // Race-guard: concurrent startChat calls for one session must not spawn two
  // drivers. Holds the in-flight start so late callers join it rather than
  // racing a second spawn.
  private starting = new Map<string, Promise<void>>();
  private runs = new Map<string, { abort: AbortController; driver?: StructuredDriver; acceptsEvents: boolean; scope?: OwnedAgentRunScope<AgentOutputEvent> }>();
  private teardowns = new WeakMap<StructuredDriver, Promise<void>>();
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
    this.supportsChat = opts.agentRuntime?.isChatCapable ?? isChatCapableTool;
    this.factory = opts.driverFactory;
    this.send = opts.sendMessage;
    this.onAgentSession = opts.onAgentSession;
    this.dropSessionReplay = opts.dropSessionReplay;
    this.onSetConfig = opts.onSetConfig;
    this.onUserPrompt = opts.onUserPrompt;
  }

  async startChat(opts: { sessionId: string; tool: string; runId?: string; resumeId?: string; config?: Record<string, string>; initialPrompt?: string; approvalPolicy?: ApprovalPolicy }): Promise<ChatStartOutcome> {
    const { sessionId, tool, resumeId, config, initialPrompt, approvalPolicy = "default" } = opts;
    if (!this.supportsChat(tool)) {
      throw new Error(`tool "${tool}" does not support chat mode`);
    }
    if (this.drivers.has(sessionId)) {
      // already running — idempotent, but a racing duplicate start still
      // carries the caller's own initialPrompt and must deliver it once.
      await this.deliverInitialPrompt(sessionId, initialPrompt, resumeId);
      return this.drivers.has(sessionId) ? "ready" : "cancelled";
    }
    const inflight = this.starting.get(sessionId);
    if (inflight) {
      if (this.runs.get(sessionId)?.abort.signal.aborted) {
        await inflight.catch(() => {});
        if (this.starting.get(sessionId) === inflight) this.starting.delete(sessionId);
        await this.stopping.get(sessionId);
        return this.startChat(opts);
      }
      await inflight;
      await this.deliverInitialPrompt(sessionId, initialPrompt, resumeId);
      return this.drivers.has(sessionId) ? "ready" : "cancelled";
    }

    const run = { abort: new AbortController(), driver: undefined as StructuredDriver | undefined, acceptsEvents: true, scope: undefined as OwnedAgentRunScope<AgentOutputEvent> | undefined };
    this.runs.set(sessionId, run);
    run.scope = createAgentRunScope({
      runId: opts.runId ?? crypto.randomUUID(),
      isCurrent: () => this.runs.get(sessionId) === run && run.acceptsEvents,
      emit: (event) => this.send(AgentOutputEventSchema.parse({ ...event, sessionId })),
    });
    run.abort.signal.addEventListener("abort", () => run.scope!.cancel(run.abort.signal.reason), { once: true });
    const startPromise = (async () => {
      // A just-issued session:stop may still be tearing down the prior driver.
      // Wait it out so the new codex process spawns only after the old one has
      // exited and released the ~/.codex sqlite lock (else initialize wedges).
      const pendingStop = this.stopping.get(sessionId);
      if (pendingStop) await pendingStop;
      if (run.abort.signal.aborted) return;
      const context: DriverRunContext = {
        scope: run.scope!,
        signal: run.abort.signal,
        isCurrent: () => this.runs.get(sessionId) === run && !run.abort.signal.aborted && run.acceptsEvents,
        onAgentSession: (agentSessionId) => {
          if (context.isCurrent()) this.onAgentSession(sessionId, agentSessionId);
        },
      };
      let driver: StructuredDriver;
      try {
        driver = this.factory(sessionId, tool, (message) => {
          if (this.runs.get(sessionId) === run && run.acceptsEvents) this.send(message);
        }, resumeId, approvalPolicy, context);
      } catch (error) {
        run.acceptsEvents = false;
        run.abort.abort(error);
        const cleanup = run.scope!.dispose().then(() => {
          if (this.stopping.get(sessionId) === cleanup) this.stopping.delete(sessionId);
          if (this.runs.get(sessionId) === run) this.runs.delete(sessionId);
        });
        this.stopping.set(sessionId, cleanup);
        void cleanup.catch(() => {});
        throw error;
      }
      run.driver = driver;
      run.scope!.registerCleanup(() => driver.dispose());
      let abortStart: (() => void) | undefined;
      try {
        await Promise.race([
          driver.start(resumeId, run.abort.signal),
          new Promise<never>((_, reject) => {
            abortStart = () => reject(run.abort.signal.reason);
            run.abort.signal.addEventListener("abort", abortStart, { once: true });
            if (run.abort.signal.aborted) abortStart();
          }),
        ]);
      } catch (err) {
        // Register the failed-start teardown the same way stopChat does, so a
        // restart still waits out the dying process for the ~/.codex lock (a bare
        // dispose() here would drop that guarantee — the very race the map closes).
        void this.trackTeardown(sessionId, driver).catch(() => {});
        if (run.abort.signal.aborted) return;
        throw err;
      } finally {
        if (abortStart) run.abort.signal.removeEventListener("abort", abortStart);
      }
      if (run.abort.signal.aborted) return;
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
          void this.trackTeardown(sessionId, driver).catch(() => {});
          throw err;
        }
      }
      this.drivers.set(sessionId, driver);
    })();
    this.starting.set(sessionId, startPromise);
    try { await startPromise; }
    finally {
      if (this.starting.get(sessionId) === startPromise) this.starting.delete(sessionId);
    }

    // One-shot first turn for this launch. Delivered through the driver's own
    // prompt() so the transcript records it exactly like an app-sent
    // agent:prompt. After start, so the config replay above (model/effort)
    // applies to this first turn.
    if (!run.abort.signal.aborted) await this.deliverInitialPrompt(sessionId, initialPrompt, resumeId);
    return run.abort.signal.aborted ? "cancelled" : "ready";
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
      if (this.drivers.get(sessionId) !== driver) return;
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
    const run = this.runs.get(sessionId);
    if (run) run.acceptsEvents = false;
    run?.abort.abort(new Error("Agent startup cancelled"));
    const driver = run?.driver ?? this.drivers.get(sessionId);
    if (!driver) return this.stopping.get(sessionId) ?? Promise.resolve();
    this.drivers.delete(sessionId);
    return this.trackTeardown(sessionId, driver);
  }

  // Dispose a driver and record its teardown in `stopping` (keyed by session) so
  // a restart of that session waits it out. Registers synchronously (the set runs
  // before any await), and clears its own entry unless a newer teardown replaced it.
  private trackTeardown(sessionId: string, driver: StructuredDriver): Promise<void> {
    const existing = this.teardowns.get(driver);
    if (existing) return existing;
    // Clear the session's capabilities: the empty frame tells live apps the
    // selectors are gone, then the replay-cache entry is dropped so a stopped
    // session neither replays stale selectors on app attach nor leaves a
    // tombstone in the cache forever.
    // End of this session's lifetime — allow a later relaunch to deliver its own
    // one-shot prompt (this teardown is the only driver-removal path).
    this.initialPromptDelivered.delete(sessionId);
    const run = this.runs.get(sessionId);
    if (run?.driver === driver) run.acceptsEvents = false;
    const notify = (callback: () => void) => {
      try { callback(); } catch { /* Delivery failure cannot retain provider resources. */ }
    };
    let resolveDisposal!: () => void;
    let rejectDisposal!: (error: unknown) => void;
    const disposal = new Promise<void>((resolve, reject) => {
      resolveDisposal = resolve;
      rejectDisposal = reject;
    });
    const teardown = disposal.finally(() => {
      // Again, because dispose() itself emits session-scoped frames (a driver
      // clearing its background-task list), which would otherwise re-cache a
      // tombstone the earlier drop had just removed. A restart for this id waits
      // out `stopping`, so nothing live can be dropped here.
      notify(() => this.dropSessionReplay?.(sessionId));
    }).then(() => {
      if (this.stopping.get(sessionId) === teardown) this.stopping.delete(sessionId);
      if (this.runs.get(sessionId) === run) this.runs.delete(sessionId);
    });
    this.teardowns.set(driver, teardown);
    this.stopping.set(sessionId, teardown);
    notify(() => this.send(createMessage("agent:capabilities", { sessionId })));
    notify(() => this.dropSessionReplay?.(sessionId));
    try { Promise.resolve(run?.scope ? run.scope.dispose() : driver.dispose()).then(resolveDisposal, rejectDisposal); }
    catch (error) { rejectDisposal(error); }
    // Failure stays in `stopping`: a replacement must not infer resource release.
    void teardown.catch(() => {});
    return teardown;
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
    const sessionId = "sessionId" in msg ? String(msg.sessionId) : "";
    const run = this.runs.get(sessionId);
    const isCurrent = () => this.runs.get(sessionId) === run && (!run || run.acceptsEvents);
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
            if (!cancelled && msg.turnId && isCurrent()) {
              this.send(createMessage("agent:turn-end", {
                sessionId: msg.sessionId,
                turnId: msg.turnId,
                stopReason: "cancelled",
              }));
            }
          }
          break;
        }
        case "agent:session-action": {
          const driver = this.drivers.get(msg.sessionId);
          if (!driver) throw new Error("chat session not started");
          if (msg.action === "compact") {
            if (!driver.compact) throw new Error("This agent does not support compact");
            await driver.compact();
          }
          if (msg.action === "revert") {
            if (!driver.revert) throw new Error("This agent does not support revert");
            await driver.revert({
              turnId: msg.turnId,
              itemId: msg.itemId,
              messageId: msg.messageId,
              partId: msg.partId,
            });
          }
          break;
        }
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
      if (!isCurrent()) return;
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
    const frames = await driver.getTranscriptSnapshot();
    return this.drivers.get(sessionId) === driver ? frames : [];
  }

  /** `sessionId`'s slash commands, or undefined when none are available — the
   *  session isn't running, its driver reports no catalog, or discovery has
   *  produced nothing yet. All three are the same answer to the one caller that
   *  asks (the Handler): do not claim to know this session's commands. */
  commandCatalog(sessionId: string): CapCommand[] | undefined {
    return this.drivers.get(sessionId)?.commandCatalog?.();
  }

  disposeAll(): Promise<void> {
    const ids = new Set([...this.runs.keys(), ...this.drivers.keys(), ...this.stopping.keys()]);
    return Promise.allSettled([...ids].map((id) => this.stopChat(id))).then((results) => {
      const failures = results.filter((r): r is PromiseRejectedResult => r.status === "rejected");
      if (failures.length) throw new AggregateError(failures.map((r) => r.reason), "Agent teardown failed");
    });
  }
}
