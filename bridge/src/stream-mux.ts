import { randomBytes } from "node:crypto";
import { CONTROL_STREAM_ID } from "antgrid-wire";
import type { Channel, MessageBus } from "./message-bus";
import type { SendOutcome } from "./send-scheduler";
import { createMessage, parseMessageFast } from "./protocol";
import { parseTunnelMessage } from "./tunnel-protocol";
import { logger } from "./logger";

const log = logger.child({ component: "stream-mux" });

/** One `stream-invalid` per dead id per this window: a stranded phone replays a
 *  burst of verbs, and one notice is enough for it to rebind. */
export const INVALID_NOTICE_COOLDOWN_MS = 5_000;
/** How long a dead id stays in the rate-limit map. Past this the phone is either
 *  rebound (no more frames) or genuinely stuck and deserves a fresh notice. */
export const INVALID_NOTICE_TTL_MS = 60_000;

/** A project's attachment to the single machine relay socket. Opaque `streamId`
 *  namespaces this project's sealed frames inside the one E2E session;
 *  `detach()` releases it, `sendTunnel` routes a preview/tunnel-protocol
 *  message tagged with the stream. */
export interface StreamHandle {
  readonly streamId: string;
  detach(): void;
  /** Send a tunnel-protocol (preview channel) message tagged with this stream.
   *  Resolves when the message left the send queue — "sent"/"dropped"/
   *  "too-large" from the send path, or "gated" when this stream's outbound
   *  authorization refused it. */
  sendTunnel(data: object): Promise<SendOutcome>;
}

export interface AttachStreamOpts {
  /** Relay acked the stream-open (data-plane slot admitted). */
  onAdmitted?: (streamId: string) => void;
  /** Relay rejected the stream-open; the socket and every other stream stay
   *  live. Current relays admit every stream — the only rejection code we still
   *  decode, `SESSION_LIMIT_EXCEEDED`, is retired and reaches us only from a
   *  relay predating the worker-limit change. */
  onRejected?: (code: string, message: string) => void;
  /** The machine's paired phone became reachable (session established / peer
   *  online). Also fired at attach time when the session is already established,
   *  so a drill-in stream resumes immediately. */
  onPeerOnline?: () => void;
  onPeerOffline?: () => void;
  /** A preview-channel tunnel-protocol message routed to this stream. */
  onTunnel?: (raw: unknown) => void;
  /** Outbound authorization: consulted on EVERY frame this stream would send.
   *  The mirror of the core's inbound gate — a stream carries project data off
   *  the machine, so it rides the same machine mobile-access switch that every
   *  inbound verb does, read live so a `mobile-access:set` takes effect without
   *  tearing the stream down. Absent = always deliver (local/wizard callers that
   *  answer to no switch); callers that HAVE a switch must fail closed in their
   *  own provider, not here. */
  mayDeliver?: () => boolean;
}

/** The slice of the machine {@link RelayClient} the mux drives. Kept minimal so
 *  the mux is unit-testable against a stub. */
export interface StreamMuxTransport {
  openStream(streamId: string): void;
  closeStream(streamId: string): void;
  /** Seal + fragment + send one stream-tagged app envelope on `channel`.
   *  Resolves when the message left the send queue. */
  sendEnvelope(streamId: string, msg: unknown, channel: Channel): Promise<SendOutcome>;
}

interface StreamEntry {
  bus: MessageBus;
  unsub: () => void;
  opts: AttachStreamOpts;
  settled: boolean;
  /** The app answered `stream-unbound` for this id: it holds no transport, so
   *  every frame we push is discarded on arrival. Muted rather than detached —
   *  the core stays running for its loopback owner, the advert stays dialable,
   *  and a re-open reuses this same id (host-server publishes `stream-ready`
   *  with the recorded streamId), so tearing the stream down here would break
   *  the very reconnect that heals it. */
  unboundAtPeer: boolean;
}

/**
 * Multiplexes project streams over the single machine relay socket.
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
  /** Dead streamId → when we last told the phone about it, so a phone that keeps
   *  replaying on it (or ignores the notice) can't turn every dropped frame into
   *  a control-plane send. */
  private readonly invalidNotifiedAt = new Map<string, number>();

  constructor(
    private readonly transport: StreamMuxTransport,
    private readonly now: () => number = Date.now,
  ) {}

  attach(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    // 16 hex chars from 8 random bytes — opaque, allocated agent-side.
    const streamId = randomBytes(8).toString("hex");
    // Gate at the send, not at attach/detach: the stream stays open and the core
    // keeps running, so flipping the switch back on resumes delivery with no
    // re-attach and no lost core. Dropping mid-flight can strand an RPC the phone
    // is awaiting — acceptable, since the same switch already refuses its next
    // request; the app times that out and resyncs from a snapshot.
    const mayDeliver = () => opts.mayDeliver?.() ?? true;
    const entry: StreamEntry = {
      bus,
      unsub: () => {},
      opts,
      settled: false,
      unboundAtPeer: false,
    };
    entry.unsub = bus.subscribe({
      deliver: (msg, channel) => {
        // Ahead of mayDeliver: a stream nobody is receiving is not an
        // authorization question, and the switch is the more expensive read.
        if (entry.unboundAtPeer) return;
        if (!mayDeliver()) return;
        void this.transport.sendEnvelope(streamId, msg, channel);
      },
    });
    this.streams.set(streamId, entry);
    this.transport.openStream(streamId);
    // A stream attached while the session is already established (drill-in) never
    // sees a fresh peer-online, so resume it now.
    if (this.peerOnline) opts.onPeerOnline?.();
    return {
      streamId,
      detach: () => this.detach(streamId),
      // Gated too: tunnel frames bypass the bus (see setPlainHook), so the
      // subscriber check above never sees them. The refusal is "gated", NOT
      // "dropped": a WS tunnel must survive the switch being off (the close a
      // teardown would send is gated too, leaving the browser socket mute for
      // the life of the page), and a cleared queue and a closed switch are
      // different facts to the one consumer that awaits this.
      // The unbound mute stops at the bus deliberately: a tunnel run is driven
      // by a request arriving ON this stream, and inbound traffic un-mutes it,
      // so the muted case is a server-pushed frame on a tunnel that predates
      // the mute. Refusing it would need a third outcome — tunnel-manager.ts
      // branches on "sent", and "gated" is spoken for above.
      sendTunnel: (data) =>
        mayDeliver()
          ? this.transport.sendEnvelope(streamId, data, "preview")
          : Promise.resolve<SendOutcome>("gated"),
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
   *  stream-open rejection: `STREAM_LIMIT_EXCEEDED` from a current relay, or
   *  the retired `SESSION_LIMIT_EXCEEDED` from an older one). Returns false when
   *  `ref` is not one of our streams so the caller keeps normal error handling
   *  (a streamId is the only kind of `ref` the relay ever sends). */
  onError(ref: string, code: string, message: string): boolean {
    const entry = this.streams.get(ref);
    if (!entry) return false;
    if (!entry.settled) {
      entry.settled = true;
      entry.opts.onRejected?.(code, message);
    }
    return true;
  }

  /** Tell the phone a streamId is dead so it renegotiates instead of replaying
   *  onto it forever. Stream-scoped like the relay's `error{ref}`: the socket,
   *  the control plane and every live stream are untouched. Rate-limited per id
   *  because the phone's retries arrive as a burst, and the map is swept so a
   *  long-lived host can't accumulate an entry per dead id. */
  private notifyStreamInvalid(streamId: string): void {
    const now = this.now();
    const last = this.invalidNotifiedAt.get(streamId);
    if (last !== undefined && now - last < INVALID_NOTICE_COOLDOWN_MS) return;
    for (const [id, at] of this.invalidNotifiedAt) {
      if (now - at >= INVALID_NOTICE_TTL_MS) this.invalidNotifiedAt.delete(id);
    }
    this.invalidNotifiedAt.set(streamId, now);
    void this.transport.sendEnvelope(
      CONTROL_STREAM_ID,
      createMessage("stream-invalid", { streamId }),
      "control",
    );
  }

  /** Route an inbound envelope's message (`m`, serialized) to its stream. Returns
   *  false for an unknown streamId so the caller drops + logs — and answers the
   *  phone with `stream-invalid` so a host restart self-heals. */
  dispatchInbound(streamId: string, mJson: string, channel: Channel): boolean {
    const entry = this.streams.get(streamId);
    if (!entry) {
      this.notifyStreamInvalid(streamId);
      return false;
    }
    // The peer is transmitting on this stream, so it holds a transport for it —
    // the strongest possible retraction of an earlier `stream-unbound`, and the
    // one that needs no cooperation from whoever muted it.
    if (entry.unboundAtPeer) this.markBound(streamId);
    const msg = parseMessageFast(mJson);
    if (msg) {
      entry.bus.dispatchInbound(msg, channel, "relay");
      return true;
    }
    const tunnel = parseTunnelMessage(mJson);
    if (tunnel) entry.opts.onTunnel?.(tunnel);
    return true;
  }

  /** The app answered `stream-unbound`: it received a frame on [streamId] and
   *  holds no transport for it, so everything we push there is discarded. Mute
   *  until it proves otherwise — see {@link StreamEntry.unboundAtPeer} for why
   *  this mutes rather than detaches.
   *
   *  Advisory, NOT authorization: the peer can only mute a stream this host
   *  already opened for it, and the worst a lying peer achieves is silencing
   *  its own project. The switch (`mayDeliver`) is unaffected. */
  markUnbound(streamId: string): void {
    const entry = this.streams.get(streamId);
    if (!entry || entry.unboundAtPeer) return;
    entry.unboundAtPeer = true;
    log.warn("Stream %s unbound at the peer — muting until it rebinds", streamId);
  }

  /** The peer holds a transport for [streamId] again: resume delivery. Called
   *  when it transmits on the stream, and by the host when it re-publishes
   *  `stream-ready` — a re-open reuses the SAME id, so without this the mute
   *  would outlive the reconnect that heals it. */
  markBound(streamId: string): void {
    const entry = this.streams.get(streamId);
    if (!entry || !entry.unboundAtPeer) return;
    entry.unboundAtPeer = false;
    log.info("Stream %s rebound at the peer — resuming delivery", streamId);
  }

  notifyPeerOnline(): void {
    this.peerOnline = true;
    // A fresh E2E session re-adverts every project and the app rebinds from
    // that, so a mute earned by the PREVIOUS session must not silence this one.
    // Costs at most one more notice per stream if the new peer is unbound too.
    for (const entry of this.streams.values()) {
      entry.unboundAtPeer = false;
      entry.opts.onPeerOnline?.();
    }
  }

  notifyPeerOffline(): void {
    this.peerOnline = false;
    for (const entry of this.streams.values()) entry.opts.onPeerOffline?.();
  }

  /** Re-send `stream-open` for every attached stream. Called on `welcome` after
   *  a reconnect: the relay dropped its openStreams on the disconnect, so every
   *  stream must be re-admitted before app traffic resumes.
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
