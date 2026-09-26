/// Upload handles: the transport-agnostic surface `upload_service.dart` drives
/// regardless of whether the upload rides its own native QUIC stream
/// (`MachineSession`'s `StreamTransport`, see `machine_session.dart`) or the
/// loopback path (`LocalTransport`'s `file:upload-local`, see
/// `local_transport.dart`). Mirrors `terminal_attachment.dart`'s split.
library;

import 'dart:async';

import 'models/stream_open.dart';

/// Largest piece the stream path writes per `sendRaw` call.
const int kUploadStreamSliceBytes = 262144;

/// Bounds the stream path's writer queue (`PeerLink.openStream`'s
/// `maxQueuedBytes`) — HTTP-sized uploads await every write, so this only
/// guards against a burst of unusually large slices queuing ahead of the
/// native binding draining them.
const int kUploadStreamMaxQueuedBytes = 524288;

/// How long either path waits for its next expected reply — the bridge's
/// single `file:upload-result` record, whether that follows the stream
/// path's `finish()` or the loopback exchange's `file:upload-local` send —
/// before giving up.
const Duration kUploadResultTimeout = Duration(seconds: 30);

/// One `file:upload-result` JSON, decoded loosely enough to serve both paths.
final class UploadStreamResult {
  final bool ok;
  final String? uploadId;
  final String? path;
  final String? relPath;
  final String? mimeType;
  final String? error;
  final String? message;

  const UploadStreamResult({
    required this.ok,
    this.uploadId,
    this.path,
    this.relPath,
    this.mimeType,
    this.error,
    this.message,
  });

  /// `null` unless [json] is a `file:upload-result` whose `requestId` matches
  /// [requestId] — the check a stream-path reader needs, since its one
  /// incoming record could otherwise be any decodable JSON.
  static UploadStreamResult? tryParse(
    Map<String, dynamic> json, {
    required String requestId,
  }) {
    if (json['type'] != 'file:upload-result') return null;
    if (json['requestId'] != requestId) return null;
    final ok = json['ok'];
    if (ok is! bool) return null;
    return UploadStreamResult(
      ok: ok,
      uploadId: json['uploadId'] as String?,
      path: json['path'] as String?,
      relPath: json['relPath'] as String?,
      mimeType: json['mimeType'] as String?,
      error: json['error'] as String?,
      message: json['message'] as String?,
    );
  }
}

/// Why [UploadExchange.result] errored instead of settling a
/// [UploadStreamResult]. `code` is one of `REFUSED` (`refusedCode` set),
/// `NOT_SUPPORTED`, `STREAM_OPEN_FAILED`, `SEND_FAILED`, `STREAM_ENDED`,
/// `PROTOCOL`, `INVALID_NAME`, `CANCELLED`, `TIMEOUT`, `TRANSPORT_CLOSED`.
final class UploadFailure implements Exception {
  final String code;
  final StreamRefusedCode? refusedCode;
  final String? message;

  const UploadFailure(this.code, {this.refusedCode, this.message});

  @override
  String toString() => 'UploadFailure($code)';
}

/// One file upload and whatever exchange carries it.
abstract interface class UploadExchange {
  String get requestId;

  /// The bridge's result, or an [UploadFailure]. Never an unhandled error.
  Future<UploadStreamResult> get result;

  /// Idempotent. Resets the send half (or leaves the slot queue, on the
  /// stream path) and fails [result] `CANCELLED`.
  void cancel();
}

/// An [UploadExchange] that never started — [failure] is already set.
/// [requestId] defaults to `''` for a caller with no exchange to name yet
/// (e.g. `BufferedAgentTransport`'s base `NOT_SUPPORTED`).
final class FailedUploadExchange implements UploadExchange {
  FailedUploadExchange(UploadFailure failure, [this.requestId = ''])
    : _resultCompleter = Completer<UploadStreamResult>() {
    // Mirrors FailedTunnelHttpExchange: a caller that never awaits `result`
    // must not turn this into an unhandled error.
    _resultCompleter.future.ignore();
    _resultCompleter.completeError(failure);
  }

  @override
  final String requestId;

  final Completer<UploadStreamResult> _resultCompleter;

  @override
  Future<UploadStreamResult> get result => _resultCompleter.future;

  @override
  void cancel() {}
}
