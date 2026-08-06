// Minimal JSON-RPC 2.0 endpoint over NDJSON (newline-delimited) streams.
// Codex `app-server` uses NDJSON, not LSP Content-Length framing.
// Supports: outbound request/notify, inbound notification handlers, and
// inbound server->client requests (codex approvals) answered by id.

type Json = unknown;

export interface JsonRpcTransport {
  /** A stream of already-split, newline-free JSON text lines from the peer. */
  readLines: ReadableStream<string>;
  /** Write one JSON line to the peer (the endpoint appends no newline here —
   *  see spawn.ts which adds "\n" when piping to the process). */
  writeLine: (line: string) => void;
}

type Pending = { resolve: (v: Json) => void; reject: (e: Error) => void };
type NotificationHandler = (params: Json) => void;
type RequestHandler = (params: Json, rpcId: number | string) => Promise<Json> | Json;

export class JsonRpcEndpoint {
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private notificationHandlers = new Map<string, NotificationHandler>();
  private requestHandlers = new Map<string, RequestHandler>();
  private write: (line: string) => void;
  private disposed = false;
  private reader?: ReadableStreamDefaultReader<string>;
  private closeHandler?: () => void;

  constructor(transport: JsonRpcTransport) {
    this.write = transport.writeLine;
    void this.readLoop(transport.readLines);
  }

  // A hung (but not crashed) peer would otherwise leave the awaiter pending
  // forever — the stream-close path only rejects on codex *exiting*. The default
  // is generous so slow model spin-up (initialize/thread-start) never false-trips.
  request(method: string, params?: Json, timeoutMs = 120_000): Promise<Json> {
    const id = this.nextId++;
    const promise = new Promise<Json>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) {
          reject(new Error(`json-rpc request timed out after ${timeoutMs}ms: ${method}`));
        }
      }, timeoutMs);
      // Deliberately NOT unref'd: on Bun (Windows) an unref'd timer that later
      // *fires* wedges the event loop and never lets the process exit. The timer
      // is always cleared on resolve/reject/dispose anyway, so it can't outlive
      // its request.
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
    });
    this.write(JSON.stringify({ jsonrpc: "2.0", id, method, params: params ?? {} }));
    return promise;
  }

  notify(method: string, params?: Json): void {
    this.write(JSON.stringify({ jsonrpc: "2.0", method, params: params ?? {} }));
  }

  onNotification(method: string, handler: NotificationHandler): void {
    this.notificationHandlers.set(method, handler);
  }

  onRequest(method: string, handler: RequestHandler): void {
    this.requestHandlers.set(method, handler);
  }

  // Fires once when the peer's stdout closes unexpectedly (codex exited/crashed),
  // NOT on dispose() — a caller that intentionally tears the endpoint down already
  // knows. Lets a driver close out an in-flight turn instead of leaving it hung.
  onClose(handler: () => void): void {
    this.closeHandler = handler;
  }

  dispose(): void {
    this.disposed = true;
    // The read loop is parked in `await reader.read()`, so flipping `disposed`
    // alone never unblocks it — cancel the reader so the loop actually exits and
    // stops holding the peer stream open.
    this.reader?.cancel().catch(() => {});
    this.rejectAllPending("endpoint disposed");
  }

  private rejectAllPending(message: string): void {
    for (const p of this.pending.values()) p.reject(new Error(message));
    this.pending.clear();
  }

  private async readLoop(lines: ReadableStream<string>): Promise<void> {
    const reader = lines.getReader();
    this.reader = reader;
    try {
      while (!this.disposed) {
        const { value, done } = await reader.read();
        if (done) break;
        if (!value) continue;
        const trimmed = value.trim();
        if (!trimmed) continue;
        let msg: Record<string, unknown>;
        try { msg = JSON.parse(trimmed) as Record<string, unknown>; } catch { continue; }
        this.handle(msg);
      }
    } finally {
      reader.releaseLock();
      // The peer's stdout closed (codex exited/crashed). In-flight requests will
      // never get a response — reject them so awaiters (e.g. thread/start) fail
      // fast instead of hanging forever. dispose() already drained them itself.
      if (!this.disposed) {
        this.rejectAllPending("codex stream closed");
        this.closeHandler?.();
      }
    }
  }

  private handle(msg: Record<string, unknown>): void {
    // Response to one of our requests.
    if (msg["id"] !== undefined && (msg["result"] !== undefined || msg["error"] !== undefined) && !msg["method"]) {
      const id = msg["id"] as number;
      const pending = this.pending.get(id);
      if (!pending) return;
      this.pending.delete(id);
      const err = msg["error"] as { message?: string } | undefined;
      if (err) {
        pending.reject(new Error(err.message ?? "json-rpc error"));
      } else {
        pending.resolve(msg["result"]);
      }
      return;
    }
    // Inbound server->client request (has id AND method).
    if (msg["id"] !== undefined && msg["method"]) {
      const id = msg["id"] as number | string;
      const method = msg["method"] as string;
      const handler = this.requestHandlers.get(method);
      if (!handler) {
        this.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: `no handler: ${method}` } }));
        return;
      }
      void Promise.resolve(handler(msg["params"], id))
        .then((result) => this.write(JSON.stringify({ jsonrpc: "2.0", id, result })))
        .catch((e: unknown) => {
          const message = e instanceof Error ? e.message : String(e);
          this.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } }));
        });
      return;
    }
    // Inbound notification (method, no id).
    if (msg["method"]) {
      const method = msg["method"] as string;
      const handler = this.notificationHandlers.get(method);
      // A throwing handler must not escape into readLoop — that would kill the
      // whole RPC connection over one bad notification. Contain and log it.
      try {
        handler?.(msg["params"]);
      } catch (err) {
        console.error(`notification handler for ${method} threw:`, err);
      }
    }
  }
}
