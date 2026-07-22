import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";

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

  private constructor(
    proc: { kill(): void },
    stdin: import("bun").FileSink,
    deviceId: string,
    x25519PublicKey: string,
  ) {
    this.proc = proc;
    this.stdin = stdin;
    this.deviceId = deviceId;
    this.x25519PublicKey = x25519PublicKey;
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

  waitForAbMessage(type: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => e.event === "antgrid-message" && e.data?.type === type,
      timeoutMs,
    );
  }

  async connect(relayUrl: string, licenseToken?: string): Promise<void> {
    // App/phone clients no longer send a licenseToken — they inherit auth
    // from a paired agent via signed pair-approval. Only forward a token if
    // a caller explicitly opts in (e.g. legacy / agent-shaped tests).
    const cmd: Record<string, unknown> = { action: "connect", relayUrl };
    if (licenseToken !== undefined) cmd.licenseToken = licenseToken;
    this.sendCommand(cmd);
    await this.waitForState("authenticated");
  }

  async pairWith(
    agentDeviceId: string,
    opts: { pairCode?: string; timeoutMs?: number } = {},
  ): Promise<void> {
    this.sendCommand({
      action: "pair",
      targetDeviceId: agentDeviceId,
      ...(opts.pairCode ? { pairCode: opts.pairCode } : {}),
    });
    await this.waitForState("paired", opts.timeoutMs ?? 10_000);
  }

  /**
   * Drive the pull-model E2E handshake. The eval-client (phone) signs its
   * client-hello and verifies the agent's signed agent-hello against the agent's
   * pinned Ed25519 pubkey before deriving — mirroring the production app. The
   * caller supplies `agentEd25519Pub` (raw 32 bytes, base64) from the agent's
   * bootstrap keypair; without it the Dart client refuses to derive.
   */
  async performHandshake(agentEd25519Pub: string): Promise<void> {
    this.sendCommand({ action: "handshake", agentEd25519Pub });
    await this.waitForEvent((e) => e.event === "handshake-complete");
  }

  sendEncrypted(msg: AbMessage): void {
    this.sendCommand({ action: "send-encrypted", data: msg });
  }

  /**
   * Pull-then-replay welcome state, mirroring the production `RelayTransport.connect()`.
   * Issues the `state.snapshot` RPC; the client fans the cached frames
   * (agent:status/tree:full/git:status) out as `antgrid-message` events, then
   * emits `snapshot-complete`. Without this the welcome-state waiters race the
   * agent's de-duped live burst and time out non-deterministically.
   */
  async pullStateSnapshot(timeoutMs = 10_000): Promise<void> {
    const done = this.waitForEvent((e) => e.event === "snapshot-complete", timeoutMs).catch(
      () => {},
    );
    this.sendCommand({ action: "snapshot" });
    await done;
  }

  // ---- High-level helpers ----

  waitForAgentStatus(timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForAbMessage("agent:status", timeoutMs);
  }

  sendTerminalInput(terminalId: string, data: string): void {
    this.sendEncrypted(createMessage("terminal:input", { terminalId, data }));
  }

  sendTerminalResize(terminalId: string, cols: number, rows: number): void {
    // clientId is the driver discriminator (bridge arbitration). It's opaque to
    // the bridge — this client's stable deviceId stands in for the app's
    // per-install clientId.
    this.sendEncrypted(
      createMessage("terminal:resize", { terminalId, cols, rows, clientId: this.deviceId }),
    );
  }

  sendTerminalStart(opts: {
    terminalId: string;
    name?: string;
    command: string;
    args?: string[];
  }): void {
    this.sendEncrypted(createMessage("terminal:start", {
      terminalId: opts.terminalId,
      name: opts.name ?? opts.terminalId,
      command: opts.command,
      args: opts.args ?? [],
    }));
  }

  async requestFileContent(projectId: string, path: string, timeoutMs = 10_000): Promise<DartEvent> {
    this.sendEncrypted(createMessage("file:read", { projectId, path }));
    return this.waitForEvent(
      (e) => e.event === "antgrid-message" && e.data?.type === "file:content" && e.data?.path === path,
      timeoutMs,
    );
  }

  waitForFileTree(timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForAbMessage("tree:full", timeoutMs);
  }

  waitForTreeUpdate(timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForAbMessage("tree:update", timeoutMs);
  }

  waitForTerminalOutput(terminalId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => e.event === "antgrid-message" && e.data?.type === "terminal:output" && e.data?.terminalId === terminalId,
      timeoutMs,
    );
  }

  waitForTerminalStarted(terminalId?: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
        e.data?.type === "terminal:started" &&
        (terminalId === undefined || e.data?.terminalId === terminalId),
      timeoutMs,
    );
  }

  waitForTerminalExited(terminalId: string, timeoutMs = 10_000): Promise<DartEvent> {
    return this.waitForEvent(
      (e) => e.event === "antgrid-message" && e.data?.type === "terminal:exited" && e.data?.terminalId === terminalId,
      timeoutMs,
    );
  }

  /**
   * Wait for terminal output containing a marker string. Uses a single
   * predicate-based waiter so the full timeout applies to finding the marker
   * (not just the first output frame).
   */
  waitForTerminalOutputContaining(
    terminalId: string,
    marker: string,
    timeoutMs = 10_000,
  ): Promise<DartEvent> {
    return this.waitForEvent(
      (e) =>
        e.event === "antgrid-message" &&
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
