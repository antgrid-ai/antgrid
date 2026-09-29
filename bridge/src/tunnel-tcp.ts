import net from "node:net";
import tls from "node:tls";
import type { StreamSendOutcome } from "./peer/stream-records";

/** How long an upstream connect may take. A refused port answers at once;
 *  this only bounds a listener that accepts SYNs and then never completes the
 *  handshake. */
export const TCP_CONNECT_TIMEOUT_MS = 10_000;

/** How long the TLS probe waits for a ServerHello. A plaintext HTTP server
 *  answers a ClientHello with a 400 and closes at once, so only a listener
 *  that waits silently for more bytes ever runs this out — which is not TLS. */
export const TLS_PROBE_TIMEOUT_MS = 3_000;

/** How long, after the app's side ends, the upstream may keep talking before
 *  the bridge half-closes it. Bytes it sends meanwhile are read and discarded,
 *  so a response still in flight is not cut off by unread data in our receive
 *  buffer (which the kernel would answer with a reset). */
export const TCP_END_DRAIN_MS = 300;

/** The one place a socket is destroyed rather than ended: an upstream that
 *  neither reads nor closes after the tunnel is over would otherwise hold its
 *  descriptor and any parked write until the dev server itself exits. */
export const TCP_END_DESTROY_MS = 60_000;

/** One TCP tunnel's view of its own stream (the registry implements it). */
export interface TunnelTcpPeer {
  /** The upstream is up: the reply record goes out before any raw byte. */
  ready(): Promise<StreamSendOutcome>;
  /** Nothing answered on the port: an error record, then FIN. */
  unreachable(message: string): void;
  /** Upstream output toward the app. Resolves once it has left the send
   *  queue, which is what paces the upstream read. */
  data(bytes: Uint8Array): Promise<StreamSendOutcome>;
  /** The upstream closed: FIN after every byte already sent. Idempotent. */
  end(): void;
}

/** What the registry feeds app-side traffic into. */
export interface TunnelTcpUpstreamSink {
  /** Resolves once the socket has taken the bytes (after a drain, when it
   *  pushed back), so the stream's next raw read waits on it. */
  write(bytes: Uint8Array): Promise<void>;
  /** The app's side is over (FIN, reset or teardown). The bridge never resets
   *  the upstream on its own initiative: it stops relaying, keeps reading and
   *  discarding so its receive buffer is empty, then half-closes once the
   *  upstream has finished or a short window has passed. An upstream still
   *  streaming a large body when the browser gives up can still see a reset,
   *  exactly as it would from a real browser; a dev server with no socket
   *  error listener dies of that, so the window is what keeps the common case
   *  (a response that has just finished) clean. Idempotent. */
  end(): void;
}

function connectMessage(err: unknown): string {
  const code = (err as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : err instanceof Error ? err.message : String(err);
}

/**
 * One upstream `localhost:<port>` connection piped to one tunnel stream.
 * `localhost` rather than a literal address: a dev server may listen on only
 * one of `::1` / `127.0.0.1`, and resolving the name reaches either.
 *
 * Half-close toward the app is deliberately not modelled. Bun's client sockets lose the
 * read side when their write side ends, so an end in either direction winds
 * the whole connection down — which is also all an HTTP client ever does.
 */
export class TunnelTcpRun implements TunnelTcpUpstreamSink {
  private socket: net.Socket | undefined;
  private connected = false;
  private over = false;
  private drainTimer: ReturnType<typeof setTimeout> | undefined;
  private destroyTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private readonly port: number,
    private readonly peer: TunnelTcpPeer,
    private readonly onSettled: (run: TunnelTcpRun) => void,
    private readonly connectTimeoutMs = TCP_CONNECT_TIMEOUT_MS,
    private readonly endDrainMs = TCP_END_DRAIN_MS,
    private readonly endDestroyMs = TCP_END_DESTROY_MS,
  ) {}

  start(): void {
    if (this.socket || this.over) return;
    const socket = net.connect({ host: "localhost", port: this.port, allowHalfOpen: false });
    this.socket = socket;
    socket.setNoDelay(true);
    socket.setTimeout(this.connectTimeoutMs, () => {
      if (this.connected) return;
      // Destroyed even when the run already ended: an `end()` that arrived
      // mid-handshake left this socket to finish, and a handshake that never
      // finishes would otherwise hold its descriptor for the OS connect timeout.
      socket.destroy();
      this.failBeforeConnect("connect timed out");
    });
    socket.once("connect", () => {
      socket.setTimeout(0);
      if (this.over) {
        this.winddown(socket);
        return;
      }
      this.connected = true;
      // Paused until the reply record is queued, so no raw byte can overtake it.
      socket.pause();
      void this.peer.ready().then((outcome) => {
        if (outcome !== "sent") {
          this.end();
          return;
        }
        if (!this.over) socket.resume();
      });
    });
    socket.on("data", (chunk: Buffer) => {
      if (this.over) return;
      socket.pause();
      void this.peer.data(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength)).then((outcome) => {
        if (outcome !== "sent") {
          this.end();
          return;
        }
        if (!this.over) socket.resume();
      });
    });
    socket.on("error", (err) => {
      if (!this.connected) {
        this.failBeforeConnect(connectMessage(err));
        return;
      }
      this.settle();
    });
    socket.on("close", () => {
      this.clearTimers();
      if (!this.connected) {
        this.failBeforeConnect("connection closed");
        return;
      }
      this.settle();
    });
  }

  write(bytes: Uint8Array): Promise<void> {
    const socket = this.socket;
    if (!socket || this.over || !this.connected) return Promise.resolve();
    if (socket.write(bytes)) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        socket.off("drain", done);
        socket.off("close", done);
        resolve();
      };
      socket.on("drain", done);
      socket.on("close", done);
    });
  }

  end(): void {
    if (this.over) return;
    this.over = true;
    // A socket still connecting is left to finish and then ended by the
    // connect handler above: closing it mid-handshake is the reset this
    // class promises never to send.
    if (this.connected && this.socket) this.winddown(this.socket);
    this.peer.end();
    this.onSettled(this);
  }

  /** Ends the upstream socket without resetting it: reads stay flowing (the
   *  data handler drops what arrives) so nothing is left unread, and the
   *  half-close waits for the upstream's own end or the drain window. */
  private winddown(socket: net.Socket): void {
    socket.resume();
    const finish = () => {
      if (this.drainTimer) clearTimeout(this.drainTimer);
      this.drainTimer = undefined;
      if (!socket.destroyed) socket.end();
    };
    socket.once("end", finish);
    this.drainTimer = setTimeout(finish, this.endDrainMs);
    this.drainTimer.unref?.();
    this.destroyTimer = setTimeout(() => socket.destroy(), this.endDestroyMs);
    this.destroyTimer.unref?.();
  }

  private clearTimers(): void {
    if (this.drainTimer) clearTimeout(this.drainTimer);
    if (this.destroyTimer) clearTimeout(this.destroyTimer);
    this.drainTimer = undefined;
    this.destroyTimer = undefined;
  }

  /** The upstream never came up: an error record, then FIN. */
  fail(message: string): void {
    this.failBeforeConnect(message);
  }

  private failBeforeConnect(message: string): void {
    if (this.over) return;
    this.over = true;
    this.socket?.destroy();
    this.peer.unreachable(message);
    this.onSettled(this);
  }

  /** The upstream closed or errored after connecting: the tunnel ends with
   *  it, cleanly — the app sees FIN after the bytes already relayed. */
  private settle(): void {
    if (this.over) return;
    this.over = true;
    this.peer.end();
    this.onSettled(this);
  }
}

export type TlsProbeResult = { reachable: false; message: string } | { reachable: true; tls: boolean };

/** Whether `localhost:<port>` answers at all, and whether it answers a TLS
 *  ClientHello. The page's scheme is chosen from this before the WebView
 *  dials, so a TLS-only dev server the bridge never saw announce itself is
 *  loaded as https rather than guessed as http. */
export function probeTls(port: number, timeoutMs = TLS_PROBE_TIMEOUT_MS): Promise<TlsProbeResult> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: TlsProbeResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const socket = tls.connect({ host: "localhost", port, rejectUnauthorized: false, servername: "localhost" });
    const timer = setTimeout(() => {
      socket.destroy();
      finish({ reachable: true, tls: false });
    }, timeoutMs);
    socket.once("secureConnect", () => {
      // Bun reports secureConnect for a plaintext server that simply hung up
      // on the ClientHello; only a negotiated cipher proves a TLS peer.
      const negotiated = Boolean(socket.getCipher()?.name);
      socket.end();
      finish({ reachable: true, tls: negotiated });
    });
    // A listener that hangs up without an error or a handshake is up and not TLS.
    socket.once("close", () => finish({ reachable: true, tls: false }));
    // Never `once`: a reset after the verdict is still an error event, and an
    // unhandled one takes the whole host down.
    socket.on("error", (err) => {
      const code = (err as { code?: unknown }).code;
      if (code === "ECONNREFUSED" || code === "ConnectionRefused") {
        finish({ reachable: false, message: connectMessage(err) });
        return;
      }
      // A TLS-layer failure (alert, handshake failure) is a TLS peer that
      // refused this client; only a bare reset or hang-up means plaintext.
      finish({ reachable: true, tls: isTlsLayerError(err) });
    });
  });
}

function isTlsLayerError(err: unknown): boolean {
  const code = (err as { code?: unknown } | null)?.code;
  if (typeof code === "string" && (code.startsWith("ERR_SSL_") || code.startsWith("ERR_TLS_"))) return true;
  const message = err instanceof Error ? err.message : "";
  return /alert|SSL routines|handshake failure/i.test(message);
}
