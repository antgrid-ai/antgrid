/**
 * Project streams (docs/iroh-reduction/stage-A-A4-contract.md §3.1-§3.3 and
 * stage-A-A5-contract.md §3.3). Every project gets its own QUIC bidi stream per
 * app peer: after the A0b open frame `{kind:"project", projectId}`, each record is
 * the bare UTF-8 JSON of exactly one `AbMessage` — one message is always one
 * record, with no `{"__frag":…}` splitting and no `{s, m}` envelope. Machine
 * control traffic (`s` omitted / `"0"`) never reaches this file.
 *
 * This registry is plugged into `PeerStreamAcceptor` as the `project`
 * handler, and into `TerminalStreamRegistry`/`TunnelStreamRegistry` as
 * `projectBinding`/`tunnelBinding` (A2/A3): those never open or promote a
 * core, only look up whatever this registry already has attached.
 */

import {
  MAX_TRANSFER_BYTES,
  STREAM_MAX_PROJECTS_PER_PEER,
  STREAM_PROJECT_APP_RECORD_MAX_BYTES,
  type ProjectStreamOpen,
} from "antgrid-wire";
import { isSafeProjectId } from "./project-id";
import { createMessage, parseMessageFast, type AbMessage } from "./protocol";
import type { Channel, MessageBus } from "./message-bus";
import type { TunnelStreamServer } from "./tunnel-manager";
import type { netwatch } from "./netwatch";
import {
  StreamRecordReader,
  StreamRecordWriter,
  type SendOutcome,
  type StreamSendOutcome,
  type StreamWriteFailure,
} from "./peer/stream-records";
import type {
  AcceptedBiStream,
  StreamAdmission,
  StreamHandler,
  StreamRefusal as DispatchStreamRefusal,
} from "./peer/stream-dispatch";

/** A stream carrying what its per-recipient queue held for a project's whole
 *  session-stream lifetime (§2): the same cap the old scheduler applied. */
export const PROJECT_STREAM_MAX_QUEUED_BYTES = 67_108_864;
/** Below the session stream's binding default of 0? No — the session stream
 *  carries no binding priority of its own; this sits below terminal streams
 *  (1) and above tunnel streams (-1), as `terminal-streams.ts` requires. */
export const STREAM_PRIORITY_PROJECT = 0;
// Reset/stop codes are bridge diagnostics only — Dart cannot read them back.
export const STREAM_RESET_PROJECT = 0x17n;
export const STREAM_STOP_PROJECT = 0x18n;

/** One `control:result` refusal notice per dead (peer, project) pair per this
 *  window: a stale app replays a burst of verbs, and one notice is enough for
 *  it to stop. */
export const INVALID_NOTICE_COOLDOWN_MS = 5_000;
/** How long a refused pair stays in the rate-limit map. */
export const INVALID_NOTICE_TTL_MS = 60_000;

const textEncoder = new TextEncoder();

/** A project's attachment to the registry. `detach()` releases it. Terminal
 *  and tunnel traffic never ride this handle (A2/A3): they hold their own
 *  QUIC streams, admitted through {@link TerminalProjectBinding} and
 *  {@link TunnelProjectBinding}. */
export interface StreamHandle {
  detach(): void;
  /** "gated" when the switch or the receiver mute says no; "dropped" when the
   *  target peer holds no open project stream for this project; "too-large"
   *  past MAX_TRANSFER_BYTES; else the writer's outcome. `channel` is ignored
   *  natively (§1.1). */
  sendTo(msg: unknown, channel: Channel, target: SendTarget): Promise<SendOutcome>;
  /** True iff `peerId` holds an open project stream for this project AND
   *  mayDeliver() AND mayDeliverTo(peerSession(peerId)). Synchronous — what
   *  `ProjectCore.sendToAppSession` returns. */
  deliverableTo(peerId: string): boolean;
  readonly terminalHooks?: TerminalStreamHooks;
}

/** Delivered to whichever core owns a terminal stream's bound project, so it
 *  can react to a native attachment's lifecycle the same way it reacts to the
 *  loopback and legacy session-stream paths. See `peer/terminal-streams.ts`. */
export interface TerminalStreamHooks {
  retired(peerId: string, attachmentId: string): void;
  subscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void;
}

/** What `TerminalStreamRegistry` needs from a project's entry to admit and
 *  route a terminal stream without opening or promoting a core itself (A2). */
export interface TerminalProjectBinding {
  /** The peer holds an open project stream for this project (A4's single
   *  per-peer admission point, root CLAUDE.md's checkout-routing invariant). */
  hasOpenStream(peerId: string): boolean;
  /** `entry.opts.mayAcceptFrom(peerSession(peerId))`, re-read on every call —
   *  the same per-sender gate `dispatch` applies. */
  refusalFor(peerId: string): StreamRefusal | null;
  /** Re-runs `refusalFor`, then `entry.bus.dispatchInbound(msg, "control",
   *  "relay", peerId)`. False when the entry has gone or `refusalFor` now
   *  refuses. Does NOT require an open project stream (no cascade, §0). */
  dispatch(msg: AbMessage, peerId: string): boolean;
}

/** What `TunnelStreamRegistry` needs from a project's entry to admit and
 *  route a tunnel stream without opening or promoting a core itself (A3). A
 *  tunnel stream carries no bus traffic, so unlike {@link TerminalProjectBinding}
 *  it has no `dispatch` — only the per-sender gate and the project's own
 *  {@link TunnelStreamServer}, which the registry calls to admit the stream. */
export interface TunnelProjectBinding {
  hasOpenStream(peerId: string): boolean;
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
 *  app device, so every send either fans out (optionally filtered per
 *  receiver) or names the single session that asked. */
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
  /** The project this stream carries, named on a refusal so the app can fail
   *  the exact bind it is waiting on instead of guessing. */
  projectId?: string;
  /** Host-local binding is ready for native peer sessions. Fired synchronously
   *  inside `attach()`. */
  onAdmitted?: () => void;
  /** A native app session was established. Also fired at attach time when a
   *  session is already established, so a drill-in stream resumes immediately. */
  onPeerOnline?: () => void;
  onPeerOffline?: () => void;
  /** One app session ended (liveness, presence, eviction, socket close) while
   *  others may still be attached. Distinct from `onPeerOffline`, which fires
   *  only when the LAST session is gone. */
  onPeerSessionGone?: (peerId: string) => void;
  /** This peer's project stream for THIS project ended while its session
   *  lives on: the app closed it (FIN or reset), or it overflowed or was lost
   *  (D3). Not fired by `detach()` or `dropPeer()`. */
  onPeerStreamClosed?: (peerId: string) => void;
  /** The project's tunnel server; absent => tunnel streams for this project
   *  are refused NOT_ALLOWED. */
  tunnels?: TunnelStreamServer;
  /** Outbound authorization: consulted on EVERY frame this stream would send.
   *  Read live so a `mobile-access:set` takes effect without tearing the
   *  stream down. Absent = always deliver. */
  mayDeliver?: () => boolean;
  /** Per-RECEIVER half of the same gate, consulted once per attached session —
   *  on a broadcast AND on a peer-addressed send. Absent = deliver to every
   *  session. */
  mayDeliverTo?: (peer: PeerSessionView) => boolean;
  /** Per-SENDER mirror of {@link mayDeliverTo}, consulted at open and on every
   *  inbound record. `null` peer = a frame whose session we cannot resolve. */
  mayAcceptFrom?: (peer: PeerSessionView | null) => StreamRefusal | null;
}

export interface ProjectStreamRegistryOptions {
  /** Fail closed: absent => every open is refused NOT_ALLOWED. */
  remoteAccessEnabled?: () => boolean;
  /** host-server `seenProjects.has`. Absent => NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  peerSession(peerId: string): PeerSessionView | null;
  /** Peer-addressed control-plane send on the SESSION stream (the refused-
   *  sender `control:result` notice). */
  sendSessionMessage(peerId: string, msg: AbMessage): void;
  /** A message over `MAX_TRANSFER_BYTES` was refused locally, before any
   *  write: the same hook `PeerSessionOwner` reports its own session-stream
   *  refusals through. */
  onError?(code: string, message: string): void;
  /** Retires the whole connection. Only "unauthorized" (writer) or
   *  "protocol-violation" (reader prefix). */
  retirePeer(peerId: string, reason: "unauthorized" | "protocol-violation"): void;
  /** A2 routing, unchanged: a terminal-bound message for `peerId` goes to its
   *  terminal stream. `undefined` falls back to that peer's PROJECT stream
   *  (was: the session stream). */
  routeTerminal?(peerId: string, msg: AbMessage, signal?: AbortSignal): Promise<StreamSendOutcome> | undefined;
  terminalHooks?: TerminalStreamHooks;
  /** The project's last live entry detached (unchanged meaning). */
  projectDetached?(projectId: string): void;
  diagnostic?(event: Parameters<typeof netwatch.record>[0]): void;
  now?: () => number;
}

interface Entry {
  bus: MessageBus;
  unsub: () => void;
  opts: AttachStreamOpts;
  /** Bindings currently attached to THIS entry. A binding stays here until it
   *  is unbound, even after a newer entry for the same projectId replaces
   *  this one as the admission target ("newest wins", §3.1). */
  bindings: Set<Binding>;
}

interface Binding {
  readonly peerId: string;
  readonly projectId: string;
  readonly entry: Entry;
  readonly stream: AcceptedBiStream;
  readonly writer: StreamRecordWriter;
  readonly reader: StreamRecordReader;
  /** Removed from every index and its cap slot freed. The staleness guard
   *  every async step checks: once unbound, nothing may act on this binding
   *  again. */
  unbound: boolean;
}

/**
 * `(peerId, projectId) -> binding`, registered into `PeerStreamAcceptor`'s
 * handler table as `{ project: registry.handler }`.
 */
export class ProjectStreamRegistry {
  private readonly entries: Entry[] = [];
  private readonly bindings = new Map<string, Binding>();
  private readonly peerBindings = new Map<string, Set<Binding>>();
  /** Last broadcast peer state, so an entry attached mid-session inherits it. */
  private peerOnline = false;
  private readonly noticeSentAt = new Map<string, number>();
  private readonly now: () => number;

  constructor(private readonly opts: ProjectStreamRegistryOptions) {
    this.now = opts.now ?? Date.now;
  }

  readonly handler: StreamHandler<ProjectStreamOpen> = (admission) => this.admit(admission);

  // ---- Attach / detach ------------------------------------------------------

  attach(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    const entry: Entry = { bus, unsub: () => {}, opts, bindings: new Set() };

    // Gate at the send, not at attach/detach: the stream stays open and the
    // core keeps running, so flipping the switch back on resumes delivery
    // with no re-attach and no lost core.
    const mayDeliver = () => opts.mayDeliver?.() ?? true;
    // The per-receiver mute applies to a peer-addressed send too — a bus verb
    // can reply straight to its asker, and a device that cannot route
    // checkouts would read an isolated session's data as main's whether it
    // asked for it or not. `null` = nothing to send to; the caller drops.
    const gatedTarget = (target?: SendTarget): SendTarget | null => {
      if (target?.kind !== "peer") {
        return { kind: "broadcast", where: bothOf(target?.where, opts.mayDeliverTo) };
      }
      if (!opts.mayDeliverTo) return target;
      const peer = this.opts.peerSession(target.peerId);
      return peer && opts.mayDeliverTo(peer) ? target : null;
    };
    const recipientsFor = (target: SendTarget): Binding[] => {
      if (target.kind === "peer") {
        for (const binding of entry.bindings) {
          if (binding.peerId === target.peerId && !binding.unbound) return [binding];
        }
        return [];
      }
      const out: Binding[] = [];
      for (const binding of entry.bindings) {
        if (binding.unbound) continue;
        const peer = this.opts.peerSession(binding.peerId);
        if (!peer) continue;
        if (target.where && !target.where(peer)) continue;
        out.push(binding);
      }
      return out;
    };
    const sendTo = (msg: unknown, _channel: Channel, target?: SendTarget): Promise<SendOutcome> => {
      if (!mayDeliver()) return Promise.resolve<SendOutcome>("gated");
      const to = gatedTarget(target);
      if (!to) return Promise.resolve<SendOutcome>("gated");
      const recipients = recipientsFor(to);
      if (recipients.length === 0) return Promise.resolve<SendOutcome>("dropped");
      return this.writeToRecipients(recipients, msg);
    };

    entry.unsub = bus.subscribe({
      // This stream IS the relay wire for this project, so an audience-
      // targeted publish meant for the desktop's loopback socket must not be
      // enveloped onto it.
      audience: "relay",
      deliver: (msg, _channel, signal, peerId) => {
        if (!mayDeliver()) {
          if (signal && !signal.aborted) return Promise.reject(new Error("Project delivery gated"));
          return;
        }
        const requested: SendTarget | undefined = peerId ? { kind: "peer", peerId } : undefined;
        const to = gatedTarget(requested);
        if (!to) {
          if (signal && !signal.aborted) return Promise.reject(new Error("Project delivery gated"));
          return;
        }
        // A2: a terminal-bound message routes onto its own stream instead of
        // this project stream. `mayDeliver`/`gatedTarget` above still gate it
        // at enqueue time; the writer's `authorized()` rechecks remote access
        // per record.
        const routed = peerId ? this.opts.routeTerminal?.(peerId, msg, signal) : undefined;
        const sent: Promise<SendOutcome> = routed ?? (async () => {
          const recipients = recipientsFor(to);
          if (recipients.length === 0) return "dropped" as SendOutcome;
          return this.writeToRecipients(recipients, msg, signal);
        })();
        if (signal) {
          return sent.then((outcome) => {
            if (outcome !== "sent" && !signal.aborted) throw new Error(`Project delivery ${outcome}`);
          });
        }
        void sent;
      },
    });

    this.entries.push(entry);
    opts.onAdmitted?.();
    // An entry attached while the session is already established (drill-in)
    // never sees a fresh peer-online, so resume it now.
    if (this.peerOnline) opts.onPeerOnline?.();

    return {
      detach: () => this.detach(entry),
      sendTo: (msg, channel, target) => sendTo(msg, channel, target),
      deliverableTo: (peerId) => this.deliverableTo(entry, peerId),
      terminalHooks: this.opts.terminalHooks,
    };
  }

  private deliverableTo(entry: Entry, peerId: string): boolean {
    if (!(entry.opts.mayDeliver?.() ?? true)) return false;
    for (const binding of entry.bindings) {
      if (binding.peerId !== peerId || binding.unbound) continue;
      if (!entry.opts.mayDeliverTo) return true;
      const peer = this.opts.peerSession(peerId);
      return peer !== null && entry.opts.mayDeliverTo(peer);
    }
    return false;
  }

  private detach(entry: Entry): void {
    const idx = this.entries.indexOf(entry);
    if (idx === -1) return;
    this.entries.splice(idx, 1);
    try { entry.unsub(); } catch { /* bus already gone */ }
    for (const binding of [...entry.bindings]) {
      this.unbind(binding);
      void binding.writer.finish();
      void binding.stream.recv.stop(STREAM_STOP_PROJECT).catch(() => {});
    }
    const projectId = entry.opts.projectId;
    if (projectId !== undefined && !this.hasLiveEntryFor(projectId)) {
      this.opts.projectDetached?.(projectId);
    }
  }

  private hasLiveEntryFor(projectId: string): boolean {
    for (const entry of this.entries) {
      if (entry.opts.projectId === projectId) return true;
    }
    return false;
  }

  /** The most recently attached live entry bound to `projectId`, or null.
   *  Lookup only — never opens or promotes a core. Iterates newest-first
   *  semantics via last-match: a project can hold more than one live entry
   *  only across a reconnect race, so the latest one wins for a fresh open. */
  private latestEntryFor(projectId: string): Entry | null {
    let found: Entry | null = null;
    for (const entry of this.entries) {
      if (entry.opts.projectId === projectId) found = entry;
    }
    return found;
  }

  // ---- Outbound write --------------------------------------------------------

  /** Encodes `msg` once, then queues it on every recipient's writer before
   *  awaiting any of them: awaiting per recipient would let one slow peer
   *  hold up every other peer's copy. "sent" only once every recipient wrote
   *  it; any other outcome makes the whole call "dropped". A message over the
   *  sender's cap is refused before any writer is reached; one `AbMessage` is
   *  always exactly one record. */
  private async writeToRecipients(recipients: Binding[], msg: unknown, signal?: AbortSignal): Promise<SendOutcome> {
    const type = (msg as { type?: string } | null)?.type;
    const json = JSON.stringify(msg);
    const bytes = Buffer.byteLength(json, "utf8");
    if (bytes > MAX_TRANSFER_BYTES) {
      const message = `${type ?? "message"} exceeds MAX_TRANSFER_BYTES`;
      this.opts.onError?.("MESSAGE_TOO_LARGE", message);
      this.opts.diagnostic?.({
        dir: "tx", kind: "drop", transport: "iroh", channel: "control",
        msgType: type, reason: "MESSAGE_TOO_LARGE", detail: { bytes },
      });
      return "too-large";
    }
    const frame = textEncoder.encode(json);
    const outcomes = await Promise.all(recipients.map((binding) => binding.writer.send(frame, signal)));
    return outcomes.every((outcome) => outcome === "sent") ? "sent" : "dropped";
  }

  // ---- Admission (synchronous, before any read) -----------------------------

  /** Every check is synchronous and runs before any read is issued on `recv`:
   *  a handler that has started its read loop never returns a refusal again.
   *  The open never opens or promotes a core — step 5 is a lookup only over
   *  whatever `project:start` (or a desktop promotion) already attached. */
  private admit(admission: StreamAdmission<ProjectStreamOpen>): DispatchStreamRefusal | undefined {
    const { peerId, open, stream, authorized } = admission;
    const { projectId } = open;

    if (this.openStreamCount(peerId) >= STREAM_MAX_PROJECTS_PER_PEER) {
      return { code: "CAP_EXCEEDED", message: "too many project streams" };
    }
    if (!isSafeProjectId(projectId)) {
      return { code: "NOT_ALLOWED", message: "unsafe project id" };
    }
    if (!(this.opts.remoteAccessEnabled?.() ?? false)) {
      return { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" };
    }
    if (!(this.opts.projectCataloged?.(projectId) ?? false)) {
      return { code: "NOT_ALLOWED", message: "project not recognized" };
    }
    const entry = this.latestEntryFor(projectId);
    if (entry === null) {
      // Hazard J: the core is not relay-registered yet. The app waits for the
      // ready notice on the session stream and opens again.
      return { code: "NOT_READY", message: "project is not ready; wait for stream-ready" };
    }
    if (!(entry.opts.mayDeliver?.() ?? true)) {
      return { code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" };
    }
    const refusal = entry.opts.mayAcceptFrom?.(this.opts.peerSession(peerId)) ?? null;
    if (refusal) {
      return refusal.code === "UPDATE_REQUIRED"
        ? { code: "UPDATE_REQUIRED", message: refusal.message }
        : { code: "NOT_ALLOWED", message: refusal.message };
    }
    if (this.bindings.has(this.key(peerId, projectId))) {
      return { code: "INVALID", message: "project stream already open" };
    }

    // `binding` is referenced by the writer/reader failure closures below
    // before it is assigned; both only ever run after `admit` has returned.
    let binding!: Binding;
    const writer = new StreamRecordWriter(
      stream,
      authorized,
      (reason) => this.onWriterFailure(binding, reason),
      PROJECT_STREAM_MAX_QUEUED_BYTES,
      STREAM_PRIORITY_PROJECT,
      STREAM_RESET_PROJECT,
    );
    const reader = new StreamRecordReader(
      stream,
      STREAM_PROJECT_APP_RECORD_MAX_BYTES,
      () => { if (!binding.unbound) this.opts.retirePeer(peerId, "protocol-violation"); },
    );
    binding = { peerId, projectId, entry, stream, writer, reader, unbound: false };
    this.bind(binding);
    // The bind is complete once this is written — the app treats its project
    // stream as bound only once this first record arrives (D-1).
    void writer.send(textEncoder.encode(JSON.stringify(createMessage("stream-ready", { projectId }))));
    void this.runLoop(binding);
    return undefined;
  }

  // ---- Binding lifecycle ------------------------------------------------------

  private async runLoop(binding: Binding): Promise<void> {
    for (;;) {
      let bytes: Uint8Array;
      try {
        bytes = await binding.reader.read();
      } catch {
        // A StreamProtocolViolation already retired the connection through the
        // reader's own onFailure, which unbinds this peer's bindings via
        // dropPeer — so by the time we get here `unbound` is already true for
        // that case, and this branch only ever does real work for the app's
        // own FIN/reset.
        if (!binding.unbound) this.handleAppEnd(binding);
        return;
      }
      if (binding.unbound) {
        void binding.stream.recv.stop(STREAM_STOP_PROJECT).catch(() => {});
        return;
      }
      const text = Buffer.from(bytes).toString("utf-8");
      this.dispatchJson(binding, text);
    }
  }

  /** §3.2 inbound steps 3-5: parse, re-check the per-sender gate, dispatch. */
  private dispatchJson(binding: Binding, json: string): void {
    if (binding.unbound) return;
    const msg = parseMessageFast(json);
    if (!msg) {
      this.opts.diagnostic?.({
        dir: "rx", kind: "drop", transport: "iroh", channel: "control",
        reason: "not-ab-message",
      });
      return;
    }
    const refusal = binding.entry.opts.mayAcceptFrom?.(this.opts.peerSession(binding.peerId)) ?? null;
    if (refusal) {
      this.notifyRefused(binding.peerId, binding.projectId, refusal);
      return;
    }
    binding.entry.bus.dispatchInbound(msg, "control", "relay", binding.peerId);
  }

  /** Tell one session why its records are being dropped. Addressed, because a
   *  healthy sibling banner-ing someone else's UPDATE_REQUIRED is worse than
   *  the silence this replaces. Rate-limited per (peer, project). */
  private notifyRefused(peerId: string, projectId: string, refusal: StreamRefusal): void {
    if (!this.noticeDue(`${peerId}\u0000${projectId}`)) return;
    this.opts.sendSessionMessage(peerId, createMessage("control:result", {
      ok: false,
      projectId,
      error: { code: refusal.code, message: refusal.message },
    }));
  }

  /** Rate limit for the refused-sender notice, swept so a long-lived host
   *  can't accumulate an entry per stale pair. */
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

  /** The app's FIN or a read rejection (reset): unbind, FIN our own half,
   *  fire `onPeerStreamClosed` so the owner can react (e.g. drop a focus
   *  claim). */
  private handleAppEnd(binding: Binding): void {
    this.unbind(binding);
    void binding.writer.finish();
    binding.entry.opts.onPeerStreamClosed?.(binding.peerId);
  }

  private onWriterFailure(binding: Binding, reason: StreamWriteFailure): void {
    if (binding.unbound) return;
    if (reason === "unauthorized") {
      this.opts.retirePeer(binding.peerId, "unauthorized");
      return;
    }
    // "overflow" or "stream-lost": the writer has already reset its own half.
    // Only this stream resets (D3) — the app reopens and resyncs through
    // state.snapshot.
    this.unbind(binding);
    void binding.stream.recv.stop(STREAM_STOP_PROJECT).catch(() => {});
    binding.entry.opts.onPeerStreamClosed?.(binding.peerId);
  }

  /** The peer's session or connection is gone: abort without dispatching
   *  anything — there is nobody left to receive a reaction. No hooks: the
   *  owner's own `onPeerSessionGone`/`onPeerOffline` fire from `dropSession`. */
  dropPeer(peerId: string): void {
    const set = this.peerBindings.get(peerId);
    if (!set) return;
    for (const binding of [...set]) {
      binding.writer.abort();
      void binding.stream.recv.stop(STREAM_STOP_PROJECT).catch(() => {});
      this.unbind(binding);
    }
  }

  // ---- Coarse peer presence ---------------------------------------------------

  notifyPeerOnline(): void {
    if (this.peerOnline) return;
    this.peerOnline = true;
    for (const entry of this.entries) entry.opts.onPeerOnline?.();
  }

  notifyPeerOffline(): void {
    if (!this.peerOnline) return;
    this.peerOnline = false;
    for (const entry of this.entries) entry.opts.onPeerOffline?.();
  }

  notifyPeerSessionOffline(peerId: string): void {
    for (const entry of this.entries) entry.opts.onPeerSessionGone?.(peerId);
  }

  // ---- Lookups for terminal/tunnel admission ----------------------------------

  projectBinding(projectId: string): TerminalProjectBinding | null {
    const entry = this.latestEntryFor(projectId);
    if (!entry) return null;
    const live = () => this.entries.includes(entry);
    return {
      hasOpenStream: (peerId) => this.hasOpenStream(peerId, projectId),
      refusalFor: (peerId) => {
        if (!live()) return { code: "NOT_ALLOWED", message: "project stream is gone" };
        return entry.opts.mayAcceptFrom?.(this.opts.peerSession(peerId)) ?? null;
      },
      dispatch: (msg, peerId) => {
        if (!live()) return false;
        const refusal = entry.opts.mayAcceptFrom?.(this.opts.peerSession(peerId)) ?? null;
        if (refusal) return false;
        entry.bus.dispatchInbound(msg, "control", "relay", peerId);
        return true;
      },
    };
  }

  tunnelBinding(projectId: string): TunnelProjectBinding | null {
    const entry = this.latestEntryFor(projectId);
    if (!entry) return null;
    const live = () => this.entries.includes(entry);
    return {
      hasOpenStream: (peerId) => this.hasOpenStream(peerId, projectId),
      refusalFor: (peerId) => {
        if (!live()) return { code: "NOT_ALLOWED", message: "project stream is gone" };
        return entry.opts.mayAcceptFrom?.(this.opts.peerSession(peerId)) ?? null;
      },
      mayDeliverTo: (peerId) => {
        if (!live()) return false;
        if (!(entry.opts.mayDeliver?.() ?? true)) return false;
        if (!entry.opts.mayDeliverTo) return true;
        const peer = this.opts.peerSession(peerId);
        return peer !== null && entry.opts.mayDeliverTo(peer);
      },
      tunnels: () => (live() ? entry.opts.tunnels ?? null : null),
    };
  }

  hasOpenStream(peerId: string, projectId: string): boolean {
    const binding = this.bindings.get(this.key(peerId, projectId));
    return binding !== undefined && !binding.unbound;
  }

  openStreamCount(peerId: string): number {
    return this.peerBindings.get(peerId)?.size ?? 0;
  }

  /** Tear every entry down (socket close / client shutdown). */
  detachAll(): void {
    for (const entry of [...this.entries]) this.detach(entry);
  }

  // ---- Indexing ----------------------------------------------------------------

  private bind(binding: Binding): void {
    this.bindings.set(this.key(binding.peerId, binding.projectId), binding);
    binding.entry.bindings.add(binding);
    let set = this.peerBindings.get(binding.peerId);
    if (!set) {
      set = new Set();
      this.peerBindings.set(binding.peerId, set);
    }
    set.add(binding);
  }

  /** Removes both index entries and frees the cap slot exactly once. */
  private unbind(binding: Binding): void {
    if (binding.unbound) return;
    binding.unbound = true;
    this.bindings.delete(this.key(binding.peerId, binding.projectId));
    binding.entry.bindings.delete(binding);
    const set = this.peerBindings.get(binding.peerId);
    if (set) {
      set.delete(binding);
      if (set.size === 0) this.peerBindings.delete(binding.peerId);
    }
  }

  private key(peerId: string, projectId: string): string {
    return `${peerId}\u0000${projectId}`;
  }
}
