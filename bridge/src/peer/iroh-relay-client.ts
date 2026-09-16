import { z } from "zod";
import { CONTROL_STREAM_ID, FrameKind, MAX_FRAME_PAYLOAD, PEER_ALPN, PEER_REFRESH_MS, RouteHeader, ServerMessage, decodeRouteFrame, encodeRouteFrame } from "antgrid-wire";
import type { Connection, Endpoint, Incoming } from "@number0/iroh";
import { RelayClient, type RelayClientOptions } from "../relay-client";
import { baseSlotDeviceId } from "../relay-slot";
import type { Channel, MessageBus } from "../message-bus";
import type { AttachStreamOpts, StreamHandle } from "../stream-mux";
import type { PendingSinkWrite, QueuedAppFrame } from "../send-scheduler";
import { AuthorizationLease, type EnrollmentIdentity, type LeaseFailure } from "./authorization-lease";
import { EndpointApiError, EndpointEnrollment } from "./enrollment";
import { PeerRecords, type PeerRecordFailure } from "./records";
import { frameIdFor } from "../netwatch";

export const TransportModeSchema = z.enum(["websocket", "iroh-preferred", "iroh-only"]);
export type TransportMode = z.infer<typeof TransportModeSchema>;

export interface IrohRelayOptions extends RelayClientOptions {
  enrollment: EnrollmentIdentity;
  endpointSecret: string;
  licenseApiUrl: string;
  mode: TransportMode;
  remoteAccessEnabled: () => boolean;
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
export class IrohRelayClient extends RelayClient {
  private readonly nativePeers = new Map<string, NativePeer>();
  private readonly centralStreams = new Set<string>();
  private readonly localAdmissions = new Map<string, () => void>();
  private readonly authorizedHellos = new Map<string, { attemptId: string; admitted: boolean }>();
  private endpoint: Endpoint | null = null;
  private readonly enrollment: EndpointEnrollment;
  private readonly lease: AuthorizationLease;
  private refreshTimer: ReturnType<typeof setInterval> | null = null;
  private lifetime = 0;
  private stopped = false;
  private pendingAdmissions = 0;
  private admissionGeneration = 0;
  private approvedRelays = "";

  constructor(private readonly nativeOpts: IrohRelayOptions) {
    super(nativeOpts);
    if (!nativeOpts.identity.ed25519PrivateKey) throw new Error("Endpoint enrollment requires device identity");
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

  override connect(): void {
    super.connect();
    const lifetime = ++this.lifetime;
    void this.startEndpoint(lifetime).catch((error) => {
      if (error instanceof EndpointApiError && (error.status === 401 || error.status === 403)) this.lease.invalidate("denied");
      this.opts.onError?.("PEER_TRANSPORT_UNAVAILABLE", String(error));
    });
  }

  private async startEndpoint(lifetime: number): Promise<void> {
    await this.enrollment.register();
    if (this.stopped || lifetime !== this.lifetime) return;
    if (!await this.lease.refresh()) throw new Error("Peer lease refused");
    if (this.lease.current?.endpoint?.endpointId !== this.enrollment.endpointId) {
      this.lease.invalidate("rotated");
      throw new Error("Local endpoint registration is no longer active");
    }
    if (this.stopped || lifetime !== this.lifetime) return;
    if (this.refreshTimer) clearInterval(this.refreshTimer);
    this.refreshTimer = setInterval(() => {
      if (this.sessions.size || this.nativePeers.size) void this.lease.refresh().catch(() => {});
    }, PEER_REFRESH_MS);
    this.refreshTimer.unref?.();
    if (this.nativeOpts.mode === "websocket") return;
    const native = await import("@number0/iroh/index.js");
    const builder = native.Endpoint.builder();
    builder.applyMinimal();
    builder.secretKey(this.enrollment.seedBytes());
    builder.alpns([Array.from(Buffer.from(PEER_ALPN))]);
    const relays = this.lease.current?.relayUrls;
    if (!relays?.length) throw new Error("No approved Iroh relay configured");
    builder.relayMode(native.RelayMode.customFromUrls(relays));
    const endpoint = await builder.bind();
    if (this.stopped || lifetime !== this.lifetime) { await endpoint.close(); return; }
    if (relays.slice().sort().join("\n") !== this.lease.current?.relayUrls.slice().sort().join("\n")) {
      await endpoint.close();
      throw new Error("Relay policy changed while binding endpoint");
    }
    if (endpoint.id().toString() !== this.enrollment.endpointId) {
      await endpoint.close();
      throw new Error("Native endpoint identity mismatch");
    }
    this.endpoint = endpoint;
    this.approvedRelays = relays.slice().sort().join("\n");
    void this.acceptConnections(endpoint, lifetime);
  }

  private reconcileRelays(): void {
    const endpoint = this.endpoint;
    if (!endpoint || this.lease.current?.relayUrls.slice().sort().join("\n") === this.approvedRelays) return;
    this.endpoint = null;
    const lifetime = ++this.lifetime;
    for (const peerId of [...this.nativePeers.keys()]) this.dropNativePeer(peerId);
    void endpoint.close().then(() => {
      if (!this.stopped && lifetime === this.lifetime) return this.startEndpoint(lifetime);
    }).catch((error) => this.opts.onError?.("PEER_TRANSPORT_UNAVAILABLE", String(error)));
  }

  private async acceptConnections(endpoint: Endpoint, lifetime: number): Promise<void> {
    try {
      while (!this.stopped && lifetime === this.lifetime) {
        const incoming = await endpoint.acceptNext();
        if (!incoming) return;
        if (!this.nativeOpts.remoteAccessEnabled() || this.nativePeers.size + this.pendingAdmissions >= 4) { await incoming.refuse(); continue; }
        let connection: Connection;
        try { connection = await this.connectIncoming(incoming); }
        catch { continue; }
        if (this.stopped || lifetime !== this.lifetime) { connection.close(1n, []); return; }
        try { await this.acceptPeer(connection); }
        catch (error) {
          connection.close(error instanceof EndpointApiError && (error.status === 401 || error.status === 403) ? 3n : 1n, []);
        }
      }
    } catch {
      if (!this.stopped && lifetime === this.lifetime) this.dropAllPeers("connection-lost");
    }
  }

  private async connectIncoming(incoming: Incoming): Promise<Connection> {
    const generation = this.admissionGeneration;
    this.pendingAdmissions++;
    let retired = false;
    const operation = incoming.accept().then((accepting) => accepting.connect()).then((connection) => {
      if (retired || this.stopped || generation !== this.admissionGeneration) {
        connection.close(1n, []);
        throw new Error("Retired native admission");
      }
      return connection;
    }).finally(() => { this.pendingAdmissions--; });
    // The binding cannot cancel Connecting. A timed-out future retains one
    // bounded admission slot until it settles, and its late connection is closed.
    return deadline(operation, () => { retired = true; });
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
    // The app selects before E2E. A late native connection cannot replace a
    // WebSocket handshake or create a second writer for that selection.
    if (this.sessions.has(peerId) || this.pending.has(peerId) || this.nativePeers.has(peerId)) { connection.close(1n, []); return; }
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
    return this.lease.resume();
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
    const websocketPeers = new Set([...this.sessions.keys(), ...this.pending.keys(), ...this.authorizedHellos.keys()]);
    const hasWebsocketPeer = [...websocketPeers].some((peerId) => !this.nativePeers.has(peerId));
    this.dropAllPeers(reason === "resume" ? "connection-lost" : "unauthorized");
    // Erasing WS keys alone leaves the app sending until its E2E liveness timer
    // expires. Central offline/online transitions already drive a fresh handshake.
    // Native-only sessions have their own connection-close signal.
    if (hasWebsocketPeer && reason !== "closed" && this.ws?.readyState === WebSocket.OPEN) {
      this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "relay",
        msgType: "peer:authorization-invalidated", detail: { reason } });
      this.ws.close(1012, "Peer authorization invalidated");
    }
  }

  protected override centralControlsPeer(peerId: string): boolean { return !this.nativePeers.has(peerId); }
  protected override payloadTransport(peerId?: string): "relay" | "iroh" {
    return peerId && this.nativePeers.has(peerId) ? "iroh" : "relay";
  }

  protected override handleTextMessage(raw: string): void {
    try {
      const parsed = ServerMessage.safeParse(JSON.parse(raw));
      if (parsed.success && parsed.data.type === "peer-policy-changed") {
        this.lease.observePolicyGeneration(parsed.data.generation);
        void this.lease.refresh().catch(() => {});
      }
      if (parsed.success && parsed.data.type === "stream-opened") this.centralStreams.add(parsed.data.streamId);
    } catch { /* The central decoder reports malformed control messages. */ }
    super.handleTextMessage(raw);
  }

  protected override resetE2eState(): void {
    this.centralStreams.clear();
    for (const peerId of this.authorizedHellos.keys()) if (this.centralControlsPeer(peerId)) this.authorizedHellos.delete(peerId);
    for (const peerId of [...this.sessions.keys()]) if (this.centralControlsPeer(peerId)) this.dropSession(peerId);
    for (const peerId of [...this.pending.keys()]) if (this.centralControlsPeer(peerId)) this.tearDownPending(peerId);
  }

  override attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    const startedAt = performance.now();
    let admitted = false;
    const admit = (id: string, transport: "relay" | "iroh" = "relay") => {
      if (admitted) return;
      admitted = true;
      this.localAdmissions.delete(id);
      if (transport === "iroh") this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport,
        msgType: "peer:project-local-admitted", streamId: id, detail: { elapsedMs: performance.now() - startedAt } });
      opts.onAdmitted?.(id);
    };
    const handle = super.attachStream(bus, { ...opts, onAdmitted: admit,
      onLocalReady: (id) => {
        opts.onLocalReady?.(id);
        this.localAdmissions.set(id, () => admit(id, "iroh"));
        if ([...this.nativePeers.keys()].some((peerId) => this.sessions.has(peerId))) admit(id, "iroh");
      },
    });
    return { ...handle, detach: () => {
      this.localAdmissions.delete(handle.streamId);
      this.centralStreams.delete(handle.streamId);
      handle.detach();
    } };
  }

  protected override onSessionEstablished(peerId: string): void {
    const peer = this.nativePeers.get(peerId);
    if (!peer) return;
    this.recordDiagnostic({ dir: "event", kind: "lifecycle", transport: "iroh", msgType: "peer:e2e-established",
      detail: { elapsedMs: performance.now() - peer.acceptedAt } });
    for (const admit of [...this.localAdmissions.values()]) admit();
  }

  protected override handleBinaryFrame(buf: Buffer): void {
    try {
      const frame = decodeRouteFrame(buf);
      const header = frame.header;
      if (typeof header === "object" && header && "from" in header && this.nativePeers.has(String(header.from))) {
        const from = String(header.from);
        const hello = frame.kind === FrameKind.handshake && JSON.parse(Buffer.from(frame.payload).toString("utf8"));
        if (hello?.type !== "handshake:client-hello" || this.sessions.has(from) || this.pending.has(from) || this.authorizedHellos.has(from)) return;
        // Selection timed out before native E2E began. Retire only that empty
        // native carrier so the selected WebSocket hello is not silently lost.
        this.dropNativePeer(from);
      }
    } catch { return; }
    if (this.nativeOpts.mode !== "iroh-only") super.handleBinaryFrame(buf);
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

  protected override sendScheduledPayload(sealed: Buffer, peerId: string, frame: QueuedAppFrame): number | null | PendingSinkWrite {
    if (!this.authorized(peerId, this.nativePeers.get(peerId)?.endpointId)) return null;
    const peer = this.nativePeers.get(peerId);
    if (!peer) return super.sendScheduledPayload(sealed, peerId, frame);
    const session = this.sessions.get(peerId);
    const record = encodeRouteFrame({ type: "message", to: peerId, channel: frame.channel }, sealed, FrameKind.sealed);
    return { bytes: sealed.length, completed: peer.records.send(record, () =>
      this.sessions.get(peerId) === session && !frame.signal?.aborted && frame.authorized?.() !== false,
    ).then((outcome) => {
      if (outcome === "sent") this.recordNativeWrite(sealed, record.length, frame.channel, FrameKind.sealed, frame.type, frame.streamId);
      return outcome === "sent";
    }) };
  }

  protected override sendPayload(data: Buffer | string, to: string, channel: Channel = "control", kind = FrameKind.sealed,
    diagnosticType = "transport", streamId?: string): boolean {
    if (!this.authorized(to, this.nativePeers.get(to)?.endpointId)) return false;
    const peer = this.nativePeers.get(to);
    if (!peer) {
      if (streamId && streamId !== CONTROL_STREAM_ID && !this.centralStreams.has(streamId)) return false;
      return this.nativeOpts.mode !== "iroh-only" && super.sendPayload(data, to, channel, kind, diagnosticType, streamId);
    }
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

  override close(): void {
    this.stopped = true;
    this.lifetime++;
    if (this.refreshTimer) clearInterval(this.refreshTimer);
    this.refreshTimer = null;
    this.lease.invalidate("closed");
    this.enrollment.close();
    void this.endpoint?.close();
    this.endpoint = null;
    super.close();
  }
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
