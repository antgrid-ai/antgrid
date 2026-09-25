/// Tunnel-stream wire records and the transport-agnostic handles
/// (`TunnelHttpExchange`, `TunnelWsChannel`) that `terminal_service.dart`'s
/// preview counterpart drives. The stream-backed implementations live in
/// `machine_session.dart`'s `StreamTransport` (mirroring how
/// `_StreamTerminalAttachment` sits beside `terminal_attachment.dart`'s
/// interfaces); this file holds only the shapes both sides share plus the
/// record codec, and never talks to a `PeerStream` directly.
///
/// `preview_service.dart`'s queue and policy stay in `app/` — nothing here was
/// moved or adapted from it (stage-A-A3-contract.md §4.1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models/stream_open.dart';

/// Bounds one tunnel stream's writer queue on the app side. HTTP awaits every
/// send, so it never approaches this; WS upstream messages are events the app
/// cannot await, so this is how many maximum-size frames may queue before the
/// stream is reset (mirrors the bridge's `TUNNEL_STREAM_MAX_QUEUED_BYTES`,
/// which is 4 MiB because it also covers the bridge's own flush cadence).
const int kTunnelStreamMaxQueuedBytes = 2097152;

/// One `tunnel:http-head` record, decoded.
final class TunnelHttpHead {
  final int status;
  final Map<String, String> headers;
  final List<String> setCookies;

  const TunnelHttpHead({
    required this.status,
    required this.headers,
    this.setCookies = const [],
  });
}

/// One HTTP body record. [gzip] is true for tag [kTunnelRecordTagBodyGzip];
/// the reader inflates it, one independent gzip member per record.
final class TunnelBodyRecord {
  final Uint8List bytes;
  final bool gzip;

  const TunnelBodyRecord({required this.bytes, required this.gzip});
}

/// One WebSocket message. A text message's `bytes` are its UTF-8 encoding.
final class TunnelWsFrame {
  final bool binary;
  final Uint8List bytes;

  const TunnelWsFrame({required this.binary, required this.bytes});
}

/// Why a tunnel exchange or channel ended in failure.
///
/// `code` is one of: `REFUSED` ([refusal] set), `NOT_SUPPORTED`,
/// `STREAM_UNBOUND`, `STREAM_OPEN_FAILED`, `SEND_FAILED`, `STREAM_ENDED`,
/// `TRUNCATED`, `PROTOCOL`, `CANCELLED`, `TRANSPORT_CLOSED`.
final class TunnelExchangeFailure implements Exception {
  final String code;
  final StreamRefused? refusal;
  final Object? error;

  const TunnelExchangeFailure(this.code, {this.refusal, this.error});

  @override
  String toString() => 'TunnelExchangeFailure($code)';
}

/// One HTTP request/response pair riding its own stream.
abstract interface class TunnelHttpExchange {
  String get requestId;

  /// Completes with the head, or errors with [TunnelExchangeFailure]. Never
  /// an unhandled error.
  Future<TunnelHttpHead> get head;

  /// Single-subscription. Done after `tunnel:http-end`; errors
  /// [TunnelExchangeFailure] (`TRUNCATED` / `PROTOCOL` / `CANCELLED` /
  /// `TRANSPORT_CLOSED`).
  Stream<TunnelBodyRecord> get body;

  /// Idempotent. Waiting for a slot: leave the queue and never open. Opening
  /// or open: reset the send half (or abandon the pending open) and keep
  /// draining any records already in flight.
  void cancel();
}

/// Why a [TunnelWsChannel.done] completed.
sealed class TunnelWsEnd {
  const TunnelWsEnd();
}

final class TunnelWsClosedByPeer extends TunnelWsEnd {
  final int? code;
  final String? reason;

  const TunnelWsClosedByPeer(this.code, this.reason);
}

final class TunnelWsClosedLocally extends TunnelWsEnd {
  const TunnelWsClosedLocally();
}

final class TunnelWsFailed extends TunnelWsEnd {
  final TunnelExchangeFailure failure;

  const TunnelWsFailed(this.failure);
}

/// One browser-side WebSocket's tunnel for its whole lifetime.
abstract interface class TunnelWsChannel {
  String get tunnelId;

  /// bridge -> browser, in order; closes when [done] completes.
  Stream<TunnelWsFrame> get frames;

  /// Completes once, never errors.
  Future<TunnelWsEnd> get done;

  /// Serialized in call order, including calls made before the stream opens.
  /// `true` = accepted. `false` = the channel is dead (it has already
  /// reset). A frame over [kStreamTunnelDataMaxBytes] resets it.
  Future<bool> send(TunnelWsFrame frame);

  /// Writes `tunnel:ws-close` after every queued frame, then finishes.
  /// Idempotent.
  void close({int? code, String? reason});

  /// Resets with no close record. Idempotent.
  void abort();
}

/// One decoded tunnel-stream record body (the framing length prefix is
/// already stripped by [PeerStream]).
sealed class TunnelRecord {}

final class TunnelJsonRecord extends TunnelRecord {
  final String text;

  TunnelJsonRecord(this.text);
}

final class TunnelDataRecord extends TunnelRecord {
  final int tag;
  final Uint8List payload;

  TunnelDataRecord(this.tag, this.payload);
}

/// One tag byte plus [payload]. Throws [RangeError] for an unknown tag or a
/// payload over [kStreamTunnelDataMaxBytes].
Uint8List encodeTunnelDataRecord(int tag, Uint8List payload) {
  if (tag < kTunnelRecordTagBody || tag > kTunnelRecordTagWsBinary) {
    throw RangeError.value(tag, 'tag', 'unknown tunnel data tag');
  }
  if (payload.length > kStreamTunnelDataMaxBytes) {
    throw RangeError.value(
      payload.length,
      'payload.length',
      'over kStreamTunnelDataMaxBytes',
    );
  }
  final out = Uint8List(payload.length + 1);
  out[0] = tag;
  out.setRange(1, out.length, payload);
  return out;
}

/// `null` for an empty record, an unknown tag, or a first byte of 0x7B whose
/// body is not valid UTF-8. The returned payload is a view, not a copy.
TunnelRecord? decodeTunnelRecord(Uint8List record) {
  if (record.isEmpty) return null;
  final first = record[0];
  if (first == 0x7B) {
    try {
      return TunnelJsonRecord(utf8.decode(record, allowMalformed: false));
    } catch (_) {
      return null;
    }
  }
  if (first < kTunnelRecordTagBody || first > kTunnelRecordTagWsBinary) {
    return null;
  }
  return TunnelDataRecord(first, Uint8List.sublistView(record, 1));
}

/// A [TunnelHttpExchange] that never opened a stream — [failure] is already
/// set. Shared by [BufferedAgentTransport]'s default (`NOT_SUPPORTED`) and by
/// a `StreamTransport` that fails before attempting an open (`STREAM_UNBOUND`,
/// `TRANSPORT_CLOSED`).
final class FailedTunnelHttpExchange implements TunnelHttpExchange {
  FailedTunnelHttpExchange(this.requestId, TunnelExchangeFailure failure)
    : _headCompleter = Completer<TunnelHttpHead>(),
      _bodyController = StreamController<TunnelBodyRecord>() {
    // A caller that reads only one of head/body must never see the other
    // one's error surface as unhandled (contract §4.1's shared note on this
    // pair) — the buffered stream error below is only ever delivered once
    // something actually listens, so only the Future side needs a silencer.
    _headCompleter.future.ignore();
    _headCompleter.completeError(failure);
    _bodyController.addError(failure);
    unawaited(_bodyController.close());
  }

  @override
  final String requestId;

  final Completer<TunnelHttpHead> _headCompleter;
  final StreamController<TunnelBodyRecord> _bodyController;

  @override
  Future<TunnelHttpHead> get head => _headCompleter.future;

  @override
  Stream<TunnelBodyRecord> get body => _bodyController.stream;

  @override
  void cancel() {}
}

/// A [TunnelWsChannel] that never opened a stream — [done] already completed
/// [TunnelWsFailed]. Same role as [FailedTunnelHttpExchange].
final class FailedTunnelWsChannel implements TunnelWsChannel {
  FailedTunnelWsChannel(this.tunnelId, TunnelExchangeFailure failure)
    : _framesController = StreamController<TunnelWsFrame>(),
      _doneCompleter = Completer<TunnelWsEnd>() {
    _doneCompleter.complete(TunnelWsFailed(failure));
    unawaited(_framesController.close());
  }

  @override
  final String tunnelId;

  final StreamController<TunnelWsFrame> _framesController;
  final Completer<TunnelWsEnd> _doneCompleter;

  @override
  Stream<TunnelWsFrame> get frames => _framesController.stream;

  @override
  Future<TunnelWsEnd> get done => _doneCompleter.future;

  @override
  Future<bool> send(TunnelWsFrame frame) async => false;

  @override
  void close({int? code, String? reason}) {}

  @override
  void abort() {}
}
