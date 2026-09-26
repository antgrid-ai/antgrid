import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { CONTROL_HANDLE } from "../support/stream";
import { TERMINAL_PROTOCOL_VERSION, TerminalScreenFrameSchema } from "../../bridge/src/terminal-frames/protocol";

// `URL.pathname` yields a leading-slash `/C:/…` form that is an invalid cwd on
// Windows (uv_spawn rejects it with ENOENT). `fileURLToPath` gives a native path.
const DART_CLIENT_DIR = fileURLToPath(new URL("../../packages/antgrid_eval_client", import.meta.url));

/**
 * Build the argv to run the Dart eval CLI. On Windows under `bun test`,
 * `Bun.spawn` can't exec the `dart.bat` shim (only works under `bun run`), so
 * prefer the real `dart.exe` bundled in Flutter's SDK cache (derived from the
 * resolved `dart.bat` path), then fall back to running the `.bat` through
 * cmd.exe. On POSIX (incl. CI) bare `dart` on PATH already works.
 */
function dartRunArgv(): string[] {
  const script = ["run", "bin/antgrid_eval_client.dart"];
  const which = Bun.which("dart");
  if (process.platform !== "win32") return ["dart", ...script];
  if (which && which.toLowerCase().endsWith(".bat")) {
    const exe = join(dirname(which), "cache", "dart-sdk", "bin", "dart.exe");
    if (existsSync(exe)) return [exe, ...script];
    const comspec = process.env.ComSpec ?? "C:\\Windows\\System32\\cmd.exe";
    return [comspec, "/c", which, ...script];
  }
  return [which ?? "dart", ...script];
}

/**
 * Cap on queued unmatched events. The Dart agent streams terminal output and
 * status messages continuously; without a bound the queue grows unboundedly
 * across long suites. When exceeded, the oldest events are dropped.
 */
const MAX_QUEUE_LENGTH = 1_000;

/** An event emitted by the Dart CLI over stdout (JSON line). */
type DartLifecycleEvent =
  | { event: "initialized"; deviceId: string; publicKey: string; x25519PublicKey: string }
  | { event: "control-connected" }
  | { event: "peer-connected"; endpointId: string; leaseRemainingMs: number }
  | { event: "peer-disconnected" }
  | { event: "control-disconnected" }
  | { event: "disconnected" };

type DartEvent = (DartLifecycleEvent | { event: string }) & Record<string, any>;

type Waiter = {
  match: (event: DartEvent) => boolean;
  resolve: (event: DartEvent) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

/**
 * DartAppClient wraps the Dart CLI (`packages/antgrid_eval_client`) as a
 * subprocess and communicates via JSON lines over stdin/stdout.
 *
 * The pattern mirrors RelayClient: an event queue + waiter array so callers
 * can either poll queued events or async-wait for future ones.
 */
export class DartAppClient {
  private proc: { pid: number; kill(): void };
  private stdin: import("bun").FileSink;
  private eventQueue: DartEvent[] = [];
  private waiters: Waiter[] = [];

  readonly deviceId: string;
  readonly x25519PublicKey: string;
  /** Raw 32-byte Ed25519 pubkey (base64) — the identity `startFakeLicenseApi({
   *  accountDevices })` must register for this client to be admitted without
   *  a pairing ceremony (see `setupDartTestEnv`). */
  readonly ed25519PublicKey: string;

  private constructor(
    proc: { pid: number; kill(): void },
    stdin: import("bun").FileSink,
    deviceId: string,
    x25519PublicKey: string,
    ed25519PublicKey: string,
  ) {
    this.proc = proc;
    this.stdin = stdin;
    this.deviceId = deviceId;
    this.x25519PublicKey = x25519PublicKey;
    this.ed25519PublicKey = ed25519PublicKey;
  }

  /**
   * Spawn the Dart CLI, send init, wait for "initialized" event, and return
   * a ready DartAppClient.
   */
  static async create(name?: string): Promise<DartAppClient> {
    const proc = Bun.spawn(dartRunArgv(), {
      cwd: DART_CLIENT_DIR,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "inherit",
    });

    const procStdin = proc.stdin as import("bun").FileSink;
    const procStdout = proc.stdout as ReadableStream<Uint8Array>;

    const earlyQueue: DartEvent[] = [];
    const earlyWaiters: Waiter[] = [];

    void DartAppClient._readLoop(procStdout, earlyQueue, earlyWaiters);

    procStdin.write(JSON.stringify({ action: "init", name: name ?? "eval-dart-app" }) + "\n");

    const initEvent = await new Promise<DartEvent>((resolve, reject) => {
      const idx = earlyQueue.findIndex((e) => e.event === "initialized");
      if (idx !== -1) {
        resolve(earlyQueue.splice(idx, 1)[0]);
        return;
      }

      const timer = setTimeout(() => {
        const i = earlyWaiters.findIndex((w) => w.timer === timer);
        if (i !== -1) earlyWaiters.splice(i, 1);
        reject(new Error("Timed out waiting for Dart client initialized event (30s)"));
      }, 30_000);

      earlyWaiters.push({
        match: (e) => e.event === "initialized" || e.event === "error",
        resolve,
        reject,
        timer,
      });
    });

    if (initEvent.event === "error") {
      proc.kill();
      throw new Error(`Dart client init failed: ${String(initEvent.message)}`);
    }
    const client = new DartAppClient(
      proc,
      procStdin,
      initEvent.deviceId as string,
      initEvent.x25519PublicKey as string,
      initEvent.publicKey as string,
    );

    // The early read loop holds a reference to earlyQueue and earlyWaiters.
    // We assign those same arrays to the client so the running loop continues
    // dispatching into client.eventQueue / client.waiters seamlessly —
    // no second reader is started on the stream.
    client.eventQueue = earlyQueue;
    client.waiters = earlyWaiters;

    return client;
  }

  private static async _readLoop(
    stdout: ReadableStream<Uint8Array>,
    queue: DartEvent[],
    waiters: Waiter[],
  ): Promise<void> {
    const reader = stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          try {
            const event = JSON.parse(trimmed) as DartEvent;
            DartAppClient._dispatch(event, queue, waiters);
          } catch {
            // Non-JSON line — skip
          }
        }
      }
    } catch {
      // Process ended or pipe closed — normal during disconnect
    } finally {
      reader.releaseLock();
    }
  }

  private static _dispatch(
    event: DartEvent,
    queue: DartEvent[],
    waiters: Waiter[],
  ): void {
    for (let i = 0; i < waiters.length; i++) {
      if (waiters[i].match(event)) {
        const waiter = waiters.splice(i, 1)[0];
        clearTimeout(waiter.timer);
        waiter.resolve(event);
        return;
      }
    }
    queue.push(event);
    // Drop oldest when over cap to avoid unbounded growth on long suites.
    if (queue.length > MAX_QUEUE_LENGTH) {
      queue.splice(0, queue.length - MAX_QUEUE_LENGTH);
    }
  }

  sendCommand(cmd: Record<string, any>): void {
    this.stdin.write(JSON.stringify(cmd) + "\n");
  }

  /**
   * Wait for a DartEvent matching the predicate.
   * Checks the queue first, then registers a waiter.
   */
  waitForEvent(
    match: (event: DartEvent) => boolean,
    timeoutMs = 10_000,
  ): Promise<DartEvent> {
    for (let i = 0; i < this.eventQueue.length; i++) {
      if (match(this.eventQueue[i])) {
        return Promise.resolve(this.eventQueue.splice(i, 1)[0]);
      }
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.waiters.findIndex((w) => w.timer === timer);
        if (idx !== -1) this.waiters.splice(idx, 1);
        reject(new Error(`Timed out waiting for Dart event (${timeoutMs}ms)`));
      }, timeoutMs);

      this.waiters.push({ match, resolve, reject, timer });
    });
  }

  waitForState(state: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => e.event === "state" && e.connectionState === state,
      timeoutMs,
    );
  }

  /** Await an AbMessage of `type` on the machine CONTROL PLANE (adverts, host
   *  verbs). Project verbs answer on a project stream — see
   *  {@link waitForStreamAbMessage}. */
  waitForAbMessage(type: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForStreamAbMessage(CONTROL_HANDLE, type, timeoutMs);
  }

  /** Await an AbMessage of `type` arriving on a specific project stream. */
  waitForStreamAbMessage(streamId: string, type: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => e.event === "antgrid-message" && e.streamId === streamId && e.data?.type === type,
      timeoutMs,
    );
  }

  /** Await a `terminal-attach-*` event for `requestId` matching `predicate`
   *  (checked against the full event, so a caller can narrow on `end`,
   *  `data?.type` or anything else the CLI attaches). */
  waitForTerminalAttach(
    requestId: string,
    predicate: (event: DartEvent) => boolean,
    timeoutMs = 10_000,
  ): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => typeof e.event === "string" && e.event.startsWith("terminal-attach-") &&
        e.requestId === requestId && predicate(e),
      timeoutMs,
    );
  }

  async connectControl(
    relayUrl: string,
    licenseToken: string,
    machineDeviceId: string,
  ): Promise<void> {
    const connected = this.waitForEvent((e) => e.event === "control-connected", 30_000);
    this.sendCommand({
      action: "control-connect",
      relayUrl,
      licenseToken,
      machineDeviceId,
    });
    await connected;
  }

  async connectPeer(options: {
    licenseApiUrl: string;
    accountId: string;
    enrollmentId: string;
    clientSecret: string;
    machineDeviceId: string;
    addresses: string[];
  }): Promise<{ endpointId: string; leaseRemainingMs: number }> {
    const connected = this.waitForEvent((e) => e.event === "peer-connected", 30_000);
    this.sendCommand({
      action: "peer-connect",
      machineDeviceId: options.machineDeviceId,
      licenseApiUrl: options.licenseApiUrl,
      accountId: options.accountId,
      enrollmentId: options.enrollmentId,
      clientSecret: options.clientSecret,
      nativeAddresses: options.addresses,
    });
    const event = await connected;
    return {
      endpointId: event.endpointId as string,
      leaseRemainingMs: event.leaseRemainingMs as number,
    };
  }
  /**
   * Drive the session to `established`: a plaintext `session:hello` on the
   * native payload, confirmed by the agent's `established`. QUIC/TLS between
   * the leased endpoints is the confidentiality layer, so there is no agent
   * key to pin. `machineDeviceId` is the agent's bare deviceUuid: with
   * pairing gone the relay hands out no peer id, so the phone addresses
   * coordinates it already holds — exactly as the app dials from its account
   * inventory.
   *
   * Runs ONE attempt: the Dart driver leaves give-up to the caller's
   * supervisor, which no eval has, so callers racing agent startup must retry.
   * `attemptTimeoutMs` caps that attempt (default 10s) — shorten it when
   * looping so the loop's worst case stays bounded.
   */
  async performHandshake(
    machineDeviceId: string,
    attemptTimeoutMs?: number,
  ): Promise<void> {
    const done = this.waitForEvent(
      (e) =>
        e.event === "handshake-complete" ||
        (e.event === "error" && String(e.message).startsWith("Handshake failed")),
      30_000,
    );
    this.sendCommand({ action: "handshake", machineDeviceId, attemptTimeoutMs });
    const result = await done;
    if (result.event !== "handshake-complete") throw new Error(String(result.message));
  }

  /**
   * Opens `projectId`'s own QUIC stream (Stage A wave A4): control-plane
   * `project:start`, then `MachineSession.openProject` — resolved at 0 RTT
   * when the `agent:projects` advert already showed the project running. No
   * new socket. The Dart CLI's `project-started` event still carries a
   * `streamId` field; its VALUE is now `projectId` (D-8), not a bridge-minted
   * id.
   */
  async openProjectStream(projectId: string, timeoutMs = 25_000): Promise<string> {
    const done = this.waitForEvent(
      (e) =>
        (e.event === "project-started" && e.projectId === projectId) ||
        (e.event === "error" && String(e.message).startsWith("project-start failed")),
      timeoutMs,
    );
    this.sendCommand({ action: "project-start", projectId });
    const result = await done;
    if (result.event !== "project-started") throw new Error(String(result.message));
    return result.streamId as string;
  }

  /**
   * Send an AbMessage on the machine CONTROL PLANE (`s` omitted), plaintext.
   * Name/action kept as `send(-encrypted)` — the wire command the Dart CLI
   * (`packages/antgrid_eval_client`) still expects — not a claim about sealing.
   */
  sendEncrypted(msg: AbMessage): void {
    this.sendCommand({ action: "send-encrypted", data: msg });
  }

  /** Send an AbMessage on `streamId`'s own project stream (A4: no `{s, m}`
   *  envelope on the wire — the Dart CLI command shape is unchanged, but
   *  `streamId` is the handle, which equals the projectId, not a bridge-minted
   *  id). */
  sendOnStream(streamId: string, msg: AbMessage): void {
    this.sendCommand({ action: "send-encrypted", streamId, data: msg });
  }

  /**
   * Pull-then-replay durable state for a stream, mirroring what a
   * `ProjectSession` does on bind. Issues the `state.snapshot` RPC; the client
   * fans the cached frames (agent:status/tree:full/git:status on a project
   * stream, `agent:projects` on the control plane) out as `antgrid-message`
   * events, then emits `snapshot-complete`. Without this the welcome-state
   * waiters race the agent's de-duped live burst and time out
   * non-deterministically.
   *
   * The production pull excludes `tree:full` (the app's own tree hydrator
   * carries it), so on a project stream this client asks for the heavy types
   * separately before it reports complete — see `_handleSnapshot` in
   * `packages/antgrid_eval_client`.
   */
  async pullStateSnapshot(streamId = CONTROL_HANDLE, timeoutMs = 15_000): Promise<void> {
    const done = this.waitForEvent(
      (e) => e.event === "snapshot-complete" && e.streamId === streamId,
      timeoutMs,
    ).catch(() => {});
    this.sendCommand({ action: "snapshot", streamId });
    await done;
  }

  /** Drop queued `antgrid-message` events of `type` so a later wait sees only
   *  frames produced AFTER this call (mirrors `RelayClient.drainQueued`). */
  drainQueued(type: string): void {
    this.eventQueue = this.eventQueue.filter(
      (e) => !(e.event === "antgrid-message" && e.data?.type === type),
    );
  }

  // ---- High-level helpers ----
  //
  // v3: every project verb rides the project's STREAM, so these all take the
  // streamId `openProjectStream` returned. The control plane carries only host
  // verbs and the catalog adverts (see `evals/support/stream.ts`).

  waitForAgentStatus(streamId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForStreamAbMessage(streamId, "agent:status", timeoutMs);
  }

  /** Opens a terminal attachment through the Dart eval CLI's `terminal-attach`
   *  action (§4.5 of the Stage A A2 contract): `openTerminalAttachment` on a
   *  `MultiStreamPeerLink` session rides its own native stream, and on the
   *  socket path falls back transparently — `isStream` on the `-opened` event
   *  tells the caller which. `version` always goes over the wire (defaulting
   *  to the terminal-frames protocol version), because the Zod schema behind
   *  `terminal:subscribe` requires it. */
  terminalAttach(
    streamId: string,
    opts: { terminalId: string; requestId: string; checkoutId?: string; version?: number },
  ): void {
    this.sendCommand({
      action: "terminal-attach",
      streamId,
      terminalId: opts.terminalId,
      requestId: opts.requestId,
      checkoutId: opts.checkoutId ?? "main",
      version: opts.version ?? TERMINAL_PROTOCOL_VERSION,
    });
  }

  /** `handle.send(data)` for an open terminal attachment. */
  terminalAttachSend(requestId: string, data: Record<string, any>): void {
    this.sendCommand({ action: "terminal-attach-send", requestId, data });
  }

  /** `handle.close()` for an open terminal attachment. Idempotent. */
  terminalAttachClose(requestId: string): void {
    this.sendCommand({ action: "terminal-attach-close", requestId });
  }

  sendTerminalInput(streamId: string, terminalId: string, data: string): void {
    this.sendOnStream(streamId, createMessage("terminal:input", { terminalId, data }));
  }

  sendTerminalResize(streamId: string, terminalId: string, cols: number, rows: number): void {
    // clientId is the driver discriminator (bridge arbitration). It's opaque to
    // the bridge — this client's stable deviceId stands in for the app's
    // per-install clientId.
    this.sendOnStream(
      streamId,
      createMessage("terminal:resize", { intent: "takeover", terminalId, cols, rows, clientId: this.deviceId }),
    );
  }

  sendTerminalStart(streamId: string, opts: {
    terminalId: string;
    name?: string;
    command: string;
    args?: string[];
  }): void {
    this.sendOnStream(streamId, createMessage("terminal:start", {
      terminalId: opts.terminalId,
      name: opts.name ?? opts.terminalId,
      command: opts.command,
      args: opts.args ?? [],
    }));
  }

  async requestFileContent(
    streamId: string,
    projectId: string,
    path: string,
    timeoutMs = 10_000,
  ): Promise<DartEvent> {
    const done = this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
        e.streamId === streamId &&
        e.data?.type === "file:content" &&
        e.data?.path === path,
      timeoutMs,
    );
    this.sendOnStream(streamId, createMessage("file:read", { projectId, path }));
    return done;
  }

  /** The open-time tree is retained for replay, never pushed — every client
   *  pulls its own (see MessageBus.retain and `state-snapshot.ts`) — so ask for
   *  it the way a `ProjectSession` does rather than await a push that no longer
   *  comes. The waiter is armed BEFORE the pull so the fanned frame cannot land
   *  in the gap between them. */
  async waitForFileTree(streamId: string, timeoutMs = 10_000): Promise<DartEvent> {
    const waiting = this.waitForStreamAbMessage(streamId, "tree:full", timeoutMs);
    await this.pullStateSnapshot(streamId, timeoutMs);
    return waiting;
  }

  waitForTreeUpdate(streamId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForStreamAbMessage(streamId, "tree:update", timeoutMs);
  }

  waitForTerminalOutput(streamId: string, terminalId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
        e.streamId === streamId &&
        e.data?.type === "terminal:output" &&
        e.data?.terminalId === terminalId,
      timeoutMs,
    );
  }

  waitForTerminalStarted(streamId: string, terminalId?: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
        e.streamId === streamId &&
        e.data?.type === "terminal:started" &&
        (terminalId === undefined || e.data?.terminalId === terminalId),
      timeoutMs,
    );
  }

  waitForTerminalExited(streamId: string, terminalId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
        e.streamId === streamId &&
        e.data?.type === "terminal:exited" &&
        e.data?.terminalId === terminalId,
      timeoutMs,
    );
  }

  /**
   * Wait for terminal output containing a marker string. Uses a single
   * predicate-based waiter so the full timeout applies to finding the marker
   * (not just the first output frame) — but a marker split across two PTY
   * chunks still needs the accumulating loop the TS scenarios use.
   */
  waitForTerminalOutputContaining(
    streamId: string,
    terminalId: string,
    marker: string,
    timeoutMs = 10_000,
  ): Promise<DartEvent> {
    return this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
        e.streamId === streamId &&
        e.data?.type === "terminal:output" &&
        e.data?.terminalId === terminalId &&
        typeof e.data?.data === "string" &&
        e.data.data.includes(marker),
      timeoutMs,
    );
  }

  /** Frame-capable Dart sessions opt each visible terminal in explicitly and
   * acknowledge every frame, including screens that precede the marker. */
  async waitForTerminalFrameContaining(
    streamId: string,
    terminalId: string,
    marker: string,
    timeoutMs = 10_000,
  ): Promise<DartEvent> {
    const deadline = Date.now() + timeoutMs;
    const remaining = () => Math.max(1, deadline - Date.now());
    const requestId = crypto.randomUUID();
    this.sendOnStream(streamId, createMessage("terminal:subscribe", {
      terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId,
    }));
    const subscribed = await this.waitForEvent((event) =>
      event.event === "antgrid-message" && event.streamId === streamId &&
      event.data?.type === "terminal:subscribed" && event.data.requestId === requestId,
      remaining());
    const { runId, attachmentId } = subscribed.data;
    try {
      while (Date.now() < deadline) {
        const frame = await this.waitForEvent((event) =>
          event.event === "antgrid-message" && event.streamId === streamId &&
          event.data?.type === "terminal:frame" && event.data.terminalId === terminalId &&
          event.data.runId === runId && event.data.attachmentId === attachmentId,
          remaining());
        const screen = TerminalScreenFrameSchema.parse(frame.data);
        this.sendOnStream(streamId, createMessage("terminal:ack", {
          terminalId, runId, attachmentId, sequence: frame.data.sequence,
        }));
        if (screen.ansi.includes(marker)) return frame;
      }
      throw new Error(`Timed out waiting for terminal frame marker (${timeoutMs}ms)`);
    } finally {
      this.sendOnStream(streamId, createMessage("terminal:unsubscribe", {
        terminalId, runId, attachmentId,
      }));
    }
  }

  async disconnectPeer(): Promise<void> {
    const disconnected = this.waitForEvent((e) => e.event === "peer-disconnected", 10_000);
    this.sendCommand({ action: "peer-disconnect" });
    await disconnected;
  }

  async disconnectControl(): Promise<void> {
    const disconnected = this.waitForEvent((e) => e.event === "control-disconnected", 10_000);
    this.sendCommand({ action: "control-disconnect" });
    await disconnected;
  }

  async disconnect(): Promise<void> {
    try {
      const disconnected = this.waitForEvent((e) => e.event === "disconnected", 10_000);
      this.sendCommand({ action: "dispose" });
      await disconnected;
    } catch {
      // Ignore write errors if process already died
    }

    for (const waiter of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("DartAppClient disconnected"));
    }
    this.waiters = [];
    this.eventQueue = [];

    try {
      this.proc.kill();
    } catch {
      // Already dead
    }
  }

  /**
   * Kills the whole process tree with no chance for the Dart VM to exit on
   * its own (which can send a graceful QUIC CONNECTION_CLOSE the bridge would
   * retire the peer on immediately, defeating a test of the idle timeout).
   *
   * `dart.exe run` spawns a child `dartvm.exe` holding the actual native
   * endpoint; killing only the Bun-spawned pid lets that child drain stdin
   * EOF and exit cleanly. Safe to call on an already-dead process.
   */
  async hardKill(): Promise<void> {
    const pid = this.proc.pid;
    if (process.platform === "win32") {
      try {
        const killer = Bun.spawn(["taskkill", "/PID", String(pid), "/T", "/F"], {
          stdout: "ignore",
          stderr: "ignore",
        });
        await killer.exited;
      } catch {
        // Already dead, or taskkill itself failed to spawn.
      }
      return;
    }

    // POSIX: no /T equivalent, so walk the tree via pgrep and SIGKILL every
    // descendant before the root, bottom-up.
    const descendants: number[] = [];
    let frontier = [pid];
    while (frontier.length > 0) {
      const next: number[] = [];
      for (const parent of frontier) {
        try {
          const out = Bun.spawnSync(["pgrep", "-P", String(parent)]);
          const text = new TextDecoder().decode(out.stdout).trim();
          if (text) {
            for (const line of text.split("\n")) {
              const child = Number(line);
              if (Number.isFinite(child)) next.push(child);
            }
          }
        } catch {
          // No children, or pgrep unavailable — nothing more under this pid.
        }
      }
      descendants.push(...next);
      frontier = next;
    }
    for (const child of [...descendants].reverse()) {
      try {
        process.kill(child, "SIGKILL");
      } catch {
        // Already dead.
      }
    }
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // Already dead.
    }
  }
}
