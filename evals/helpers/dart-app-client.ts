import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import { CONTROL_STREAM_ID } from "antgrid-wire";

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
type DartEvent = Record<string, any>;

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
  private proc: { kill(): void };
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
    proc: { kill(): void },
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
      stderr: "ignore",
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
        reject(new Error("Timed out waiting for Dart client initialized event (15s)"));
      }, 15_000);

      earlyWaiters.push({
        match: (e) => e.event === "initialized",
        resolve,
        reject,
        timer,
      });
    });

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
    return this.waitForStreamAbMessage(CONTROL_STREAM_ID, type, timeoutMs);
  }

  /** Await an AbMessage of `type` arriving on a specific project stream. */
  waitForStreamAbMessage(streamId: string, type: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => e.event === "antgrid-message" && e.streamId === streamId && e.data?.type === type,
      timeoutMs,
    );
  }

  async connect(relayUrl: string, licenseToken: string): Promise<void> {
    // Mandatory in v3: the app hello carries the account's own license token
    // (design §4.2). Omitting it makes the Dart CLI reject the command outright
    // rather than dial token-free, so this stays required here.
    this.sendCommand({ action: "connect", relayUrl, licenseToken });
    await this.waitForState("authenticated");
  }

  /**
   * Drive the pull-model E2E handshake to `established`. The eval-client
   * (phone) signs its client-hello and verifies the agent's signed agent-hello
   * against the agent's pinned Ed25519 pubkey before deriving — mirroring the
   * production app. `agentEd25519Pub` (raw 32 bytes, base64) comes from the
   * agent's bootstrap keypair; without it the Dart client refuses to derive.
   * `machineDeviceId` is the agent's bare deviceUuid: with pairing gone the
   * relay hands out no peer id, so the phone addresses coordinates it already
   * holds — exactly as the app dials from its account inventory.
   *
   * Runs ONE attempt: the Dart driver leaves give-up to the caller's
   * supervisor, which no eval has, so callers racing agent startup must retry.
   * `attemptTimeoutMs` caps that attempt (default 10s) — shorten it when
   * looping so the loop's worst case stays bounded.
   */
  async performHandshake(
    agentEd25519Pub: string,
    machineDeviceId: string,
    attemptTimeoutMs?: number,
  ): Promise<void> {
    const done = this.waitForEvent(
      (e) =>
        e.event === "handshake-complete" ||
        (e.event === "error" && String(e.message).startsWith("Handshake failed")),
      30_000,
    );
    this.sendCommand({ action: "handshake", agentEd25519Pub, machineDeviceId, attemptTimeoutMs });
    const result = await done;
    if (result.event !== "handshake-complete") throw new Error(String(result.message));
  }

  /**
   * Drill into a project: control-plane `project:start`, then the agent's
   * `stream-ready { projectId, streamId }` (design §7.4) — resolved at 0 RTT
   * when the `agent:projects` advert already carried the stream. No new socket.
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

  /** Send an AbMessage on the machine CONTROL PLANE (`s` omitted), sealed. */
  sendEncrypted(msg: AbMessage): void {
    this.sendCommand({ action: "send-encrypted", data: msg });
  }

  /** Send an AbMessage tagged with a project stream (`{ s: streamId, m }`). */
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
   */
  async pullStateSnapshot(streamId = CONTROL_STREAM_ID, timeoutMs = 15_000): Promise<void> {
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

  sendTerminalInput(streamId: string, terminalId: string, data: string): void {
    this.sendOnStream(streamId, createMessage("terminal:input", { terminalId, data }));
  }

  sendTerminalResize(streamId: string, terminalId: string, cols: number, rows: number): void {
    // clientId is the driver discriminator (bridge arbitration). It's opaque to
    // the bridge — this client's stable deviceId stands in for the app's
    // per-install clientId.
    this.sendOnStream(
      streamId,
      createMessage("terminal:resize", { terminalId, cols, rows, clientId: this.deviceId }),
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

  waitForFileTree(streamId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForStreamAbMessage(streamId, "tree:full", timeoutMs);
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

  async disconnect(): Promise<void> {
    try {
      this.sendCommand({ action: "disconnect" });
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
}
