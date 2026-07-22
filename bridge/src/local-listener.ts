import { timingSafeEqual } from "node:crypto";
import type { ServerWebSocket } from "bun";
import { MessageBus, type Channel, type TransportSubscriber } from "./message-bus";
import { parseMessageFast, type AbMessage } from "./protocol";
import { logger } from "./logger";

interface ConnState {
  state: "awaiting-hello" | "connected" | "rejected";
  appPid?: number;
}

export interface LocalListenerOptions {
  bus: MessageBus;
  token: string;
  /** Optional allow-list for Origin header. Default: only empty/missing Origin allowed. */
  allowedOrigins?: string[];
  /**
   * Invoked once a client completes the hello handshake and is promoted to
   * owner. Used by the agent to replay cached state to late joiners.
   */
  onOwnerConnected?: () => void;
}

const CLOSE_UNAUTHORIZED = 4401;
const CLOSE_CONFLICT = 4409;

export class LocalListener implements TransportSubscriber {
  private server: ReturnType<typeof Bun.serve> | null = null;
  private connections = new Set<ServerWebSocket<ConnState>>();
  private ownerSocket: ServerWebSocket<ConnState> | null = null;
  private busUnsubscribe: (() => void) | null = null;

  constructor(private opts: LocalListenerOptions) {}

  /** True while a desktop owner is connected over the loopback socket. The
   *  relay slot's `onUnpaired` (phone left) consults this so it never tears
   *  down core services that a live loopback owner is still using. */
  get hasOwner(): boolean {
    return this.ownerSocket !== null;
  }

  get port(): number {
    if (!this.server) throw new Error("not started");
    const p = this.server.port;
    if (p === undefined) throw new Error("server has no port");
    return p;
  }

  async start(): Promise<void> {
    const tokenBuf = Buffer.from(this.opts.token);

    this.server = Bun.serve<ConnState, never>({
      hostname: "127.0.0.1",
      port: 0,
      fetch: (req, server) => {
        const origin = req.headers.get("origin");
        if (origin && !(this.opts.allowedOrigins ?? []).includes(origin)) {
          return new Response("forbidden origin", { status: 403 });
        }
        const ok = server.upgrade(req, { data: { state: "awaiting-hello" } });
        return ok ? undefined : new Response("upgrade required", { status: 400 });
      },
      websocket: {
        maxPayloadLength: 1048576,
        open: (ws) => {
          this.connections.add(ws);
        },
        message: (ws, raw) => {
          const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
          if (ws.data.state === "awaiting-hello") {
            this.handleHello(ws, text, tokenBuf);
            return;
          }
          if (ws.data.state === "connected") {
            this.handleFrame(ws, text);
          }
        },
        close: (ws) => {
          this.connections.delete(ws);
          if (this.ownerSocket === ws) {
            logger.info("local listener: owner disconnected (app pid=%s)", ws.data.appPid ?? "?");
            this.ownerSocket = null;
            this.busUnsubscribe?.();
            this.busUnsubscribe = null;
          }
        },
      },
    });

    logger.info(`local listener bound on 127.0.0.1:${this.server.port}`);
  }

  async stop(): Promise<void> {
    this.busUnsubscribe?.(); this.busUnsubscribe = null;
    for (const ws of this.connections) ws.close();
    this.server?.stop(true);
    this.server = null;
    this.connections.clear();
    this.ownerSocket = null;
  }

  /** TransportSubscriber — bus -> wire (broadcast to owner only; spec invariant: ≤1 owner). */
  deliver(msg: AbMessage, channel: Channel): void {
    if (!this.ownerSocket) return;
    this.ownerSocket.send(JSON.stringify({ channel, ...msg }));
  }

  private handleHello(ws: ServerWebSocket<ConnState>, text: string, tokenBuf: Buffer): void {
    let envelope: any;
    try { envelope = JSON.parse(text); } catch {
      logger.warn("local listener: rejecting hello (bad envelope), closing 4401");
      ws.close(CLOSE_UNAUTHORIZED, "bad envelope"); return;
    }
    if (envelope?.type !== "hello" || typeof envelope.token !== "string") {
      logger.warn("local listener: rejecting hello (malformed), closing 4401");
      ws.close(CLOSE_UNAUTHORIZED, "bad hello"); return;
    }
    const presented = Buffer.from(envelope.token);
    const ok = presented.length === tokenBuf.length && timingSafeEqual(presented, tokenBuf);
    if (!ok) {
      logger.warn("local listener: rejecting hello (bad token), closing 4401");
      ws.close(CLOSE_UNAUTHORIZED, "bad token"); return;
    }

    const newPid = typeof envelope.appPid === "number" ? envelope.appPid : undefined;

    // A second hello carrying the VALID token is the same trusted app
    // reconnecting (a provider rebuild, retry, or eviction+reopen on the app
    // side), NOT a competing owner — loopback + this per-core token is the sole
    // trust boundary and there is only ever one app. The previous owner's TCP
    // close lags its replacement's hello, so rejecting here (4409) surfaced as
    // "socket closed before ready" on a perfectly legitimate reconnect. Take
    // over instead: drop the stale owner's bus subscription and force-close it,
    // then promote this socket below. The stale socket's own `close` handler is
    // identity-guarded (ownerSocket === ws), so its late firing won't clobber
    // the new owner we install here.
    if (this.ownerSocket && this.ownerSocket !== ws) {
      const stale = this.ownerSocket;
      logger.warn(
        "local listener: owner superseded — new app (pid=%s) took over from existing owner (pid=%s); closing stale socket 4409",
        newPid ?? "?",
        stale.data.appPid ?? "?",
      );
      this.busUnsubscribe?.();
      this.busUnsubscribe = null;
      this.ownerSocket = null;
      try { stale.close(CLOSE_CONFLICT, "owner superseded"); } catch {}
    } else {
      logger.info("local listener: owner connected (app pid=%s)", newPid ?? "?");
    }

    ws.data.state = "connected";
    ws.data.appPid = newPid;
    this.ownerSocket = ws;
    ws.send(JSON.stringify({ type: "ready" }));
    this.busUnsubscribe = this.opts.bus.subscribe(this);
    this.opts.onOwnerConnected?.();
  }

  private handleFrame(ws: ServerWebSocket<ConnState>, text: string): void {
    let envelope: any;
    try { envelope = JSON.parse(text); } catch { return; }
    const channel: Channel = envelope.channel === "preview" ? "preview" : "control";
    delete envelope.channel;
    // parseMessageFast takes a JSON string — re-stringify after stripping channel.
    const msg = parseMessageFast(JSON.stringify(envelope));
    if (!msg) return;
    // `loopback`: the owner is the desktop, trusted by the socket + token — its
    // frames are never subject to the per-phone allowlist gate, even when this
    // core has also been promoted onto the relay (shared bus + handler).
    this.opts.bus.dispatchInbound(msg, channel, "loopback");
  }
}
