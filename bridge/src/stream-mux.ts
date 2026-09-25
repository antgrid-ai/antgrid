import { randomBytes } from "node:crypto";
import { CONTROL_STREAM_ID } from "antgrid-wire";
import type { Channel, MessageBus } from "./message-bus";
import type { SendOutcome } from "./send-scheduler";
import { createMessage, parseMessageFast, type AbMessage } from "./protocol";
import type { TunnelStreamServer } from "./tunnel-manager";
import { logger } from "./logger";
import type { StreamSendOutcome } from "./peer/stream-records";

const log = logger.child({ component: "stream-mux" });

/** One `stream-invalid` per dead id per this window: a stranded phone replays a
 *  burst of verbs, and one notice is enough for it to rebind. */
export const INVALID_NOTICE_COOLDOWN_MS = 5_000;
/** How long a dead id stays in the rate-limit map. Past this the phone is either
 *  rebound (no more frames) or genuinely stuck and deserves a fresh notice. */
export const INVALID_NOTICE_TTL_MS = 60_000;

/** A project's attachment to the single machine relay socket. Opaque `streamId`
 *  namespaces this project's sealed frames inside the one E2E session;
 *  `detach()` releases it. Tunnel (preview) traffic never rides this handle
 *  (A3): it has its own QUIC streams admitted through
 *  {@link TunnelProjectBinding}. */
export interface StreamHandle {
  readonly streamId: string;
  detach(): void;
  /** Send one frame on a named channel to a single app session, bypassing the
   *  bus. The bus has no addressing, so a published frame reaches every
   *  established session — including the human's phone, which is attached here
   *  too and must never see another agent's bus traffic. Resolves once the
   *  frame left the send queue, so a caller with an outbox can hold it rather
   *  than assume it landed. */
  sendTo(msg: unknown, channel: Channel, target: SendTarget): Promise<SendOutcome>;
  /** Present iff the transport supports terminal attachment streams (A2). A
   *  terminal stream's `retired`/`subscribeSettled` land here, keyed by this
   *  project's own core rather than by peer, because the core is what knows
   *  when a terminal run ends or a subscribe attempt resolves. */
  readonly terminalHooks?: TerminalStreamHooks;
}

/** Delivered to whichever core owns a terminal stream's bound project, so it
 *  can react to a native attachment's lifecycle the same way it reacts to the
 *  loopback and legacy session-stream paths. See `terminal-streams.ts`. */
export interface TerminalStreamHooks {
  retired(peerId: string, attachmentId: string): void;
  subscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void;
}

/** What `TerminalStreamRegistry` needs from a project's mux entry to admit and
 *  route a terminal stream without opening or promoting a core itself (A2). */
export interface TerminalProjectBinding {
  readonly streamId: string;
  /** `entry.opts.mayAcceptFrom(peerSession(peerId))`, re-read on every call —
   *  the same per-sender gate `dispatchInbound` applies to the legacy path. */
  refusalFor(peerId: string): StreamRefusal | null;
  /** Re-resolves the entry by `streamId` and re-runs `refusalFor`; on a pass,
   *  retracts an `unboundAtPeer` mute exactly as `dispatchInbound` does, then
   *  calls `entry.bus.dispatchInbound(msg, "control", "relay", peerId)`. False
   *  when the entry has gone or `refusalFor` now refuses. */
  dispatch(msg: AbMessage, peerId: string): boolean;
}

/** What `TunnelStreamRegistry` needs from a project's mux entry to admit and
 *  route a tunnel stream without opening or promoting a core itself (A3). A
 *  tunnel stream carries no bus traffic, so unlike {@link TerminalProjectBinding}
 *  it has no `dispatch` — only the per-sender gate and the project's own
 *  {@link TunnelStreamServer}, which the registry calls to admit the stream. */
export interface TunnelProjectBinding {
  readonly streamId: string;
  /** `entry.opts.mayAcceptFrom(peerSession(peerId))`, re-read on every call —
   *  the same per-sender gate `dispatchInbound` applies to bus traffic. */
  refusalFor(peerId: string): StreamRefusal | null;
  /** Per-RECEIVER gate for a stream already admitted: the mirror of
   *  `refusalFor` for outbound records (head/body/end, or a WS frame). */
  mayDeliverTo(peerId: string): boolean;
  /** The project's tunnel server, or null if the entry is gone or declared
   *  none — either way the registry refuses the stream NOT_ALLOWED. */
  tunnels(): TunnelStreamServer | null;
}

/** What one app session looks like to everything outside the relay client. No
 *  key material ever leaves that file. */
export interface PeerSessionView {
  readonly peerId: string;
  readonly peerPubkey: string;
  readonly checkoutRouting: boolean;
  /** Whether this device pulls trees on demand rather than being pushed them.
   *  Per-device: the bridge may only stop pushing when EVERY attached one does. */
  readonly pullsTree: boolean;
  readonly terminalFramesV1?: boolean;
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
  /** Host-owned binding, independent of central relay registration. */
  streamId?: string;
  /** Local dispatch is ready; this does not acknowledge WebSocket admission. */
  onLocalReady?: (streamId: string) => void;
  /** The project this stream carries, named on a refusal so the app can fail the
   *  exact bind it is waiting on instead of guessing. */
  projectId?: string;
  /** Host-local binding is ready for native peer sessions. */
  onAdmitted?: (streamId: string) => void;
  /** A native app session was established. Also fired at attach time when a
   *  session is already established,
   *  so a drill-in stream resumes immediately. */
  onPeerOnline?: () => void;
  onPeerOffline?: () => void;
  /** One app session ended (liveness, presence, eviction, socket close) while
   *  others may still be attached. Distinct from `onPeerOffline`, which fires
   *  only when the LAST session is gone: a device that quit must stop
   *  vouching for the focus and unread state it had on screen even though a
   *  sibling device is still driving the machine. */
  onPeerSessionGone?: (peerId: string) => void;
  /** The project's tunnel server; absent => tunnel streams for this project are
   *  refused NOT_ALLOWED. */
  tunnels?: TunnelStreamServer;
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
  /** Per-SENDER mirror of {@link mayDeliverTo}, consulted on every inbound bus
   *  frame — and, via {@link TunnelProjectBinding.refusalFor}, at tunnel-stream
   *  open, since a tunnel stream now carries its own traffic off the bus
   *  entirely. Absent = accept from every session; a refusal is
   *  returned rather than thrown so the mux can ANSWER the sender: an app binds
   *  a `streamId` it read off the `agent:projects` advert without a fresh
   *  `project:start`, so the refusal that verb would have given it is never
   *  reached and silence leaves it rendering an empty project forever.
   *  `null` peer = a frame whose session we cannot resolve. */
  mayAcceptFrom?: (peer: PeerSessionView | null) => StreamRefusal | null;
}

/** The slice of the machine's native peer-session owner that the mux drives.
 *  Kept minimal so the mux is unit-testable against a stub. */
export interface StreamMuxTransport {
  closeStream(streamId: string): void;
  /** Seal + fragment + send one stream-tagged app envelope on `channel`, once
   *  per session `target` selects (absent = every established session).
   *  Resolves when the message left the send queue. */
  sendEnvelope(
    streamId: string,
    msg: unknown,
    channel: Channel,
    target?: SendTarget,
    signal?: AbortSignal,
    authorized?: () => boolean,
  ): Promise<SendOutcome>;
  /** What the machine knows about one app session, or null for a route id that
   *  holds none. The mux needs it to apply a stream's per-device filters to a
   *  peer-addressed send and to an inbound frame, both of which name a session
   *  rather than enumerate them. */
  peerSession(peerId: string): PeerSessionView | null;
  /** A2: routes one outbound terminal-stream message, replacing `sendEnvelope`
   *  for it when present. `undefined` (no terminal registry, or the message is
   *  unbound) falls back to the legacy session-stream path — see `attach()`'s
   *  subscriber. Absent entirely on a transport with no terminal streams. */
  routeTerminal?(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined;
  /** Forwarded onto every `StreamHandle` this transport backs (A2). */
  readonly terminalHooks?: TerminalStreamHooks;
  /** A project's last live mux entry detached: unbind every terminal stream
   *  still bound to it, because their bus is now gone. Absent on a transport
   *  with no terminal streams. */
  projectDetached?(projectId: string): void;
}

interface StreamEntry {
  bus: MessageBus;
  unsub: () => void;
  opts: AttachStreamOpts;
  /** The app answered `stream-unbound` for this id: it holds no transport, so
   *  every frame we push is discarded on arrival. Muted rather than detached —
   *  the core stays running for its loopback owner, the advert stays dialable,
   *  and a re-open reuses this same id (host-server publishes `stream-ready`
   *  with the recorded streamId), so tearing the stream down here would break
   *  the very reconnect that heals it. */
  unboundAtPeer: boolean;
}

/**
 * Multiplexes host-owned project streams over established native peer sessions.
 * The mux allocates opaque local IDs, tags outbound bus traffic, and routes
 * inbound `{s, m}` envelopes to the owning project bus. Machine control traffic
 * (`s` omitted / `"0"`) is handled by the peer-session owner, never here. */
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
    const streamId = opts.streamId ?? randomBytes(8).toString("hex");
    if (!/^[0-9a-f]{16}$/.test(streamId) || this.streams.has(streamId)) {
      throw new Error("Invalid or duplicate project stream id");
    }
    // Gate at the send, not at attach/detach: the stream stays open and the core
    // keeps running, so flipping the switch back on resumes delivery with no
    // re-attach and no lost core. Dropping mid-flight can strand an RPC the phone
    // is awaiting — acceptable, since the same switch already refuses its next
    // request; the app times that out and resyncs from a snapshot.
    const mayDeliver = () => opts.mayDeliver?.() ?? true;
    // The per-receiver mute applies to a peer-addressed send too. Being the
    // session that asked is not an admission — a bus verb can reply straight to
    // its asker, and a device that cannot address a checkout would read an
    // isolated session's data as the main worktree's whether it asked for it or
    // not. `null` = nothing to send to; the caller drops.
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
      unboundAtPeer: false,
    };
    entry.unsub = bus.subscribe({
      // This stream IS the relay wire, so an audience-targeted publish meant
      // for the desktop's loopback socket must not be enveloped onto it.
      audience: "relay",
      deliver: (msg, channel, signal, peerId) => {
        // Ahead of mayDeliver: a stream nobody is receiving is not an
        // authorization question, and the switch is the more expensive read.
        const requested: SendTarget | undefined = peerId ? { kind: "peer", peerId } : undefined;
        const canSend = () => !entry.unboundAtPeer && mayDeliver() && gated(requested) !== null;
        if (!canSend()) {
          if (signal && !signal.aborted) return Promise.reject(new Error("Terminal delivery gated"));
          return;
        }
        // A2: a terminal-bound message routes onto its own stream instead of
        // this project stream's envelope. `mayDeliver`/`mayDeliverTo`/`gated`
        // above (and `unboundAtPeer`) still gate it at enqueue time; the
        // writer's `authorized()` rechecks remote access per record.
        const routed = peerId ? this.transport.routeTerminal?.(peerId, msg, signal) : undefined;
        const sent = routed ?? this.transport.sendEnvelope(streamId, msg, channel, gated(requested)!, signal, canSend);
        if (signal) return sent.then((outcome) => {
          if (outcome !== "sent" && !signal.aborted) throw new Error(`Terminal delivery ${outcome}`);
        });
        void sent;
      },
    });
    this.streams.set(streamId, entry);
    opts.onLocalReady?.(streamId);
    opts.onAdmitted?.(streamId);
    // A stream attached while the session is already established (drill-in) never
    // sees a fresh peer-online, so resume it now.
    if (this.peerOnline) opts.onPeerOnline?.();
    return {
      streamId,
      detach: () => this.detach(streamId),
      sendTo: (msg, channel, target) => sendTo(msg, channel, target),
      terminalHooks: this.transport.terminalHooks,
    };
  }

  private detach(streamId: string): void {
    const entry = this.streams.get(streamId);
    if (!entry) return;
    this.streams.delete(streamId);
    try { entry.unsub(); } catch { /* bus already gone */ }
    this.transport.closeStream(streamId);
    const projectId = entry.opts.projectId;
    if (projectId !== undefined && !this.hasLiveEntryFor(projectId)) {
      this.transport.projectDetached?.(projectId);
    }
  }

  /** The most recently attached live entry bound to `projectId`, or null.
   *  Lookup only — never opens or promotes a core (A2, `TerminalStreamRegistry`
   *  admission step 5). Iterates newest-first: `Map` preserves insertion order,
   *  and a project can hold more than one live entry only across a reconnect
   *  race the mux does not otherwise resolve, so the latest one wins. */
  projectBinding(projectId: string): TerminalProjectBinding | null {
    let found: { streamId: string; entry: StreamEntry } | null = null;
    for (const [streamId, entry] of this.streams) {
      if (entry.opts.projectId === projectId) found = { streamId, entry };
    }
    if (!found) return null;
    const { streamId } = found;
    return {
      streamId,
      refusalFor: (peerId) => {
        const entry = this.streams.get(streamId);
        if (!entry) return { code: "NOT_ALLOWED", message: "project stream is gone" };
        return entry.opts.mayAcceptFrom?.(this.transport.peerSession(peerId)) ?? null;
      },
      dispatch: (msg, peerId) => {
        const entry = this.streams.get(streamId);
        if (!entry) return false;
        const refusal = entry.opts.mayAcceptFrom?.(this.transport.peerSession(peerId)) ?? null;
        if (refusal) return false;
        if (entry.unboundAtPeer) this.markBound(streamId);
        entry.bus.dispatchInbound(msg, "control", "relay", peerId);
        return true;
      },
    };
  }

  /** Same lookup as {@link projectBinding}, for a tunnel stream's admission and
   *  delivery instead of the bus's. No `dispatch`: a tunnel stream carries no
   *  bus traffic, so `TunnelStreamRegistry` never calls back through the mux to
   *  route one — it owns the stream outright once admitted. */
  tunnelBinding(projectId: string): TunnelProjectBinding | null {
    let found: { streamId: string; entry: StreamEntry } | null = null;
    for (const [streamId, entry] of this.streams) {
      if (entry.opts.projectId === projectId) found = { streamId, entry };
    }
    if (!found) return null;
    const { streamId } = found;
    return {
      streamId,
      refusalFor: (peerId) => {
        const entry = this.streams.get(streamId);
        if (!entry) return { code: "NOT_ALLOWED", message: "project stream is gone" };
        return entry.opts.mayAcceptFrom?.(this.transport.peerSession(peerId)) ?? null;
      },
      mayDeliverTo: (peerId) => {
        const entry = this.streams.get(streamId);
        if (!entry) return false;
        if (!(entry.opts.mayDeliver?.() ?? true)) return false;
        if (!entry.opts.mayDeliverTo) return true;
        const peer = this.transport.peerSession(peerId);
        return peer !== null && entry.opts.mayDeliverTo(peer);
      },
      tunnels: () => {
        const entry = this.streams.get(streamId);
        return entry?.opts.tunnels ?? null;
      },
    };
  }

  /** Whether any live entry is still bound to `projectId` — used only to decide
   *  whether a detach was the LAST one for that project (§3.3). */
  private hasLiveEntryFor(projectId: string): boolean {
    for (const entry of this.streams.values()) {
      if (entry.opts.projectId === projectId) return true;
    }
    return false;
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
    if (msg) entry.bus.dispatchInbound(msg, channel, "relay", peerId);
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

  /** Tear every stream down (socket close / client shutdown). */
  detachAll(): void {
    for (const streamId of [...this.streams.keys()]) this.detach(streamId);
  }
}

export { CONTROL_STREAM_ID };
