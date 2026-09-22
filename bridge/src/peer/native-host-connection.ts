import { z } from "zod";
import { FrameKind, MAX_FRAME_PAYLOAD, PEER_ALPN, PEER_REFRESH_MS, RouteHeader, decodeRouteFrame, encodeRouteFrame } from "antgrid-wire";
import type { Connection, Endpoint, Incoming } from "@number0/iroh";
import { CentralControlClient, type CentralControlOptions } from "../central-control-client";
import { baseSlotDeviceId } from "../relay-slot";
import type { Channel, MessageBus } from "../message-bus";
import type { AttachStreamOpts, StreamHandle } from "../stream-mux";
import type { PendingSinkWrite, QueuedAppFrame } from "../send-scheduler";
import { AuthorizationLease, type EnrollmentIdentity, type LeaseFailure } from "./authorization-lease";
import { EndpointApiError, EndpointEnrollment } from "./enrollment";
import { PeerRecords, type PeerRecordFailure } from "./records";
import { PeerSessionOwner, type PeerSessionOwnerOptions, MAX_APP_SESSIONS } from "../peer-session-owner";
import { EndpointLifecycle, EndpointFailure } from "./endpoint-lifecycle";
import type { RemoteHostConnection } from "../remote-host-connection";
import { frameIdFor } from "../netwatch";

export interface NativeHostOptions extends PeerSessionOwnerOptions, CentralControlOptions {
  enrollment: EnrollmentIdentity;
  endpointSecret: string;
  licenseApiUrl: string;
  remoteAccessEnabled: () => boolean;
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
interface NativePeer {
  connection: Connection;
  endpointId: string;
  registrationGeneration: string;
  records: PeerRecords;
  handshakeTimer: ReturnType<typeof setTimeout>;
  acceptedAt: number;
}

/** Central inventory and native payloads share host-owned project bindings. */
export class NativePeerSessions extends PeerSessionOwner {
  private readonly nativePeers = new Map<string, NativePeer>();
  private readonly authorizedHellos = new Map<string, { attemptId: string; admitted: boolean }>();
  private readonly lifecycle: EndpointLifecycle<Endpoint>;
  private readonly admittingPeers = new Set<string>();
  private readonly enrollment: EndpointEnrollment;
  private readonly lease: AuthorizationLease;
  private refreshTimer: ReturnType<typeof setInterval> | null = null;
  private lifetime = 0;
  private stopped = false;
  private pendingAdmissions = 0;
  private admissionGeneration = 0;
  private approvedRelays = "";

  constructor(private readonly nativeOpts: NativeHostOptions) {
    super(nativeOpts);
    nativeOpts.payloadSink = { send: (...args) => this.sendNativePayload(...args),
      sendScheduled: (...args) => this.sendNativeScheduled(...args) };
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
      changed: (state, reason) => this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh",
        msgType: "peer:endpoint-state", detail: { state, ...(reason ? { reason } : {}) } }),
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
      });
  }

  connect(): void {
    this.lifecycle.start();
  }

  private async startEndpoint(): Promise<Endpoint> {
    await this.enrollment.register();
    if (this.stopped) throw new EndpointFailure("ENDPOINT_STOPPED");
    if (!await this.lease.refresh()) throw new Error("Peer lease refused");
    if (this.lease.current?.endpoint?.endpointId !== this.enrollment.endpointId) {
      this.lease.invalidate("rotated");
      throw new EndpointFailure("LOCAL_ENDPOINT_ROTATED", true);
    }
    if (this.refreshTimer) clearInterval(this.refreshTimer);
    this.refreshTimer = setInterval(() => {
      if (this.sessions.size || this.nativePeers.size) void this.lease.refresh().catch(() => {});
    }, PEER_REFRESH_MS);
    this.refreshTimer.unref?.();
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
      if (this.stopped || lifetime !== this.lifetime || !this.nativeOpts.remoteAccessEnabled() ||
          this.nativePeers.size >= MAX_APP_SESSIONS || this.pendingAdmissions >= 4) {
        await incoming.refuse(); continue;
      }
      void this.admitIncoming(incoming, lifetime);
    }
  }

  private recordAdmissionCounts(): void {
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:admissions",
      detail: { pending: this.pendingAdmissions, active: this.nativePeers.size, generation: this.admissionGeneration } });
  }

  private async admitIncoming(incoming: Incoming, lifetime: number): Promise<void> {
    this.pendingAdmissions++;
    this.recordAdmissionCounts();
    const generation = this.admissionGeneration;
    let retired = false;
    let connection: Connection | undefined;
    const connecting = Promise.resolve().then(() => incoming.accept()).then((accepting) => accepting.connect()).then((value) => {
      if (retired || this.stopped || generation !== this.admissionGeneration || lifetime !== this.lifetime) {
        value.close(1n, []);
        throw new EndpointFailure("ADMISSION_RETIRED");
      }
      return value;
    });
    try {
      connection = await deadline(connecting, () => { retired = true; });
      await this.acceptPeer(connection);
    } catch (error) {
      connection?.close(error instanceof EndpointApiError && [401, 403].includes(error.status) ? 3n : 1n, []);
    } finally {
      // Uncancellable Connecting futures continue occupying their bounded slot.
      await connecting.catch(() => {});
      this.pendingAdmissions--;
      this.recordAdmissionCounts();
    }
  }

  private async acceptPeer(connection: Connection): Promise<void> {
    const startedAt = performance.now();
    const generation = this.admissionGeneration;
    const close = () => connection.close(3n, []);
    if (!Buffer.from(connection.alpn()).equals(Buffer.from(PEER_ALPN))) { connection.close(2n, []); return; }
    if (!await this.lease.refresh() || generation !== this.admissionGeneration) { close(); return; }
    const endpointId = connection.remoteId().toString();
    const device = this.lease.current?.peers.find((peer) => peer.endpoint?.endpointId === endpointId);
    if (!device || !this.nativeOpts.remoteAccessEnabled()) { close(); return; }
    const peerId = `${device.deviceId}#${this.deviceId}`;
    // A concurrent native connection must not create a second session writer.
    if (this.sessions.has(peerId) || this.pending.has(peerId) || this.nativePeers.has(peerId) || this.admittingPeers.has(peerId) ||
        this.nativePeers.size + this.admittingPeers.size >= MAX_APP_SESSIONS) { connection.close(1n, []); return; }
    this.admittingPeers.add(peerId);
    try {
    const stream = await deadline(connection.acceptBi(), () => connection.close(1n, []));
    if (this.stopped || generation !== this.admissionGeneration || !this.nativeOpts.remoteAccessEnabled() || !this.lease.allows(device.deviceId, endpointId) ||
        this.sessions.has(peerId) || this.pending.has(peerId) || this.nativePeers.has(peerId)) { close(); return; }
    const records = new PeerRecords(stream, () => this.authorized(peerId, endpointId), (reason) => {
      if (this.nativePeers.get(peerId)?.records === records) this.dropNativePeer(peerId, reason);
    });
    const handshakeTimer = setTimeout(() => {
      if (!this.sessions.has(peerId)) records.close();
    }, 30_000);
    handshakeTimer.unref?.();
    const peer: NativePeer = { connection, endpointId, registrationGeneration: device.endpoint!.generation, records, handshakeTimer,
      acceptedAt: performance.now() };
    this.nativePeers.set(peerId, peer);
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:native-accepted",
      detail: { elapsedMs: performance.now() - startedAt } });
    void connection.acceptBi().then(() => records.close("protocol-violation"), () => {});
    void connection.acceptUni().then(() => records.close("protocol-violation"), () => {});
    void connection.closed().then(() => {
      if (this.nativePeers.get(peerId) === peer) records.close();
    });
    void (async () => {
      try {
        while (this.nativePeers.get(peerId) === peer) {
          const frame = decodeRouteFrame(await records.read());
          if (frame.payload.length > MAX_FRAME_PAYLOAD) throw new Error("Invalid route payload length");
          const header = RouteHeader.parse(frame.header);
          if (header.to !== this.deviceId) throw new Error("Invalid route destination");
          if (this.nativePeers.get(peerId) !== peer) return;
          this.receiveRoutedFrame(frame.payload, peerId, header.channel, frame.kind);
        }
      } catch { records.close("protocol-violation"); }
    })();
    } finally { this.admittingPeers.delete(peerId); }
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
    for (const peerId of new Set([...this.sessions.keys(), ...this.pending.keys(), ...this.nativePeers.keys()])) {
      if (!this.authorized(peerId, this.nativePeers.get(peerId)?.endpointId)) {
        this.dropNativePeer(peerId, "unauthorized");
        this.dropSession(peerId);
        this.tearDownPending(peerId);
      }
    }
  }

  noteResume(): Promise<boolean> {
    return this.lease.resume().then((allowed) => {
      if (allowed && this.lifecycle.state === "blocked") this.lifecycle.retry();
      return allowed;
    });
  }

  private dropNativePeer(peerId: string, reason: PeerRecordFailure = "connection-lost"): void {
    const peer = this.nativePeers.get(peerId);
    if (!peer) return;
    this.nativePeers.delete(peerId);
    clearTimeout(peer.handshakeTimer);
    peer.connection.close(reason === "unauthorized" ? 3n : reason === "protocol-violation" ? 2n : 1n, []);
    peer.records.close(reason);
    this.dropSession(peerId, "iroh");
    this.tearDownPending(peerId);
  }

  private dropAllPeers(reason: PeerRecordFailure = "unauthorized"): void {
    this.admissionGeneration++;
    this.authorizedHellos.clear();
    for (const peerId of [...this.nativePeers.keys()]) this.dropNativePeer(peerId, reason);
    for (const peerId of [...this.sessions.keys()]) this.dropSession(peerId);
    for (const peerId of [...this.pending.keys()]) this.tearDownPending(peerId);
  }

  private invalidatePeerConnections(reason: LeaseFailure): void {
    if (reason === "denied" || reason === "rotated") this.lifecycle.block(reason);
    this.dropAllPeers(reason === "resume" ? "connection-lost" : "unauthorized");
  }

  protected override payloadTransport(_peerId?: string): "iroh" { return "iroh"; }

  protected override onSessionEstablished(peerId: string): void {
    const peer = this.nativePeers.get(peerId);
    if (!peer) return;
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:e2e-established",
      detail: { elapsedMs: performance.now() - peer.acceptedAt } });
  }

  protected override receiveRoutedFrame(payload: Uint8Array, from: string, channel: Channel, kind: FrameKind): void {
    if (!this.authorized(from, this.nativePeers.get(from)?.endpointId)) {
      void this.lease.refresh().catch(() => {});
      return;
    }
    super.receiveRoutedFrame(payload, from, channel, kind);
  }

  protected override handleHandshakeFrame(payload: Uint8Array, from: string, frameId?: string, bytes?: number): void {
    let hello: { attemptId: string };
    try {
      hello = z.object({ type: z.literal("handshake:client-hello"), attemptId: z.string().min(1).max(256) })
        .parse(JSON.parse(Buffer.from(payload).toString("utf8")));
    } catch { return; }
    const previous = this.authorizedHellos.get(from);
    if (previous?.attemptId === hello.attemptId) {
      if (previous.admitted) super.handleHandshakeFrame(payload, from, frameId, bytes);
      return;
    }
    if (!previous && this.authorizedHellos.size >= 4) return;
    const attempt = { attemptId: hello.attemptId, admitted: false };
    const nativePeer = this.nativePeers.get(from);
    this.authorizedHellos.set(from, attempt);
    void this.lease.refresh().then((allowed) => {
      if (!allowed || this.stopped || this.authorizedHellos.get(from) !== attempt ||
          this.nativePeers.get(from) !== nativePeer || !this.authorized(from, nativePeer?.endpointId)) return;
      attempt.admitted = true;
      super.handleHandshakeFrame(payload, from, frameId, bytes);
    }).catch(() => {});
  }

  protected override dropSession(peerId: string, transport = this.payloadTransport(peerId)): void {
    if (this.nativePeers.has(peerId)) { this.dropNativePeer(peerId); return; }
    this.authorizedHellos.delete(peerId);
    super.dropSession(peerId, transport);
  }

  protected override resolvePhoneEd25519PubB64(peerId: string, verify: (candidate: string) => boolean) {
    const peer = this.lease.current?.peers.find((value) => value.deviceId === baseSlotDeviceId(peerId));
    return { pub: peer && verify(peer.ed25519Pub) ? peer.ed25519Pub : undefined, known: peer ? 1 : 0 };
  }

  private sendNativeScheduled(sealed: Buffer, peerId: string, frame: QueuedAppFrame): number | null | PendingSinkWrite {
    if (!this.authorized(peerId, this.nativePeers.get(peerId)?.endpointId)) return null;
    const peer = this.nativePeers.get(peerId);
    if (!peer) return null;
    const session = this.sessions.get(peerId);
    const record = encodeRouteFrame({ type: "message", to: peerId, channel: frame.channel }, sealed, FrameKind.sealed);
    return { bytes: sealed.length, completed: peer.records.send(record, () =>
      this.sessions.get(peerId) === session && !frame.signal?.aborted && frame.authorized?.() !== false,
    ).then((outcome) => {
      if (outcome === "sent") this.recordNativeWrite(sealed, record.length, frame.channel, FrameKind.sealed, frame.type, frame.streamId);
      return outcome === "sent";
    }) };
  }

  private sendNativePayload(data: Buffer | string, to: string, channel: Channel = "control", kind: FrameKind = FrameKind.sealed,
    diagnosticType = "transport", streamId?: string): boolean {
    if (!this.authorized(to, this.nativePeers.get(to)?.endpointId)) return false;
    const peer = this.nativePeers.get(to);
    if (!peer) return false;
    const payload = typeof data === "string" ? Buffer.from(data) : data;
    const record = encodeRouteFrame({ type: "message", to, channel }, payload, kind);
    void peer.records.send(record).then((outcome) => {
      if (outcome === "sent") this.recordNativeWrite(payload, record.length, channel, kind, diagnosticType, streamId);
    });
    return true;
  }

  private recordNativeWrite(payload: Uint8Array, routeBytes: number, channel: Channel, kind: FrameKind,
    msgType: string, streamId?: string): void {
    this.recordDiagnostic({ dir: "tx", kind: kind === FrameKind.handshake ? "handshake" : "sealed", transport: "iroh",
      channel, msgType, streamId, bytes: payload.length, frameId: frameIdFor(payload, kind === FrameKind.sealed),
      detail: { routeBytes, recordBytes: routeBytes + 4, lengthPrefixBytes: 4 } });
  }

  close(): void {
    this.stopped = true;
    this.lifetime++;
    if (this.refreshTimer) clearInterval(this.refreshTimer);
    this.refreshTimer = null;
    this.lease.invalidate("closed");
    this.enrollment.close();
    this.lifecycle.stop();
    this.disposeSessions();
  }
}

/** Central control has no reference to peer keys, queues or project readiness. */
export class NativeHostConnection implements RemoteHostConnection {
  private closed = false;
  readonly peers: NativePeerSessions;
  readonly central: CentralControlClient;
  constructor(options: NativeHostOptions) {
    this.peers = new NativePeerSessions(options);
    this.central = new CentralControlClient({
      url: options.url, identity: options.identity, abDir: options.abDir,
      getLicenseToken: options.getLicenseToken, pairedPhones: options.pairedPhones,
      autoReconnect: options.autoReconnect, onError: options.onError,
      onAuthenticated: options.onAuthenticated, onDisconnected: options.onDisconnected,
      onPeerPolicyChanged: (generation) => this.peers.notePolicyGeneration(generation),
      onAuthRevoked: () => { this.peers.invalidateAuthorization(); options.onAuthRevoked?.(); },
    });
  }
  get deviceId() { return this.peers.deviceId; }
  connect(): void { if (this.closed) return; this.central.connect(); this.peers.connect(); }
  close(): void { if (this.closed) return; this.closed = true; this.peers.close(); this.central.close(); }
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
  noteStreamBound(...args: Parameters<NativePeerSessions["noteStreamBound"]>) { return this.peers.noteStreamBound(...args); }
  noteResume(): Promise<boolean> { return this.peers.noteResume(); }
  recheckAuthorization(): void { this.peers.recheckAuthorization(); }
}

async function deadline<T>(operation: Promise<T>, cancel: () => void): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => {
      timer = setTimeout(() => { cancel(); reject(new Error("Native admission timed out")); }, 5_000);
      timer.unref?.();
    })]);
  } finally { if (timer) clearTimeout(timer); }
}
