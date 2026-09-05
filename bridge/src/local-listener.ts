import { timingSafeEqual } from "node:crypto";
import type { ServerWebSocket } from "bun";
import { MessageBus, type Channel, type TransportSubscriber } from "./message-bus";
import { parseMessageFast, type AbMessage } from "./protocol";
import { netwatch, frameIdFor, captureBody } from "./netwatch";
import { logger } from "./logger";
const log = logger.child({ component: "local-listener" });

interface ConnState {
  state: "awaiting-hello" | "connected" | "rejected";
  appPid?: number;
  checkoutRouting?: boolean;
}

export interface LocalListenerOptions {
  bus: MessageBus;
  token: string;
  /**
   * Diagnostics only — never an authorization or routing input. The netwatch
   * ring is process-wide while a bridge hosts one listener per project core, so
   * every core's loopback traffic lands in ONE interleaved stream; without this
   * tag a reader cannot tell whose frames they are looking at.
   */
  projectId: string;
  /** Optional allow-list for Origin header. Default: only empty/missing Origin allowed. */
  allowedOrigins?: string[];
  /**
   * Invoked once a client completes the hello handshake and is promoted to
   * owner. Used by the agent to replay cached state to late joiners.
   */
  onOwnerConnected?: () => void;
  /**
   * Invoked when the promoted owner's socket closes. NOT fired when an owner is
   * superseded by a replacement — {@link ownerSocket} has already moved on by
   * then, and the new owner announces its own state.
   */
  onOwnerDisconnected?: () => void;
}

const CLOSE_UNAUTHORIZED = 4401;
const CLOSE_CONFLICT = 4409;
export const CLOSE_CHECKOUT_ROUTING_REQUIRED = 4410;

export class LocalListener implements TransportSubscriber {
  private server: ReturnType<typeof Bun.serve> | null = null;
  private connections = new Set<ServerWebSocket<ConnState>>();
  private ownerSocket: ServerWebSocket<ConnState> | null = null;
  private busUnsubscribe: (() => void) | null = null;

  constructor(private opts: LocalListenerOptions) {}

  /** Stamped on every event this listener records — see `projectId`'s note. */
  private get netwatchDetail(): Record<string, string> {
    return { project: this.opts.projectId };
  }

  /** True while a desktop owner is connected over the loopback socket. The
   *  relay slot's `onPeerOffline` (phone left) consults this so it never
   *  suppresses the bus a live loopback owner is still streaming from. */
  get hasOwner(): boolean {
    return this.ownerSocket !== null;
  }

  /** Compatibility signal supplied by the loopback app hello. It is deliberately
   * not an authorization signal; routing gates still run after socket/token
   * authentication. */
  get ownerSupportsCheckoutRouting(): boolean {
    return this.ownerSocket?.data.checkoutRouting === true;
  }

  /** Fail closed before a managed-checkout frame can reach an older desktop. */
  requireCheckoutRouting(): boolean {
    if (!this.ownerSocket || this.ownerSupportsCheckoutRouting) return true;
    const stale = this.ownerSocket;
    this.ownerSocket = null;
    this.busUnsubscribe?.();
    this.busUnsubscribe = null;
    stale.data.state = "rejected";
    stale.close(CLOSE_CHECKOUT_ROUTING_REQUIRED, "checkout routing update required");
    return false;
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
            log.info("local listener: owner disconnected (app pid=%s)", ws.data.appPid ?? "?");
            this.ownerSocket = null;
            this.busUnsubscribe?.();
            this.busUnsubscribe = null;
            this.opts.onOwnerDisconnected?.();
          }
        },
      },
    });

    log.info(`local listener bound on 127.0.0.1:${this.server.port}`);
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
    if (!this.ownerSocket) {
      // The frame is discarded with no log at any level, no retry and no notice
      // to anyone: a core emitting into a window where the desktop has quit,
      // not yet said hello, or is mid-reconnect loses everything it produced,
      // which is where "the app never showed that" begins.
      netwatch.record({
        dir: "tx", kind: "drop", transport: "local", channel,
        msgType: msg.type, frameId: msg.id, reason: "no-owner",
        detail: this.netwatchDetail,
      });
      return;
    }
    // Serialized once and reused for the byte count: this runs on every frame
    // the desktop sees, terminal output included.
    const json = JSON.stringify({ channel, ...msg });
    this.ownerSocket.send(json);
    netwatch.record({
      dir: "tx", kind: "json", transport: "local", channel,
      msgType: msg.type,
      // Loopback is point-to-point with no intermediary re-wrapping anything, so
      // the message's own uuid is already an id BOTH endpoints see — the relay
      // path's nonce-derived key exists only because its route header has none.
      frameId: msg.id,
      bytes: Buffer.byteLength(json, "utf8"),
      body: captureBody(json),
      detail: this.netwatchDetail,
    });
  }

  /**
   * A refused hello is the one failure a relay-path capture can never show:
   * both halves of that capture ride the sealed session, so a session that never
   * came up records nothing at all and "it just never connected" is invisible by
   * construction. On loopback it is an ordinary event.
   *
   * NEVER attach a body here, and never let the hello's text or its `token`
   * field reach any recorded value. The envelope carries this core's shared
   * secret in cleartext, and netwatch events are written to netwatch.log and
   * handed out verbatim by the CLI's export — a captured hello would publish the
   * credential that guards this socket. The frameId is a sha256 prefix of the
   * frame, not the secret, and it is the only join key an id-less handshake has.
   */
  private recordHelloRefused(text: string, reason: string): void {
    netwatch.record({
      dir: "rx", kind: "drop", transport: "local",
      reason, bytes: Buffer.byteLength(text, "utf8"),
      frameId: frameIdFor(Buffer.from(text, "utf8"), false),
      detail: this.netwatchDetail,
    });
  }

  private handleHello(ws: ServerWebSocket<ConnState>, text: string, tokenBuf: Buffer): void {
    let envelope: any;
    try { envelope = JSON.parse(text); } catch {
      log.warn("local listener: rejecting hello (bad envelope), closing 4401");
      this.recordHelloRefused(text, "hello-not-json");
      ws.close(CLOSE_UNAUTHORIZED, "bad envelope"); return;
    }
    if (envelope?.type !== "hello" || typeof envelope.token !== "string") {
      log.warn("local listener: rejecting hello (malformed), closing 4401");
      this.recordHelloRefused(text, "hello-malformed");
      ws.close(CLOSE_UNAUTHORIZED, "bad hello"); return;
    }
    const presented = Buffer.from(envelope.token);
    const ok = presented.length === tokenBuf.length && timingSafeEqual(presented, tokenBuf);
    if (!ok) {
      log.warn("local listener: rejecting hello (bad token), closing 4401");
      this.recordHelloRefused(text, "hello-bad-token");
      ws.close(CLOSE_UNAUTHORIZED, "bad token"); return;
    }

    const newPid = typeof envelope.appPid === "number" ? envelope.appPid : undefined;
    const checkoutRouting = envelope?.capabilities?.checkoutRouting === true;

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
      log.warn(
        "local listener: owner superseded — new app (pid=%s) took over from existing owner (pid=%s); closing stale socket 4409",
        newPid ?? "?",
        stale.data.appPid ?? "?",
      );
      this.busUnsubscribe?.();
      this.busUnsubscribe = null;
      this.ownerSocket = null;
      try { stale.close(CLOSE_CONFLICT, "owner superseded"); } catch {}
    } else {
      log.info("local listener: owner connected (app pid=%s)", newPid ?? "?");
    }

    ws.data.state = "connected";
    ws.data.appPid = newPid;
    ws.data.checkoutRouting = checkoutRouting;
    this.ownerSocket = ws;
    // The accepted hello and its answer, so a capture opens with the moment the
    // desktop attached rather than with unexplained traffic from a socket the
    // reader never saw come up. Recording only the REFUSALS would make every
    // successful session look like it had no beginning.
    //
    // Body-free for the same reason `recordHelloRefused` is: this envelope
    // carries the core's shared token, and an accepted hello carries a VALID
    // one.
    netwatch.record({
      dir: "rx", kind: "handshake", transport: "local",
      msgType: "hello", bytes: Buffer.byteLength(text, "utf8"),
      frameId: frameIdFor(Buffer.from(text, "utf8"), false),
      detail: { ...this.netwatchDetail, ...(newPid === undefined ? {} : { appPid: newPid }) },
    });
    const ready = JSON.stringify({ type: "ready" });
    ws.send(ready);
    netwatch.record({
      dir: "tx", kind: "handshake", transport: "local",
      msgType: "ready", bytes: Buffer.byteLength(ready, "utf8"),
      frameId: frameIdFor(Buffer.from(ready, "utf8"), false),
      detail: this.netwatchDetail,
    });
    this.busUnsubscribe = this.opts.bus.subscribe(this);
    this.opts.onOwnerConnected?.();
  }

  private handleFrame(ws: ServerWebSocket<ConnState>, text: string): void {
    let envelope: any;
    try { envelope = JSON.parse(text); } catch {
      // Text on an established socket that is not a message at all — a truncated
      // send, or something else speaking to this port. The bridge returns
      // silently, so without this the app's frame simply ceases to exist.
      netwatch.record({
        dir: "rx", kind: "drop", transport: "local",
        reason: "not-json", bytes: Buffer.byteLength(text, "utf8"),
        detail: this.netwatchDetail,
      });
      return;
    }
    const channel: Channel = envelope.channel === "preview" ? "preview" : "control";
    delete envelope.channel;
    // parseMessageFast takes a JSON string — re-stringify after stripping channel.
    const msg = parseMessageFast(JSON.stringify(envelope));
    if (!msg) {
      // An app and a bridge that disagree about the wire — a schema addition
      // only one half shipped. It is silent on both sides, and from the app it
      // is indistinguishable from a handler that simply chose not to answer.
      netwatch.record({
        dir: "rx", kind: "drop", transport: "local", channel,
        msgType: typeof envelope?.type === "string" ? envelope.type : undefined,
        frameId: typeof envelope?.id === "string" ? envelope.id : undefined,
        reason: "unparseable", bytes: Buffer.byteLength(text, "utf8"),
        // The one drop whose body earns its cost: "the schema refused it" is
        // unactionable without the text that was refused. Safe here in a way it
        // is not on the hello paths — this is post-handshake data plane and
        // carries no credential.
        body: captureBody(text),
        detail: this.netwatchDetail,
      });
      return;
    }
    netwatch.record({
      dir: "rx", kind: "json", transport: "local", channel,
      msgType: msg.type, frameId: msg.id,
      bytes: Buffer.byteLength(text, "utf8"),
      body: captureBody(text),
      detail: this.netwatchDetail,
    });
    // `loopback`: the owner is the desktop, trusted by the socket + token — its
    // frames are never subject to the per-phone allowlist gate, even when this
    // core has also been promoted onto the relay (shared bus + handler).
    this.opts.bus.dispatchInbound(msg, channel, "loopback");
  }
}
