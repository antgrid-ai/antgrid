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
   *  `target` names the app session that asked: a tunnel body answers exactly
   *  one request, so fanning it out to every attached device both wastes the
   *  link and hands one device another's response. Absent = every session.
   *
   *  Resolves when the message left the send queue — "sent"/"dropped"/
   *  "too-large" from the send path, or "gated" when this stream's outbound
   *  authorization refused it. */
  sendTunnel(data: object, target?: SendTarget): Promise<SendOutcome>;
  /** Send one frame on a named channel to a single app session, bypassing the
   *  bus. The bus has no addressing, so a published frame reaches every
   *  established session — including the human's phone, which is attached here
   *  too and must never see another agent's bus traffic. Resolves
   *  the same outcomes as `sendTunnel`, so a caller with an outbox can hold the
   *  frame rather than assume it left. */
  sendTo(msg: unknown, channel: Channel, target: SendTarget): Promise<SendOutcome>;
}

/** What one app session looks like to everything outside the relay client. No
 *  key material ever leaves that file. */
export interface PeerSessionView {
  readonly peerId: string;
  readonly peerPubkey: string;
  readonly checkoutRouting: boolean;
  readonly reachable: boolean;
  /** Whether this device pulls trees on demand rather than being pushed them.
   *  Per-device: the bridge may only stop pushing when EVERY attached one does. */
  readonly pullsTree: boolean;
}

/** Who an outbound frame is for. A bridge holds one E2E session per attached
 *  app device, so every send either fans out (optionally filtered per receiver)
 *  or names the single session that asked. */
export type SendTarget =
  | { kind: "broadcast"; where?: (peer: PeerSessionView) => boolean }
  | { kind: "peer"; peerId: string };

/** Conjunction of two optional receiver filters, so a stream's own per-receiver
 *  mute layers under whatever filter the caller passed. */
function bothOf(
  a: ((peer: PeerSessionView) => boolean) | undefined,
  b: ((peer: PeerSessionView) => boolean) | undefined,
): ((peer: PeerSessionView) => boolean) | undefined {
  if (!a) return b;
  if (!b) return a;
  return (peer) => a(peer) && b(peer);
}

/** Why one session may not drive this stream, as the app is told it. */
export interface StreamRefusal {
  readonly code: string;
  readonly message: string;
}

export interface AttachStreamOpts {
  /** The project this stream carries, named on a refusal so the app can fail the
   *  exact bind it is waiting on instead of guessing. */
  projectId?: string;
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
  /** One app session ended (liveness, presence, eviction, socket close) while
   *  others may still be attached. Distinct from `onPeerOffline`, which fires
   *  only when the LAST reachable session is gone: a device that quit must stop
   *  vouching for the focus and unread state it had on screen even though a
   *  sibling device is still driving the machine. */
  onPeerSessionGone?: (peerId: string) => void;
  /** A preview-channel tunnel-protocol message routed to this stream, tagged
   *  with the session it came from so the answer can be addressed back. */
  onTunnel?: (raw: unknown, peerId: string) => void;
  /** Outbound authorization: consulted on EVERY frame this stream would send.
   *  The mirror of the core's inbound gate — a stream carries project data off
   *  the machine, so it rides the same machine mobile-access switch that every
   *  inbound verb does, read live so a `mobile-access:set` takes effect without
   *  tearing the stream down. Absent = always deliver (local/wizard callers that
   *  answer to no switch); callers that HAVE a switch must fail closed in their
   *  own provider, not here. */
  mayDeliver?: () => boolean;
  /** Per-RECEIVER half of the same gate, consulted once per attached session —
   *  on a broadcast AND on a peer-addressed send, since a reply is exactly as
   *  unreadable to a muted device as a push is. Absent = deliver to every
   *  session. Lets a stale app that cannot route checkouts be muted without
   *  also muting a modern one on the same machine. */
  mayDeliverTo?: (peer: PeerSessionView) => boolean;
  /** Per-SENDER mirror of {@link mayDeliverTo}, consulted on every inbound frame
   *  — bus verbs AND tunnel frames, which bypass the bus and so are gated
   *  nowhere else per device. Absent = accept from every session; a refusal is
   *  returned rather than thrown so the mux can ANSWER the sender: an app binds
   *  a `streamId` it read off the `agent:projects` advert without a fresh
   *  `project:start`, so the refusal that verb would have given it is never
   *  reached and silence leaves it rendering an empty project forever.
   *  `null` peer = a frame whose session we cannot resolve. */
  mayAcceptFrom?: (peer: PeerSessionView | null) => StreamRefusal | null;
}

/** The slice of the machine {@link RelayClient} the mux drives. Kept minimal so
 *  the mux is unit-testable against a stub. */
export interface StreamMuxTransport {
  openStream(streamId: string): void;
  closeStream(streamId: string): void;
  /** Seal + fragment + send one stream-tagged app envelope on `channel`, once
   *  per session `target` selects (absent = every established session).
   *  Resolves when the message left the send queue. */
  sendEnvelope(
    streamId: string,
    msg: unknown,
    channel: Channel,
    target?: SendTarget,
  ): Promise<SendOutcome>;
  /** What the machine knows about one app session, or null for a route id that
   *  holds none. The mux needs it to apply a stream's per-device filters to a
   *  peer-addressed send and to an inbound frame, both of which name a session
   *  rather than enumerate them. */
  peerSession(peerId: string): PeerSessionView | null;
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
  /** `<kind> <peerId> <streamId>` → when we last sent that session that notice,
   *  so a phone that keeps replaying on a stream (or ignores the notice) can't
   *  turn every dropped frame into a control-plane send. Keyed per session
   *  because each attached device has to be told separately: one device's
   *  notice must not silence the other's for the cooldown. */
  private readonly noticeSentAt = new Map<string, number>();

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
    // The per-receiver mute applies to a peer-addressed send too. Being the
    // session that asked is not an admission: tunnel frames bypass the bus, so
    // the only producer of peer targets is the one path whose sender was never
    // checked against this filter — and a device that cannot address a checkout
    // would read an isolated session's preview as the main worktree's whether it
    // asked for it or not. `null` = nothing to send to; the caller drops.
    const gated = (target?: SendTarget): SendTarget | null => {
      if (target?.kind !== "peer") {
        return { kind: "broadcast", where: bothOf(target?.where, opts.mayDeliverTo) };
      }
      if (!opts.mayDeliverTo) return target;
      const peer = this.transport.peerSession(target.peerId);
      return peer && opts.mayDeliverTo(peer) ? target : null;
    };
    const sendTo = (
      msg: unknown,
      channel: Channel,
      target?: SendTarget,
    ): Promise<SendOutcome> => {
      if (!mayDeliver()) return Promise.resolve<SendOutcome>("gated");
      // A target the per-receiver mute filtered away is the same fact as the
      // machine switch being off, not a drop: nothing was queued, so a caller
      // holding an outbox must not retire the frame.
      const to = gated(target);
      if (!to) return Promise.resolve<SendOutcome>("gated");
      return this.transport.sendEnvelope(streamId, msg, channel, to);
    };
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
        const target = gated();
        if (target) void this.transport.sendEnvelope(streamId, msg, channel, target);
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
      sendTunnel: (data, target) => sendTo(data, "preview", target),
      sendTo: (msg, channel, target) => sendTo(msg, channel, target),
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
  private notifyStreamInvalid(streamId: string, peerId: string): void {
    if (!this.noticeDue(`invalid ${peerId} ${streamId}`)) return;
    // Addressed at the sender: the notice answers one bad frame, and telling a
    // healthy device its stream is dead makes it renegotiate for nothing.
    void this.transport.sendEnvelope(
      CONTROL_STREAM_ID,
      createMessage("stream-invalid", { streamId }),
      "control",
      { kind: "peer", peerId },
    );
  }

  /** Tell one session why this stream refuses its frames. Same shape and channel
   *  the `project:start` refusal takes, so the app surfaces it through the path
   *  it already has — and addressed, because a healthy sibling banner-ing
   *  someone else's UPDATE_REQUIRED is worse than the silence this replaces. */
  private notifyRefused(
    streamId: string,
    peerId: string,
    refusal: StreamRefusal,
    projectId: string | undefined,
  ): void {
    if (!this.noticeDue(`refused ${peerId} ${streamId}`)) return;
    void this.transport.sendEnvelope(
      CONTROL_STREAM_ID,
      createMessage("control:result", {
        ok: false,
        projectId,
        error: { code: refusal.code, message: refusal.message },
      }),
      "control",
      { kind: "peer", peerId },
    );
  }

  /** Rate limit shared by both addressed notices, swept so a long-lived host
   *  can't accumulate an entry per dead id. */
  private noticeDue(key: string): boolean {
    const now = this.now();
    const last = this.noticeSentAt.get(key);
    if (last !== undefined && now - last < INVALID_NOTICE_COOLDOWN_MS) return false;
    for (const [id, at] of this.noticeSentAt) {
      if (now - at >= INVALID_NOTICE_TTL_MS) this.noticeSentAt.delete(id);
    }
    this.noticeSentAt.set(key, now);
    return true;
  }

  /** Route an inbound envelope's message (`m`, serialized) to its stream. Returns
   *  false for an unknown streamId so the caller drops + logs — and answers the
   *  phone with `stream-invalid` so a host restart self-heals. */
  dispatchInbound(streamId: string, mJson: string, channel: Channel, peerId: string): boolean {
    const entry = this.streams.get(streamId);
    if (!entry) {
      this.notifyStreamInvalid(streamId, peerId);
      return false;
    }
    // Per-sender gate ahead of BOTH routes below, because the tunnel route
    // bypasses the bus and would otherwise proxy arbitrary HTTP out of a
    // checkout for a device every other path on this stream refuses.
    const refusal = entry.opts.mayAcceptFrom?.(this.transport.peerSession(peerId)) ?? null;
    if (refusal) {
      this.notifyRefused(streamId, peerId, refusal, entry.opts.projectId);
      return true;
    }
    // The peer is transmitting on this stream, so it holds a transport for it —
    // the strongest possible retraction of an earlier `stream-unbound`, and the
    // one that needs no cooperation from whoever muted it.
    if (entry.unboundAtPeer) this.markBound(streamId);
    const msg = parseMessageFast(mJson);
    if (msg) {
      entry.bus.dispatchInbound(msg, channel, "relay", peerId);
      return true;
    }
    const tunnel = parseTunnelMessage(mJson);
    if (tunnel) entry.opts.onTunnel?.(tunnel, peerId);
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

  /** Coarse "some device is reachable". Guarded on the flag so a second device
   *  attaching does not re-run every stream's resume for a machine that was
   *  already online. */
  notifyPeerOnline(): void {
    if (this.peerOnline) return;
    this.peerOnline = true;
    // A fresh E2E session re-adverts every project and the app rebinds from
    // that, so a mute earned by the PREVIOUS session must not silence this one.
    // Costs at most one more notice per stream if the new peer is unbound too.
    for (const entry of this.streams.values()) {
      entry.unboundAtPeer = false;
      entry.opts.onPeerOnline?.();
    }
  }

  /** Coarse "no device is reachable" — the caller fires this only when the LAST
   *  session is gone. */
  notifyPeerOffline(): void {
    if (!this.peerOnline) return;
    this.peerOnline = false;
    for (const entry of this.streams.values()) entry.opts.onPeerOffline?.();
  }

  /** One session ended while others may remain. Never touches the coarse flag. */
  notifyPeerSessionOffline(peerId: string): void {
    for (const entry of this.streams.values()) entry.opts.onPeerSessionGone?.(peerId);
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
