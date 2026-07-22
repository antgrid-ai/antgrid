import { randomBytes } from "node:crypto";
import { CONTROL_STREAM_ID } from "antgrid-wire";
import type { Channel, MessageBus } from "./message-bus";
import { parseMessageFast } from "./protocol";
import { parseTunnelMessage } from "./tunnel-protocol";
import { logger } from "./logger";

/** A project's attachment to the single machine relay socket. Opaque `streamId`
 *  namespaces this project's sealed frames inside the one E2E session (design
 *  §7.1); `detach()` releases it, `sendTunnel` routes a preview/tunnel-protocol
 *  message tagged with the stream. */
export interface StreamHandle {
  readonly streamId: string;
  detach(): void;
  /** Send a tunnel-protocol (preview channel) message tagged with this stream. */
  sendTunnel(data: object): void;
}

export interface AttachStreamOpts {
  /** Relay acked the stream-open (data-plane slot admitted). */
  onAdmitted?: (streamId: string) => void;
  /** Relay rejected the stream-open (e.g. `SESSION_LIMIT_EXCEEDED`); the socket
   *  and every other stream stay live. */
  onRejected?: (code: string, message: string) => void;
  /** The machine's paired phone became reachable (session established / peer
   *  online). Also fired at attach time when the session is already established,
   *  so a drill-in stream resumes immediately. */
  onPeerOnline?: () => void;
  onPeerOffline?: () => void;
  /** The grant was severed (phone unpaired / displaced). */
  onUnpaired?: () => void;
  /** A preview-channel tunnel-protocol message routed to this stream. */
  onTunnel?: (raw: unknown) => void;
}

/** The slice of the machine {@link RelayClient} the mux drives. Kept minimal so
 *  the mux is unit-testable against a stub. */
export interface StreamMuxTransport {
  openStream(streamId: string): void;
  closeStream(streamId: string): void;
  /** Seal + fragment + send one stream-tagged app envelope on `channel`. */
  sendEnvelope(streamId: string, msg: unknown, channel: Channel): void;
}

interface StreamEntry {
  bus: MessageBus;
  unsub: () => void;
  opts: AttachStreamOpts;
  settled: boolean;
}

/**
 * Multiplexes project streams over the single machine relay socket (design §7).
 * Owned by the machine {@link RelayClient}: it allocates opaque stream ids,
 * drives stream-open/close admission, tags outbound bus traffic with the
 * stream's id, and routes inbound `{s, m}` envelopes back to the right project
 * bus. Control-plane traffic (`s` omitted / `"0"`) is handled by the RelayClient
 * directly, never here.
 */
export class StreamMux {
  private readonly streams = new Map<string, StreamEntry>();
  /** Last broadcast peer state, so a stream attached mid-session inherits it. */
  private peerOnline = false;

  constructor(private readonly transport: StreamMuxTransport) {}

  attach(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    // 16 hex chars from 8 random bytes — opaque, allocated agent-side (§7.1).
    const streamId = randomBytes(8).toString("hex");
    const unsub = bus.subscribe({
      deliver: (msg, channel) => this.transport.sendEnvelope(streamId, msg, channel),
    });
    this.streams.set(streamId, { bus, unsub, opts, settled: false });
    this.transport.openStream(streamId);
    // A stream attached while the session is already established (drill-in) never
    // sees a fresh peer-online, so resume it now.
    if (this.peerOnline) opts.onPeerOnline?.();
    return {
      streamId,
      detach: () => this.detach(streamId),
      sendTunnel: (data) => this.transport.sendEnvelope(streamId, data, "preview"),
    };
  }

  private detach(streamId: string): void {
    const entry = this.streams.get(streamId);
    if (!entry) return;
    this.streams.delete(streamId);
    try { entry.unsub(); } catch { /* bus already gone */ }
    this.transport.closeStream(streamId);
  }

  /** Relay acked `stream-opened`. */
  onOpened(streamId: string): void {
    const entry = this.streams.get(streamId);
    if (!entry || entry.settled) return;
    entry.settled = true;
    entry.opts.onAdmitted?.(streamId);
  }

  /** A relay `error{ref}` — routed here iff `ref` is a live streamId (a
   *  stream-open rejection, notably `SESSION_LIMIT_EXCEEDED`). Returns false when
   *  `ref` is not one of our streams so the caller keeps normal error handling
   *  (pair-request nonces never collide with 16-hex streamIds). */
  onError(ref: string, code: string, message: string): boolean {
    const entry = this.streams.get(ref);
    if (!entry) return false;
    if (!entry.settled) {
      entry.settled = true;
      entry.opts.onRejected?.(code, message);
    }
    return true;
  }

  /** Route an inbound envelope's message (`m`, serialized) to its stream. Returns
   *  false for an unknown streamId so the caller drops + logs. */
  dispatchInbound(streamId: string, mJson: string, channel: Channel): boolean {
    const entry = this.streams.get(streamId);
    if (!entry) return false;
    const msg = parseMessageFast(mJson);
    if (msg) {
      entry.bus.dispatchInbound(msg, channel, "relay");
      return true;
    }
    const tunnel = parseTunnelMessage(mJson);
    if (tunnel) entry.opts.onTunnel?.(tunnel);
    return true;
  }

  notifyPeerOnline(): void {
    this.peerOnline = true;
    for (const entry of this.streams.values()) entry.opts.onPeerOnline?.();
  }

  notifyPeerOffline(): void {
    this.peerOnline = false;
    for (const entry of this.streams.values()) entry.opts.onPeerOffline?.();
  }

  notifyUnpaired(): void {
    this.peerOnline = false;
    for (const entry of this.streams.values()) entry.opts.onUnpaired?.();
  }

  /** Re-send `stream-open` for every attached stream. Called on `welcome` after
   *  a reconnect: the relay dropped its openStreams on the disconnect, so the
   *  count (sessionLimit) must be re-established before app traffic resumes.
   *  Already-settled streams keep their firstRegister outcome (onOpened no-ops). */
  reopenAll(): void {
    for (const streamId of this.streams.keys()) this.transport.openStream(streamId);
  }

  /** Tear every stream down (socket close / client shutdown). */
  detachAll(): void {
    for (const streamId of [...this.streams.keys()]) this.detach(streamId);
  }
}

export { CONTROL_STREAM_ID };
