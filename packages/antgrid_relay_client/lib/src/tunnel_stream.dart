/// The transport-agnostic handle (`TunnelTcpChannel`) that the app's preview
/// forwarder drives. The stream-backed implementation lives in
/// `machine_session.dart`'s `StreamTransport` (mirroring how
/// `_StreamTerminalAttachment` sits beside `terminal_attachment.dart`'s
/// interfaces); this file holds only the shapes both sides share and never
/// talks to a `PeerStream` directly.
library;

import 'dart:async';
import 'dart:typed_data';

import 'models/stream_open.dart';

/// Bounds one tunnel stream's writer queue on the app side. The forwarder
/// awaits every send, so it never approaches this; the bound is the backstop
/// that resets a stream whose caller stops awaiting. The bridge's own bound,
/// `TUNNEL_STREAM_MAX_QUEUED_BYTES`, is deliberately larger (4 MiB) than this
/// one; the two are independent limits on opposite writers.
const int kTunnelStreamMaxQueuedBytes = 2097152;

/// Why a tunnel channel ended in failure.
///
/// `code` is `REFUSED` when the bridge refused the open ([refusal] carries its
/// code and message), otherwise one of: `UNREACHABLE` (the bridge could not
/// reach the port), `STREAM_LOST` (the stream ended before the bridge
/// replied), `NOT_SUPPORTED`, `NO_PROJECT`, `STREAM_OPEN_FAILED`,
/// `SEND_FAILED`, `PROTOCOL`, `CANCELLED`, `TRANSPORT_CLOSED`.
final class TunnelExchangeFailure implements Exception {
  final String code;
  final StreamRefused? refusal;
  final Object? error;

  /// The bridge's human-readable reason, when it sent one.
  final String? message;

  const TunnelExchangeFailure(
    this.code, {
    this.refusal,
    this.error,
    this.message,
  });

  @override
  String toString() => 'TunnelExchangeFailure($code)';
}

/// The bridge's reply to a `tunnel:tcp-open`.
final class TunnelTcpReady {
  /// Whether the port speaks TLS. Non-null only for a probe.
  final bool? tls;

  const TunnelTcpReady({this.tls});
}

/// One forwarded TCP connection.
abstract interface class TunnelTcpChannel {
  String get connId;

  /// Completes when the bridge's reply record arrives. Errors with
  /// [TunnelExchangeFailure]: `REFUSED` (with `refusal`) for a refusal, `UNREACHABLE`
  /// for a bridge that could not reach the port, `STREAM_LOST` when the stream
  /// ends or resets first, `NOT_SUPPORTED` from a transport that cannot
  /// tunnel.
  Future<TunnelTcpReady> get ready;

  /// Single-subscription. Raw upstream bytes after [ready], exactly as the
  /// upstream wrote them. Done on the bridge's FIN; errors
  /// ([PeerStreamReset] or [TunnelExchangeFailure]) on a reset.
  Stream<Uint8List> get incoming;

  /// Queues raw bytes toward the upstream and completes once they are handed
  /// to the stream. Must be awaited before the next call — the queue resets
  /// the stream past [kTunnelStreamMaxQueuedBytes]. `false` once the channel
  /// is over, and before [ready] has completed.
  Future<bool> send(Uint8List bytes);

  /// Graceful end of the send half (FIN). Idempotent.
  Future<void> finish();

  /// Resets both halves. Idempotent.
  void abort();
}

/// A [TunnelTcpChannel] that never opened a stream — [ready] has already
/// failed with the given failure. Shared by [BufferedAgentTransport]'s default
/// (`NOT_SUPPORTED`).
final class FailedTunnelTcpChannel implements TunnelTcpChannel {
  FailedTunnelTcpChannel(this.connId, TunnelExchangeFailure failure)
    : _ready = Future<TunnelTcpReady>.error(failure)..ignore();

  @override
  final String connId;

  final Future<TunnelTcpReady> _ready;

  @override
  Future<TunnelTcpReady> get ready => _ready;

  @override
  Stream<Uint8List> get incoming => const Stream<Uint8List>.empty();

  @override
  Future<bool> send(Uint8List bytes) async => false;

  @override
  Future<void> finish() async {}

  @override
  void abort() {}
}
