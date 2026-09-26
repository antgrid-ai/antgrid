import { z } from "zod";
import { PEER_ALPN, PEER_MAX_RECORD_BYTES, STREAM_MAX_BIDI_STREAMS_PER_CONNECTION, decodePeerFrame, encodePeerFrame, type PeerFrameKind } from "antgrid-wire";
import type { Connection, Endpoint, Incoming } from "@number0/iroh";
import { CentralControlClient, type CentralControlOptions } from "../central-control-client";
import { baseSlotDeviceId } from "../relay-slot";
import type { AttachStreamOpts, StreamHandle } from "../project-streams";
import type { SessionHello } from "../protocol";
import { AuthorizationLease, type EnrollmentIdentity, type LeaseFailure } from "./authorization-lease";
import { EndpointApiError, EndpointEnrollment } from "./enrollment";
import { PeerSessionOwner, type PeerSessionOwnerOptions, MAX_APP_SESSIONS } from "../peer-session-owner";
import { EndpointLifecycle, EndpointFailure } from "./endpoint-lifecycle";
import type { RemoteHostConnection } from "../remote-host-connection";
import { frameIdFor, NETWATCH_SESSION_STREAM_LABEL } from "../netwatch";
import { AdmissionRegistry, type AdmissionReservation } from "./admission-registry";
import { PeerStreamAcceptor, readStreamOpen } from "./stream-dispatch";
import { TerminalStreamRegistry } from "./terminal-streams";
import { TunnelStreamRegistry } from "./tunnel-streams";
import { UploadStreamRegistry } from "./upload-streams";
import type { AbMessage } from "../protocol";
import { StreamRecordWriter, StreamRecordReader, StreamProtocolViolation, type PeerRecordFailure, type StreamSendOutcome } from "./stream-records";

/** Fits two max-size control-plane records; the same per-stream bound as
 *  `PROJECT_STREAM_MAX_QUEUED_BYTES` (`project-streams.ts`). */
const SESSION_STREAM_MAX_QUEUED_BYTES = 67_108_864;
/** Above terminal (1), project (0) and tunnel (-1): liveness frames must not
 *  wait behind bulk. */
const STREAM_PRIORITY_SESSION = 2;
/** The next free reset code after `STREAM_STOP_PROJECT` (`project-streams.ts`). */
const STREAM_RESET_SESSION = 0x19n;

export interface NativePeerOptions extends PeerSessionOwnerOptions {
  enrollment: EnrollmentIdentity;
  endpointSecret: string;
  licenseApiUrl: string;
  getLicenseToken: () => Promise<string> | string;
  remoteAccessEnabled: () => boolean;
  /** `HostServer.seenProjects.has`, threaded through to `TerminalStreamRegistry`
   *  (A2) and `TunnelStreamRegistry` (A3). Absent fails every terminal- or
   *  tunnel-stream open closed, `NOT_ALLOWED`. */
  projectCataloged?: (projectId: string) => boolean;
  lifecycle?: {
    now?: () => number;
    random?: () => number;
    schedule?: (callback: () => void, ms: number) => () => void;
  };
}

export interface NativeHostOptions {
  central: CentralControlOptions;
  native: NativePeerOptions;
}

export function evalIrohBindAddress(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  const value = env.ANTGRID_EVAL_TEST === "1" ? env.ANTGRID_EVAL_IROH_BIND_ADDR : undefined;
  if (!value) return undefined;
  if (!/^127\.0\.0\.1:(?:[1-9][0-9]{0,4})$/.test(value) || Number(value.slice(10)) > 65_535) {
    throw new EndpointFailure("INVALID_EVAL_BIND_ADDR", true);
  }
  return value;
}

// A stock relay has no per-account registry, so any admitted or revoked
// endpoint can loop dials against this bridge's endpoint id; each dial that
// reaches the lease refresh is a web DB transaction. Bounding it per
// endpoint id (not globally) keeps two legitimately concurrent devices from
// throttling each other, while still capping a single looping identity.
const UNKNOWN_ENDPOINT_REFRESH_WINDOW_MS = 5_000;
const MAX_UNKNOWN_ENDPOINT_ENTRIES = 256;

/** How long an accepted connection may stay without an established session. */
const HELLO_TIMEOUT_MS = 30_000;

interface NativePeerContext {
  connection: Connection;
  endpointId: string;
  registrationGeneration: string;
  attemptGeneration: number;
  sessionGeneration: number;
  sessionWriter?: StreamRecordWriter;
  streams?: PeerStreamAcceptor;
  cancelHelloTimer?: () => void;
  helloAttemptId?: string;
  retired: boolean;
  acceptedAt: number;
}

/** Central inventory and native payloads share host-owned project bindings. */
export class NativePeerSessions extends PeerSessionOwner {
  private readonly nativePeers = new Map<string, NativePeerContext>();
  private readonly unknownEndpointRefreshAt = new Map<string, number>();
  private readonly lifecycle: EndpointLifecycle<Endpoint>;
  private readonly admissions = new AdmissionRegistry(4);
  private readonly enrollment: EndpointEnrollment;
  private readonly terminalStreams: TerminalStreamRegistry;
  private readonly tunnelStreams: TunnelStreamRegistry;
  private readonly uploadStreams: UploadStreamRegistry;
  private readonly lease: AuthorizationLease;
  private lifetime = 0;
  private stopped = false;
  private admissionGeneration = 0;
  private peerAttemptGeneration = 0;
  private peerSessionGeneration = 0;
  private approvedRelays = "";
  private closing: Promise<void> | null = null;

  constructor(private readonly nativeOpts: NativePeerOptions) {
    super(nativeOpts);
    if (!nativeOpts.identity.ed25519PrivateKey) throw new Error("Endpoint enrollment requires device identity");
    this.lifecycle = new EndpointLifecycle({
      create: () => this.startEndpoint(),
      listen: (endpoint) => this.acceptConnections(endpoint, this.lifetime),
      retire: async (endpoint) => {
        this.lifetime++;
        this.dropAllPeers("connection-lost");
        await endpoint.close();
      },
      terminal: (error) => error instanceof EndpointFailure && error.terminal ||
        error instanceof z.ZodError || error instanceof EndpointApiError && [401, 403, 409].includes(error.status),
      changed: (state, reason, detail) => this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh",
        msgType: "peer:endpoint-state", detail: {
          state,
          ...(reason ? { reason } : {}),
          ...detail,
          leaseRemainingMs: this.lease?.remainingMs ?? 0,
        } }),
      ...nativeOpts.lifecycle,
    });
    this.enrollment = new EndpointEnrollment(nativeOpts.enrollment, nativeOpts.endpointSecret,
      nativeOpts.identity.ed25519PrivateKey, nativeOpts.licenseApiUrl, nativeOpts.getLicenseToken);
    this.lease = new AuthorizationLease(nativeOpts.enrollment, async () => {
      try { return await this.enrollment.authorization(); }
      catch (error) {
        if (error instanceof EndpointApiError && (error.status === 401 || error.status === 403)) this.lease.invalidate("denied");
        throw error;
      }
    },
      (reason) => this.invalidatePeerConnections(reason), () => {
        this.recheckAuthorization();
        this.reconcileRelays();
      }, nativeOpts.lifecycle?.now, nativeOpts.lifecycle?.random, nativeOpts.lifecycle?.schedule);
    this.terminalStreams = new TerminalStreamRegistry({
      projectCataloged: nativeOpts.projectCataloged,
      projectBinding: (projectId) => this.projectStreams.projectBinding(projectId),
      peerSession: (peerId) => this.peerSession(peerId),
      // Guarded the same way `onUnauthorized` above is: a stale binding from a
      // superseded connection must never retire the peer's NEWER one.
      retirePeer: (peerId, reason) => { if (this.nativePeers.has(peerId)) this.retirePeer(peerId, reason); },
      // The registry's diagnostic detail is `Record<string, unknown>` (§3.2's
      // contract-pinned shape, generic over every terminal-stream event this
      // file has no reason to enumerate); netwatch's is narrower. Diagnostics
      // are observability only, never a security or routing decision, so the
      // cast is safe here in a way it would not be for an authorization value.
      diagnostic: (type, detail, stream) => this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh",
        msgType: type, detail: detail as Record<string, string | number | boolean>,
        ...(stream ? { streamKind: stream.kind, streamId: stream.id } : {}) }),
    });
    this.tunnelStreams = new TunnelStreamRegistry({
      projectCataloged: nativeOpts.projectCataloged,
      tunnelBinding: (projectId) => this.projectStreams.tunnelBinding(projectId),
      // Guarded the same way `terminalStreams`'s is: a stale binding from a
      // superseded connection must never retire the peer's NEWER one.
      retirePeer: (peerId, reason) => { if (this.nativePeers.has(peerId)) this.retirePeer(peerId, reason); },
      diagnostic: (type, detail, stream) => this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh",
        msgType: type, detail: detail as Record<string, string | number | boolean>,
        ...(stream ? { streamKind: stream.kind, streamId: stream.id } : {}) }),
    });
    this.uploadStreams = new UploadStreamRegistry({
      projectCataloged: nativeOpts.projectCataloged,
      uploadBinding: (projectId) => this.projectStreams.uploadBinding(projectId),
      // Guarded the same way `terminalStreams`'s / `tunnelStreams`'s is: a
      // stale binding from a superseded connection must never retire the
      // peer's NEWER one.
      retirePeer: (peerId, reason) => { if (this.nativePeers.has(peerId)) this.retirePeer(peerId, reason); },
      diagnostic: (type, detail, stream) => this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh",
        msgType: type, detail: detail as Record<string, string | number | boolean>,
        ...(stream ? { streamKind: stream.kind, streamId: stream.id } : {}) }),
    });
  }

  connect(): void {
    this.lifecycle.start();
  }

  protected override routeTerminalMessage(
    peerId: string,
    msg: AbMessage,
    signal?: AbortSignal,
  ): Promise<StreamSendOutcome> | undefined {
    return this.terminalStreams.route(peerId, msg, signal);
  }

  protected override terminalRetired(peerId: string, attachmentId: string): void {
    this.terminalStreams.retired(peerId, attachmentId);
  }

  protected override terminalSubscribeSettled(peerId: string, requestId: string, attachmentId: string | undefined): void {
    this.terminalStreams.subscribeSettled(peerId, requestId, attachmentId);
  }

  protected override terminalProjectDetached(projectId: string): void {
    this.terminalStreams.projectDetached(projectId);
    this.tunnelStreams.projectDetached(projectId);
    this.uploadStreams.projectDetached(projectId);
  }

  private async startEndpoint(): Promise<Endpoint> {
    await this.enrollment.register();
    if (this.stopped) throw new EndpointFailure("ENDPOINT_STOPPED");
    if (!await this.lease.refresh()) throw new Error("Peer lease refused");
    if (this.lease.current?.endpoint?.endpointId !== this.enrollment.endpointId) {
      this.lease.invalidate("rotated");
      throw new EndpointFailure("LOCAL_ENDPOINT_ROTATED", true);
    }
    const native = await import("@number0/iroh/index.js");
    if (this.stopped) throw new EndpointFailure("ENDPOINT_STOPPED");
    const builder = native.Endpoint.builder();
    builder.applyMinimal();
    builder.secretKey(this.enrollment.seedBytes());
    builder.alpns([Array.from(Buffer.from(PEER_ALPN))]);
    const evalBind = evalIrohBindAddress();
    if (evalBind) builder.bindAddr(evalBind);
    const relays = this.lease.current?.relayUrls;
    if (!relays?.length) throw new EndpointFailure("NO_APPROVED_RELAY", true);
    builder.relayMode(native.RelayMode.customFromUrls(relays));
    const endpoint = await builder.bind();
    if (relays.slice().sort().join("\n") !== this.lease.current?.relayUrls.slice().sort().join("\n")) {
      await endpoint.close();
      throw new Error("Relay policy changed while binding endpoint");
    }
    if (endpoint.id().toString() !== this.enrollment.endpointId) {
      await endpoint.close();
      throw new EndpointFailure("ENDPOINT_IDENTITY_MISMATCH", true);
    }
    this.approvedRelays = relays.slice().sort().join("\n");
    return endpoint;
  }

  private reconcileRelays(): void {
    if (this.lifecycle.state === "ready" && this.lease.current?.relayUrls.slice().sort().join("\n") !== this.approvedRelays) {
      this.lifecycle.restart();
    }
  }

  private async acceptConnections(endpoint: Endpoint, lifetime: number): Promise<void> {
    while (!this.stopped && lifetime === this.lifetime) {
      const incoming = await endpoint.acceptNext();
      if (!incoming) return;
      // Capacity is judged in `acceptPeer`, once the connecting device's
      // identity is known — a peer with a live connection reconnecting must
      // supersede its old one rather than being refused for the room it
      // already occupies.
      if (this.stopped || lifetime !== this.lifetime || !this.nativeOpts.remoteAccessEnabled()) {
        await incoming.refuse(); continue;
      }
      const reservation = this.admissions.reserve();
      if (!reservation) { await incoming.refuse(); continue; }
      void this.admitIncoming(incoming, lifetime, reservation);
    }
  }

  private recordAdmissionCounts(): void {
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:admissions",
      detail: { pending: this.admissions.size, active: this.nativePeers.size, generation: this.admissions.currentGeneration } });
  }

  private async admitIncoming(incoming: Incoming, lifetime: number, reservation: AdmissionReservation): Promise<void> {
    this.recordAdmissionCounts();
    const generation = this.admissionGeneration;
    let retired = false;
    let connection: Connection | undefined;
    const connecting = Promise.resolve().then(() => incoming.accept()).then((accepting) => accepting.connect()).then((value) => {
      if (retired || !reservation.current || this.stopped || generation !== this.admissionGeneration || lifetime !== this.lifetime) {
        value.close(1n, []);
        throw new EndpointFailure("ADMISSION_RETIRED");
      }
      return value;
    });
    try {
      connection = await deadline(connecting, () => { retired = true; }, this.nativeOpts.lifecycle?.schedule);
      await this.acceptPeer(connection);
    } catch (error) {
      connection?.close(error instanceof EndpointApiError && [401, 403].includes(error.status) ? 3n : 1n, []);
    } finally {
      // Uncancellable Connecting futures continue occupying their bounded slot.
      await connecting.catch(() => {});
      reservation.release();
      this.recordAdmissionCounts();
    }
  }

  private async acceptPeer(connection: Connection): Promise<void> {
    const now = this.nativeOpts.lifecycle?.now ?? performance.now.bind(performance);
    const startedAt = now();
    const attemptGeneration = ++this.peerAttemptGeneration;
    const generation = this.admissionGeneration;
    const close = () => connection.close(3n, []);
    if (!Buffer.from(connection.alpn()).equals(Buffer.from(PEER_ALPN))) { connection.close(2n, []); return; }
    // Synchronous and before any await: the accept loop below must never see
    // a stream count the peer negotiated ahead of this cap taking effect.
    connection.setMaxConcurrentBiStreams(BigInt(STREAM_MAX_BIDI_STREAMS_PER_CONNECTION));
    const endpointId = connection.remoteId().toString();
    let device = this.lease.current?.peers.find((peer) => peer.endpoint?.endpointId === endpointId);
    if (!device) {
      // Pre-filter before refreshing: an id already in the cached lease costs
      // no extra request here. An id that is still unrecognized after one
      // refresh this window is closed without retrying it — that refresh
      // is what admits a just-registered device whose outbox push is late.
      const attemptedAt = now();
      const last = this.unknownEndpointRefreshAt.get(endpointId);
      if (last !== undefined && attemptedAt - last < UNKNOWN_ENDPOINT_REFRESH_WINDOW_MS) { close(); return; }
      if (last === undefined && this.unknownEndpointRefreshAt.size >= MAX_UNKNOWN_ENDPOINT_ENTRIES) {
        const oldest = this.unknownEndpointRefreshAt.keys().next().value;
        if (oldest !== undefined) this.unknownEndpointRefreshAt.delete(oldest);
      }
      this.unknownEndpointRefreshAt.set(endpointId, attemptedAt);
      if (!await this.lease.refresh() || generation !== this.admissionGeneration) { close(); return; }
      device = this.lease.current?.peers.find((peer) => peer.endpoint?.endpointId === endpointId);
    }
    // A recognized id must not carry a throttle stamp: a policy bump drops every
    // peer and nulls the lease, and its redial would otherwise be refused as unknown.
    if (device) this.unknownEndpointRefreshAt.delete(endpointId);
    if (!device || !this.nativeOpts.remoteAccessEnabled()) { close(); return; }
    const peerId = `${device.deviceId}#${this.deviceId}`;
    // Newest authenticated connection wins: a device redialing (network
    // flap, app restart) supersedes its own prior connection rather than
    // being refused for the session it still holds. Only a device the lease
    // has authenticated reaches this point, so this is never a stranger
    // evicting a legitimate holder — and only the SAME endpoint supersedes:
    // a different endpoint the lease still authorizes for this device is a
    // second live identity, and must not evict the first.
    const existing = this.nativePeers.get(peerId);
    if (existing) {
      if (existing.endpointId !== endpointId && this.authorized(peerId, existing.endpointId)) {
        connection.close(1n, []);
        return;
      }
      this.retirePeer(peerId, existing.endpointId === endpointId ? "superseded" : "unauthorized");
    } else if (this.nativePeers.size >= MAX_APP_SESSIONS) {
      connection.close(1n, []);
      return;
    }
    const peer: NativePeerContext = {
      connection,
      endpointId,
      registrationGeneration: device.endpoint!.generation,
      attemptGeneration,
      sessionGeneration: 0,
      retired: false,
      acceptedAt: now(),
    };
    this.nativePeers.set(peerId, peer);
    let stream;
    try {
      stream = await deadline(connection.acceptBi(), () => connection.close(1n, []), this.nativeOpts.lifecycle?.schedule);
    } catch (error) {
      this.retireOwnAttempt(peerId, peer);
      throw error;
    }
    if (this.stopped || generation !== this.admissionGeneration || !this.nativeOpts.remoteAccessEnabled() ||
        !this.lease.allows(device.deviceId, endpointId) || this.nativePeers.get(peerId) !== peer) {
      this.retireOwnAttempt(peerId, peer); return;
    }
    // Every native stream — the session stream included — opens with one
    // open-frame record; only the first stream may declare `{kind:"session"}`,
    // and a stream open frame violation here has no session yet to keep
    // alive, unlike a later stream's in-band refusal.
    let opened;
    try {
      opened = await deadline(readStreamOpen(stream.recv), () => connection.close(1n, []), this.nativeOpts.lifecycle?.schedule);
    } catch {
      this.retireOwnAttempt(peerId, peer);
      return;
    }
    if (!opened.ok || opened.open.kind !== "session") {
      if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "protocol-violation");
      else connection.close(2n, []);
      return;
    }
    // The read above awaited, so every step-5 check can have gone stale.
    if (this.stopped || generation !== this.admissionGeneration || !this.nativeOpts.remoteAccessEnabled() ||
        !this.lease.allows(device.deviceId, endpointId) || this.nativePeers.get(peerId) !== peer) {
      this.retireOwnAttempt(peerId, peer); return;
    }
    // Identity exists before the first read: the read loop's very first
    // frame may be the hello, and `handleHello` fails closed on an absent
    // `peerPubkeyFor`.
    this.admitPeer(peerId, device.ed25519Pub);
    // A session-stream overflow retires the whole connection rather than
    // just this stream (D3's one exception): losing the session stream is
    // losing the session, and there is no separate stream to reopen.
    const writer = new StreamRecordWriter(
      { send: stream.send },
      () => this.authorized(peerId, endpointId),
      (reason) => { if (this.nativePeers.get(peerId)?.sessionWriter === writer)
        this.retirePeer(peerId, reason === "unauthorized" ? "unauthorized"
          : reason === "overflow" ? "queue-full" : "connection-lost"); },
      SESSION_STREAM_MAX_QUEUED_BYTES, STREAM_PRIORITY_SESSION, STREAM_RESET_SESSION,
    );
    const reader = new StreamRecordReader({ recv: stream.recv }, PEER_MAX_RECORD_BYTES,
      () => { if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "protocol-violation"); });
    peer.sessionWriter = writer;
    // Reads `sessions`, not any hello bookkeeping: `handleHello` must have put
    // the peer there by the time this fires, or every connection dies here.
    peer.cancelHelloTimer = this.schedule(() => {
      if (this.nativePeers.get(peerId) === peer && !this.sessions.has(peerId)) this.retirePeer(peerId, "connection-lost");
    }, HELLO_TIMEOUT_MS);
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:native-accepted",
      streamKind: "session", streamId: NETWATCH_SESSION_STREAM_LABEL,
      detail: {
        elapsedMs: now() - startedAt,
        attemptGeneration,
        leaseRemainingMs: this.lease.remainingMs,
      } });
    // Later bidi streams belong to `PeerStreamAcceptor` (admitted or refused
    // in-band, never fatal); nothing uses a uni stream, so one is a violation.
    void connection.acceptUni().then(
      () => { if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "protocol-violation"); },
      () => {},
    );
    void connection.closed().then(() => {
      if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "connection-lost");
    });
    void (async () => {
      try {
        for (;;) {
          // Checked before the read too: the first pass runs synchronously
          // inside admission, so a peer admitted under a snapshot that no
          // longer authorizes this endpoint is refused before it idles here.
          if (!this.authorized(peerId, endpointId)) { this.retirePeer(peerId, "unauthorized"); return; }
          const record = await reader.read();
          if (this.nativePeers.get(peerId) !== peer) return;
          if (!this.authorized(peerId, endpointId)) { this.retirePeer(peerId, "unauthorized"); return; }
          let frame;
          try {
            frame = decodePeerFrame(record);
          } catch {
            this.retirePeer(peerId, "protocol-violation");
            return;
          }
          this.receivePeerFrame(frame.payload, peerId, frame.header.type);
        }
      } catch (error) {
        // A `StreamProtocolViolation` has already retired the peer through the
        // reader's own `onFailure` above; retiring it again here would just
        // relabel the same event under a second reason. Anything else is the
        // ordinary FIN/reset a live connection eventually takes.
        if (!(error instanceof StreamProtocolViolation) && this.nativePeers.get(peerId) === peer) {
          this.retirePeer(peerId, "connection-lost");
        }
      }
    })();
    peer.streams = new PeerStreamAcceptor({
      connection,
      peerId,
      isCurrent: () => this.nativePeers.get(peerId) === peer,
      authorized: () => this.authorized(peerId, endpointId),
      established: () => this.sessions.has(peerId),
      onUnauthorized: () => { if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "unauthorized"); },
      handlers: {
        project: this.projectStreams.handler,
        terminal: this.terminalStreams.handler,
        "tunnel-http": this.tunnelStreams.httpHandler,
        "tunnel-ws": this.tunnelStreams.wsHandler,
        upload: this.uploadStreams.handler,
      },
      schedule: this.nativeOpts.lifecycle?.schedule,
      diagnostic: (type, detail, stream) => this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: type, detail,
        ...(stream ? { streamKind: stream.kind, streamId: stream.id } : {}) }),
    });
    peer.streams.start();
  }

  private schedule(callback: () => void, ms: number): () => void {
    if (this.nativeOpts.lifecycle?.schedule) return this.nativeOpts.lifecycle.schedule(callback, ms);
    const timer = setTimeout(callback, ms);
    timer.unref?.();
    return () => clearTimeout(timer);
  }

  private authorized(peerId: string, endpointId?: string): boolean {
    if (this.stopped || !this.nativeOpts.remoteAccessEnabled() || !this.lease.allows(baseSlotDeviceId(peerId), endpointId)) return false;
    if (this.lease.current?.endpoint?.endpointId !== this.enrollment.endpointId) return false;
    const peer = this.nativePeers.get(peerId);
    const authorized = this.lease.current?.peers.find((value) => value.deviceId === baseSlotDeviceId(peerId));
    if (peer && peer.registrationGeneration !== authorized?.endpoint?.generation) return false;
    const establishedKey = this.peerPubkeyFor(peerId);
    return !this.sessions.has(peerId) || !establishedKey || establishedKey === authorized?.ed25519Pub;
  }

  invalidateAuthorization(): void { this.lease.invalidate("denied"); }
  notePolicyGeneration(generation: string): void {
    this.lease.observePolicyGeneration(generation);
    void this.lease.refresh().catch(() => {});
  }

  recheckAuthorization(): void {
    for (const peerId of new Set([...this.sessions.keys(), ...this.nativePeers.keys()])) {
      if (!this.authorized(peerId, this.nativePeers.get(peerId)?.endpointId)) {
        this.retirePeer(peerId, "unauthorized");
      }
    }
  }

  noteResume(): Promise<boolean> {
    return this.lease.resume().then((allowed) => {
      if (allowed && this.lifecycle.state === "blocked") this.lifecycle.retry();
      return allowed;
    });
  }

  /** A superseded attempt must never retire its successor: `retirePeer` keys
   *  on `peerId`, and by the time a slow `acceptBi` settles that slot may hold
   *  the newer connection that replaced this one. */
  private retireOwnAttempt(peerId: string, peer: NativePeerContext): void {
    if (this.nativePeers.get(peerId) === peer) this.retirePeer(peerId, "connection-lost");
    else if (!peer.retired) peer.connection.close(1n, []);
  }

  private retirePeer(peerId: string, reason: PeerRecordFailure = "connection-lost"): void {
    const peer = this.nativePeers.get(peerId);
    if (!peer || peer.retired) return;
    peer.retired = true;
    this.nativePeers.delete(peerId);
    peer.cancelHelloTimer?.();
    peer.streams?.stop();
    this.terminalStreams.dropPeer(peerId);
    this.tunnelStreams.dropPeer(peerId);
    this.uploadStreams.dropPeer(peerId);
    this.projectStreams.dropPeer(peerId);
    peer.connection.close(reason === "unauthorized" ? 3n : reason === "protocol-violation" ? 2n : 1n, []);
    peer.sessionWriter?.abort();
    super.dropSession(peerId);
    this.recordDiagnostic({
      dir: "event",
      kind: "lifecycle",
      transport: "iroh",
      msgType: "peer:native-retired",
      streamKind: "session",
      streamId: NETWATCH_SESSION_STREAM_LABEL,
      detail: {
        attemptGeneration: peer.attemptGeneration,
        sessionGeneration: peer.sessionGeneration,
        reason,
        teardownOutcome: "requested",
        leaseRemainingMs: this.lease.remainingMs,
      },
    });
  }

  private dropAllPeers(reason: PeerRecordFailure = "unauthorized"): void {
    this.admissionGeneration++;
    this.admissions.retireGeneration();
    for (const peerId of [...this.nativePeers.keys()]) this.retirePeer(peerId, reason);
    for (const peerId of [...this.sessions.keys()]) this.dropSession(peerId);
  }

  private invalidatePeerConnections(reason: LeaseFailure): void {
    if (reason === "denied" || reason === "rotated") this.lifecycle.block(reason);
    this.dropAllPeers(reason === "resume" ? "connection-lost" : "unauthorized");
  }

  protected override onSessionEstablished(peerId: string): void {
    const peer = this.nativePeers.get(peerId);
    if (!peer) return;
    peer.cancelHelloTimer?.();
    peer.cancelHelloTimer = undefined;
    peer.sessionGeneration = ++this.peerSessionGeneration;
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:e2e-established",
      streamKind: "session", streamId: NETWATCH_SESSION_STREAM_LABEL,
      detail: {
        elapsedMs: (this.nativeOpts.lifecycle?.now ?? performance.now.bind(performance))() - peer.acceptedAt,
        attemptGeneration: peer.attemptGeneration,
        sessionGeneration: peer.sessionGeneration,
        leaseRemainingMs: this.lease.remainingMs,
      } });
  }

  protected override receivePeerFrame(payload: Uint8Array, from: string, kind: PeerFrameKind): void {
    if (!this.authorized(from, this.nativePeers.get(from)?.endpointId)) {
      void this.lease.refresh().catch(() => {});
      return;
    }
    super.receivePeerFrame(payload, from, kind);
  }

  /**
   * The lease re-check gate for a hello. A peer with an established session
   * just gets the base re-ack/violation rule (step 2) — the lease was already
   * checked when that session was established and is re-verified continuously
   * by `recheckAuthorization`. A fresh hello instead pins its `attemptId`
   * (so a retransmit before the refresh settles is a no-op, and a DIFFERENT
   * attemptId arriving mid-refresh is a violation) and defers establishment
   * until the refresh confirms the lease still allows this device.
   */
  protected override handleHello(hello: SessionHello, from: string, frameId?: string, bytes?: number): void {
    const peer = this.nativePeers.get(from);
    if (!peer || peer.retired) return;
    if (this.sessions.has(from)) { super.handleHello(hello, from, frameId, bytes); return; }
    if (peer.helloAttemptId !== undefined) {
      if (peer.helloAttemptId === hello.attemptId) return;
      this.refusePeer(from, "protocol-violation");
      return;
    }
    peer.helloAttemptId = hello.attemptId;
    void this.lease.refresh().then((allowed) => {
      if (this.stopped || this.nativePeers.get(from) !== peer || peer.retired) return;
      if (!allowed || !this.authorized(from, peer.endpointId)) { this.refusePeer(from, "unauthorized"); return; }
      super.handleHello(hello, from, frameId, bytes);
    }).catch(() => {
      if (this.nativePeers.get(from) === peer && !peer.retired) this.refusePeer(from, "connection-lost");
    });
  }

  protected override refusePeer(peerId: string, reason: PeerRecordFailure): void {
    this.retirePeer(peerId, reason);
  }

  /** Guarded the same way `terminalStreams`'s / `tunnelStreams`'s callbacks
   *  are: a stale binding from a superseded connection must never retire the
   *  peer's NEWER one. */
  protected override retirePeerConnection(peerId: string, reason: "unauthorized" | "protocol-violation"): void {
    if (this.nativePeers.has(peerId)) this.retirePeer(peerId, reason);
  }

  protected override dropSession(peerId: string): void {
    if (this.nativePeers.has(peerId)) { this.retirePeer(peerId); return; }
    super.dropSession(peerId);
  }

  protected override writeSessionRecord(
    peerId: string,
    kind: PeerFrameKind,
    payload: Buffer,
    diagnosticType: string,
    signal?: AbortSignal,
  ): Promise<StreamSendOutcome> | null {
    const peer = this.nativePeers.get(peerId);
    if (!peer?.sessionWriter) return null;
    const record = encodePeerFrame({ type: kind }, payload);
    return peer.sessionWriter.send(record, signal).then((outcome) => {
      if (outcome === "sent") this.recordNativeWrite(payload, record.length, diagnosticType);
      return outcome;
    });
  }

  private recordNativeWrite(payload: Uint8Array, peerFrameBytes: number, msgType: string): void {
    this.recordDiagnostic({ dir: "tx", kind: "frame", transport: "iroh",
      channel: "control", streamKind: "session", streamId: NETWATCH_SESSION_STREAM_LABEL,
      msgType, bytes: payload.length, frameId: frameIdFor(payload),
      detail: { peerFrameBytes, recordBytes: peerFrameBytes + 4, lengthPrefixBytes: 4 } });
  }

  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.stopped = true;
    this.lifetime++;
    this.lease.invalidate("closed");
    this.enrollment.close();
    this.disposeSessions();
    this.closing = this.lifecycle.stop();
    return this.closing;
  }
}

/** Central control has no reference to peer keys, queues or project readiness. */
export class NativeHostConnection implements RemoteHostConnection {
  private closed = false;
  readonly peers: NativePeerSessions;
  readonly central: CentralControlClient;
  constructor(options: NativeHostOptions) {
    this.peers = new NativePeerSessions(options.native);
    this.central = new CentralControlClient({
      ...options.central,
      onPeerPolicyChanged: (generation) => this.peers.notePolicyGeneration(generation),
      onAuthRevoked: () => { this.peers.invalidateAuthorization(); options.central.onAuthRevoked?.(); },
    });
  }
  get deviceId() { return this.peers.deviceId; }
  connect(): void { if (this.closed) return; this.central.connect(); this.peers.connect(); }
  close(): Promise<void> {
    if (this.closed) return this.peers.close();
    this.closed = true;
    this.central.close();
    return this.peers.close();
  }
  redialWithFreshToken(): void { this.central.redialWithFreshToken(); }
  sendPushDeliver(message: Parameters<CentralControlClient["sendPushDeliver"]>[0]): void { this.central.sendPushDeliver(message); }
  setBus(...args: Parameters<NativePeerSessions["setBus"]>) { return this.peers.setBus(...args); }
  attachStream(...args: Parameters<NativePeerSessions["attachStream"]>) { return this.peers.attachStream(...args); }
  establishedPeers() { return this.peers.establishedPeers(); }
  peerSession(...args: Parameters<NativePeerSessions["peerSession"]>) { return this.peers.peerSession(...args); }
  hasEstablishedSession() { return this.peers.hasEstablishedSession(); }
  anySessionSupportsCheckoutRouting() { return this.peers.anySessionSupportsCheckoutRouting(); }
  send(...args: Parameters<NativePeerSessions["send"]>) { return this.peers.send(...args); }
  sendOnChannel(...args: Parameters<NativePeerSessions["sendOnChannel"]>) { return this.peers.sendOnChannel(...args); }
  noteResume(): Promise<boolean> { return this.peers.noteResume(); }
  recheckAuthorization(): void { this.peers.recheckAuthorization(); }
}

async function deadline<T>(operation: Promise<T>, cancel: () => void,
  schedule: (callback: () => void, ms: number) => () => void = (callback, ms) => {
    const timer = setTimeout(callback, ms); timer.unref?.(); return () => clearTimeout(timer);
  }): Promise<T> {
  let cancelTimer: (() => void) | undefined;
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => {
      cancelTimer = schedule(() => { cancel(); reject(new Error("Native admission timed out")); }, 5_000);
    })]);
  } finally { cancelTimer?.(); }
}
