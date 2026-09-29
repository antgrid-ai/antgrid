/**
 * Tunnel TCP streams. Each TCP connection a preview page opens on the phone is
 * one QUIC bidi stream: after the open frame the app sends one length-prefixed
 * JSON head record naming the port, the bridge answers with one length-prefixed
 * reply record, and from then on every byte in either direction is raw TCP
 * payload. Nothing here parses HTTP, so headers, cookies, WebSockets and TLS
 * all cross untouched. No tunnel traffic ever rides the project stream.
 *
 * Registered into `PeerStreamAcceptor` as the `tunnel-tcp` handler via
 * `handlerFor`. Admission (the per-peer cap, the safe-id/catalog checks, the
 * project's own binding lookup) lives once in `ScopedStreamRegistry`
 * (`stream-dispatch.ts`); this file owns the head-record shape, the probe, and
 * the raw pipe — the real per-checkout authorization runs through
 * `TunnelStreamServer.admit` once the head record names a checkout, since the
 * stream-open wire schema carries no `checkoutId`.
 */

import { STREAM_MAX_TUNNEL_STREAMS_PER_PEER, STREAM_TUNNEL_TCP_RECORD_MAX_BYTES, type TunnelTcpStreamOpen } from "antgrid-wire";
import { TunnelTcpOpen, type TunnelTcpError, type TunnelTcpReady } from "../tunnel-protocol";
import type { TunnelManager } from "../tunnel-manager";
import type { TunnelTcpPeer, TunnelTcpUpstreamSink } from "../tunnel-tcp";
import {
  defaultSchedule,
  raceDeadline,
  READ_ENDED,
  READ_UNBOUND,
  ScopedStreamRegistry,
  STREAM_DEADLINE,
  STREAM_OPEN_DEADLINE_MS,
  STREAM_RESET_SCOPED,
  STREAM_STOP_SCOPED,
  type ScopedBinding,
  type ScopedEndCause,
  type ScopedStreamOptions,
  type Schedule,
} from "./stream-dispatch";
import {
  StreamRawReader,
  StreamRecordReader,
  STREAM_RAW_READ_BYTES,
  type StreamSendOutcome,
} from "./stream-records";
import type { TunnelProjectBinding } from "../project-streams";

export const TUNNEL_STREAM_MAX_QUEUED_BYTES = 4 * 1024 * 1024;
/** Below session (2), terminal (1) and project (0). Tunnel traffic is a page
 *  load, not a live viewer — it never needs to preempt any of them. */
export const STREAM_PRIORITY_TUNNEL = -1;

const textEncoder = new TextEncoder();
const strictDecoder = new TextDecoder("utf-8", { fatal: true });

function encodeJsonRecord(record: unknown): Uint8Array {
  return textEncoder.encode(JSON.stringify(record));
}

function parseJsonRecord(bytes: Uint8Array): { ok: true; value: unknown } | { ok: false } {
  try {
    return { ok: true, value: JSON.parse(strictDecoder.decode(bytes)) };
  } catch {
    return { ok: false };
  }
}

interface TunnelTcpBinding extends ScopedBinding<TunnelProjectBinding> {
  readonly kind: "tunnel-tcp";
  readonly reader: StreamRecordReader;
  /** Upstream half of a forwarded connection; absent for a probe and until
   *  the manager has been asked to dial. */
  sink: TunnelTcpUpstreamSink | undefined;
  /** The registry itself is tearing the binding down, so the upstream's own
   *  "I ended" callback must not turn that abnormal end into a clean FIN. */
  closing: boolean;
  /** `writer.finish()` has been issued for the stream's final record or FIN. */
  finishing: boolean;
}

export type TunnelStreamRegistryOptions = ScopedStreamOptions<TunnelProjectBinding>;

/** `(peerId, "tunnel-tcp", connId) -> binding`, registered via
 *  `handlerFor("tunnel-tcp")`. */
export class TunnelStreamRegistry extends ScopedStreamRegistry<
  TunnelTcpStreamOpen,
  TunnelTcpBinding,
  TunnelProjectBinding
> {
  private readonly scheduleFn: Schedule;

  constructor(opts: TunnelStreamRegistryOptions) {
    super({
      kinds: ["tunnel-tcp"],
      cap: STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
      capMessage: "too many tunnel streams",
      priority: STREAM_PRIORITY_TUNNEL,
      resetCode: STREAM_RESET_SCOPED,
      stopCode: STREAM_STOP_SCOPED,
      maxQueuedBytes: TUNNEL_STREAM_MAX_QUEUED_BYTES,
    }, opts);
    this.scheduleFn = opts.schedule ?? defaultSchedule;
  }

  protected idOf(open: TunnelTcpStreamOpen): string {
    return open.connId;
  }

  protected available(project: TunnelProjectBinding) {
    return project.tunnels() === null
      ? { code: "NOT_ALLOWED" as const, message: "tunnels not available" }
      : undefined;
  }

  protected createBinding(base: ScopedBinding<TunnelProjectBinding>, _open: TunnelTcpStreamOpen): TunnelTcpBinding {
    let binding!: TunnelTcpBinding;
    const reader = new StreamRecordReader(
      base.stream,
      STREAM_TUNNEL_TCP_RECORD_MAX_BYTES,
      () => { if (!binding.unbound) this.opts.retirePeer(base.peerId, "protocol-violation"); },
    );
    binding = { ...base, kind: "tunnel-tcp", reader, sink: undefined, closing: false, finishing: false };
    return binding;
  }

  protected serve(binding: TunnelTcpBinding): void {
    void this.runHead(binding);
  }

  /** Every abnormal cause ends the upstream socket the same way. `closing`
   *  goes up first because the upstream answers `end()` with its own
   *  "finished" callback, which would otherwise queue a FIN behind the abort
   *  this teardown is about to issue. */
  protected onEnded(binding: TunnelTcpBinding, _cause: ScopedEndCause): void {
    binding.closing = true;
    binding.sink?.end();
  }

  // ---- Async phase: head ---------------------------------------------------

  /** Reads exactly one record under `STREAM_OPEN_DEADLINE_MS`. On a timeout
   *  the read is still outstanding and holds the recv mutex, so only the slot
   *  and the send half go now; the receive half is stopped once that read
   *  later resolves, but not if it rejects — a reset means the peer's own
   *  send half is already gone, so there is nothing left to stop. */
  private async readHeadRecord(binding: TunnelTcpBinding): Promise<Uint8Array | undefined> {
    const readPromise = binding.reader.read();
    binding.pendingRead = readPromise;
    const outcome = await raceDeadline(readPromise, STREAM_OPEN_DEADLINE_MS, this.scheduleFn)
      .catch(() => "ended" as const);
    if (outcome === STREAM_DEADLINE) {
      binding.writer.abort();
      this.release(binding);
      readPromise.then(() => this.stopRecv(binding), () => {});
      return undefined;
    }
    binding.pendingRead = null;
    if (outcome === "ended") {
      // The app reset or FIN'd before its head (a cancel while opening): the
      // slot must go now, or every such cancel leaks one of the peer's
      // STREAM_MAX_TUNNEL_STREAMS_PER_PEER until the connection retires. The
      // read has already settled, so recv needs no stop.
      binding.writer.abort();
      this.release(binding);
      return undefined;
    }
    if (binding.unbound) {
      this.stopRecv(binding);
      return undefined;
    }
    return outcome;
  }

  /** Read under the open deadline, recheck authorization, decode the one JSON
   *  head record and check it against the schema and the open frame's own
   *  `connId` — refusing inline (and returning `undefined`) on any failure. */
  private async parseHead(binding: TunnelTcpBinding): Promise<TunnelTcpOpen | undefined> {
    const record = await this.readHeadRecord(binding);
    if (record === undefined) return undefined; // timeout, or the app's FIN/reset before a head ever arrived
    if (!this.stillAuthorized(binding)) return undefined;

    const json = parseJsonRecord(record);
    if (!json.ok) {
      this.refuseInline(binding, { code: "INVALID", message: "malformed JSON" });
      return undefined;
    }
    const parsed = TunnelTcpOpen.safeParse(json.value);
    if (!parsed.success || parsed.data.connId !== binding.id) {
      this.refuseInline(binding, { code: "INVALID", message: "malformed tunnel:tcp-open" });
      return undefined;
    }
    return parsed.data;
  }

  /** The `tunnels()?.admit` call and its refusal handling. */
  private admitTunnel(binding: TunnelTcpBinding, checkoutId: string): TunnelManager | undefined {
    const admission = binding.project.tunnels()?.admit(binding.peerId, checkoutId) ?? null;
    if (admission === null) {
      this.refuseInline(binding, { code: "NOT_ALLOWED", message: "tunnels not available" });
      return undefined;
    }
    if (!admission.ok) {
      this.refuseInline(binding, admission.refusal);
      return undefined;
    }
    return admission.manager;
  }

  private async runHead(binding: TunnelTcpBinding): Promise<void> {
    const open = await this.parseHead(binding);
    if (open === undefined) return;

    const manager = this.admitTunnel(binding, open.checkoutId);
    if (!manager) return;

    if (open.probe) {
      await this.runProbe(binding, open, manager);
      return;
    }
    this.runForward(binding, open, manager);
  }

  // ---- Probe ---------------------------------------------------------------

  private async runProbe(binding: TunnelTcpBinding, open: TunnelTcpOpen, manager: TunnelManager): Promise<void> {
    const result = await manager.probeTcp(open.port);
    // Ended while probing (peer dropped, project detached): nothing to answer.
    if (binding.unbound) return;
    if (result.reachable) {
      await this.replyThenFinish(binding, { type: "tunnel:tcp-ready", connId: binding.id, tls: result.tls } satisfies TunnelTcpReady);
    } else {
      this.diag(binding, "tunnel-stream:tcp-unreachable", { peerId: binding.peerId, connId: binding.id, reason: result.message });
      await this.replyThenFinish(binding, { type: "tunnel:tcp-error", connId: binding.id, message: result.message } satisfies TunnelTcpError);
    }
  }

  // ---- Forward -------------------------------------------------------------

  private runForward(binding: TunnelTcpBinding, open: TunnelTcpOpen, manager: TunnelManager): void {
    const peer: TunnelTcpPeer = {
      ready: async () => {
        const outcome = await this.sendRecord(binding, { type: "tunnel:tcp-ready", connId: binding.id } satisfies TunnelTcpReady);
        // The app may not send before it has read the ready record, so the raw
        // pump only starts once that record is queued.
        if (outcome === "sent") void this.pumpFromApp(binding);
        return outcome;
      },
      unreachable: (message) => {
        this.diag(binding, "tunnel-stream:tcp-unreachable", { peerId: binding.peerId, connId: binding.id, reason: message });
        void this.replyThenFinish(binding, { type: "tunnel:tcp-error", connId: binding.id, message } satisfies TunnelTcpError);
      },
      data: async (bytes) => {
        if (this.undeliverable(binding)) return "dropped";
        return binding.writer.sendRaw(bytes);
      },
      end: () => { void this.finishStream(binding); },
    };
    binding.sink = manager.serveTcp(open, peer);
    // A manager may fail a run before it returns, and the teardown that
    // followed found no sink to end.
    if (binding.closing) binding.sink.end();
  }

  /** The per-receiver gate every outbound tunnel record passes: a peer that
   *  may no longer receive from this project ends the exchange instead. */
  private undeliverable(binding: TunnelTcpBinding): boolean {
    if (binding.project.mayDeliverTo(binding.peerId)) return false;
    this.end(binding, "app-ended");
    return true;
  }

  private async sendRecord(binding: TunnelTcpBinding, record: unknown): Promise<StreamSendOutcome> {
    if (binding.unbound || binding.closing) return "dropped";
    if (this.undeliverable(binding)) return "dropped";
    return binding.writer.send(encodeJsonRecord(record));
  }

  /** The stream's one reply record followed by FIN, for a probe's answer or an
   *  upstream that never came up. */
  private async replyThenFinish(binding: TunnelTcpBinding, record: unknown): Promise<void> {
    if (binding.unbound || binding.finishing) return;
    const outcome = await this.sendRecord(binding, record);
    if (outcome !== "sent") return;
    await this.finishStream(binding);
  }

  /** A clean FIN and a reset are natively distinguishable on the wire, so
   *  `writer.finish()` alone is the "done" signal. A voluntary, graceful end on
   *  the stream's own terms: `release`, not `end` — nothing failed, so nothing
   *  should be re-aborted. The receive half is stopped once any raw read still
   *  outstanding settles, which is when the app's own FIN or reset arrives. */
  private async finishStream(binding: TunnelTcpBinding): Promise<void> {
    if (binding.unbound || binding.closing || binding.finishing) return;
    if (this.undeliverable(binding)) return;
    binding.finishing = true;
    await binding.writer.finish();
    const pending = binding.pendingRead;
    this.release(binding);
    this.stopRecv(binding, pending);
  }

  /** App bytes into the upstream socket, one read at a time: the next read is
   *  not issued until the socket has taken the previous bytes, so the app's
   *  send window is what paces a slow upstream. The app's FIN or reset ends the
   *  connection — gracefully on the upstream, since half-close is not modelled. */
  private async pumpFromApp(binding: TunnelTcpBinding): Promise<void> {
    const raw = new StreamRawReader(binding.stream);
    for (;;) {
      if (binding.unbound) return;
      const bytes = await this.trackRead(binding, raw.read(STREAM_RAW_READ_BYTES));
      if (bytes === READ_UNBOUND) return;
      if (!this.stillAuthorized(binding)) return;
      if (bytes === READ_ENDED || bytes === null) {
        binding.sink?.end();
        return;
      }
      await binding.sink?.write(bytes);
    }
  }
}
