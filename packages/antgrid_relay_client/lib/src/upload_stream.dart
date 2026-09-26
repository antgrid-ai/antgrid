/// Upload handles: the transport-agnostic surface `upload_service.dart` drives
/// regardless of whether the upload rides its own native QUIC stream
/// (`MachineSession`'s `StreamTransport`, see `machine_session.dart`) or the
/// loopback socket path ([SocketUploads], used by every [BufferedAgentTransport]
/// and by `FakeAgentTransport`). Mirrors `terminal_attachment.dart`'s split.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models/stream_open.dart';

/// Largest piece the stream path writes per `sendRaw` call.
const int kUploadStreamSliceBytes = 262144;

/// Bounds the stream path's writer queue (`MultiStreamPeerLink.openStream`'s
/// `maxQueuedBytes`) — HTTP-sized uploads await every write, so this only
/// guards against a burst of unusually large slices queuing ahead of the
/// native binding draining them.
const int kUploadStreamMaxQueuedBytes = 524288;

/// [SocketUploads]' chunk size — unrelated to [kUploadStreamSliceBytes], since
/// each chunk here is its own base64-encoded `AbMessage`.
const int kSocketUploadChunkBytes = 524288;

/// How long either path waits for its next expected reply (a chunk ack, the
/// final result, or — on the stream path — the bridge's result record after
/// `finish()`) before giving up.
const Duration kUploadResultTimeout = Duration(seconds: 30);

/// One `file:upload-result` JSON, decoded loosely enough to serve both paths:
/// the stream path's single response record and the socket path's ready/ack/
/// result trio, which share the same `ok`/`error`/`message` shape.
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
final class FailedUploadExchange implements UploadExchange {
  FailedUploadExchange(this.requestId, UploadFailure failure)
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

bool _isErrorReply(Map<String, dynamic> json) =>
    json['ok'] == false || json['error'] != null;

UploadStreamResult _resultFromReply(Map<String, dynamic> json) =>
    UploadStreamResult(
      ok: json['ok'] == true,
      uploadId: json['uploadId'] as String?,
      path: json['path'] as String?,
      relPath: json['relPath'] as String?,
      mimeType: json['mimeType'] as String?,
      error: json['error'] as String?,
      message: json['message'] as String?,
    );

/// Loopback: the `file:upload-start/ready/chunk/ack/done/result` exchange over
/// the transport's own send, in [kSocketUploadChunkBytes] base64 chunks, one
/// in flight at a time. Progress is reported on each ack, since there is no
/// byte-level write completion to measure on this path.
class SocketUploads {
  SocketUploads(this._send);

  final Future<void> Function(Map<String, dynamic> message) _send;

  final Map<String, _SocketUploadExchange> _byRequestId = {};
  // uploadId -> requestId. A dead or swept upload's result can cite only the
  // uploadId (requestId:""), so the waiter it must wake is looked up here.
  final Map<String, String> _requestIdByUploadId = {};

  UploadExchange open({
    required String requestId,
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) {
    final exchange = _SocketUploadExchange(
      requestId: requestId,
      onEnded: () => _forget(requestId),
    );
    _byRequestId[requestId] = exchange;
    unawaited(
      _run(
        exchange,
        projectId: projectId,
        checkoutId: checkoutId,
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        onProgress: onProgress,
      ),
    );
    return exchange;
  }

  void _forget(String requestId) {
    final exchange = _byRequestId.remove(requestId);
    if (exchange == null) return;
    _requestIdByUploadId.removeWhere((_, v) => v == requestId);
  }

  /// True when [json] was a ready/ack/result for an upload in flight and was
  /// consumed — the caller must then not publish it as an ordinary message.
  bool dispatch(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'file:upload-ready':
        final requestId = json['requestId'];
        if (requestId is! String) return false;
        final exchange = _byRequestId[requestId];
        if (exchange == null) return false;
        exchange._completeStep('start', json);
        return true;
      case 'file:upload-ack':
        final uploadId = json['uploadId'];
        final seq = json['seq'];
        if (uploadId is! String || seq is! int) return false;
        final requestId = _requestIdByUploadId[uploadId];
        final exchange = requestId != null ? _byRequestId[requestId] : null;
        if (exchange == null) return false;
        exchange._completeStep('ack:$seq', json);
        return true;
      case 'file:upload-result':
        final requestId = json['requestId'];
        final uploadId = json['uploadId'];
        var exchange = requestId is String && requestId.isNotEmpty
            ? _byRequestId[requestId]
            : null;
        if (exchange == null && uploadId is String) {
          final resolvedRequestId = _requestIdByUploadId[uploadId];
          exchange = resolvedRequestId != null
              ? _byRequestId[resolvedRequestId]
              : null;
        }
        if (exchange == null) return false;
        // A result can arrive as the reply to `file:upload-start` (an
        // immediate per-file refusal) or after the chunk loop — completing
        // both keys is a no-op for whichever one already resolved.
        exchange._completeStep('start', json);
        exchange._completeStep('done', json);
        if (json['ok'] == false) exchange._failPendingAcks(json);
        return true;
      default:
        return false;
    }
  }

  Future<void> _run(
    _SocketUploadExchange exchange, {
    required String projectId,
    required String checkoutId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      // Every step waiter is registered BEFORE its send: the loopback socket
      // can hand the reply to [dispatch] before the send future resumes this
      // loop, and a reply with no waiter is consumed and lost.
      final startReplyF = exchange._awaitStep('start');
      await _send(_message({
        'type': 'file:upload-start',
        'projectId': projectId,
        'checkoutId': checkoutId,
        'requestId': exchange.requestId,
        'fileName': fileName,
        'size': bytes.length,
        if (mimeType != null) 'mimeType': mimeType,
      }));
      final startReply = await startReplyF;
      if (_isErrorReply(startReply)) {
        exchange._complete(_resultFromReply(startReply));
        return;
      }
      final uploadId = startReply['uploadId'];
      if (uploadId is! String) {
        exchange._fail(const UploadFailure('PROTOCOL'));
        return;
      }
      _requestIdByUploadId[uploadId] = exchange.requestId;
      var seq = 0;
      for (var off = 0; off < bytes.length; off += kSocketUploadChunkBytes) {
        if (exchange._cancelled) {
          exchange._fail(const UploadFailure('CANCELLED'));
          return;
        }
        final end = math.min(off + kSocketUploadChunkBytes, bytes.length);
        final ackReplyF = exchange._awaitStep('ack:$seq');
        await _send(_message({
          'type': 'file:upload-chunk',
          'uploadId': uploadId,
          'seq': seq,
          'data': base64Encode(Uint8List.sublistView(bytes, off, end)),
        }));
        final ackReply = await ackReplyF;
        if (_isErrorReply(ackReply)) {
          exchange._complete(_resultFromReply(ackReply));
          return;
        }
        onProgress?.call(end, bytes.length);
        seq++;
      }
      if (exchange._cancelled) {
        exchange._fail(const UploadFailure('CANCELLED'));
        return;
      }
      final resultReplyF = exchange._awaitStep('done');
      await _send(
        _message({'type': 'file:upload-done', 'uploadId': uploadId}),
      );
      final resultReply = await resultReplyF;
      exchange._complete(_resultFromReply(resultReply));
    } on UploadFailure catch (failure) {
      exchange._fail(failure);
    } catch (error) {
      exchange._fail(UploadFailure('PROTOCOL', message: '$error'));
    } finally {
      exchange._dropPendingSteps();
    }
  }
}

final math.Random _idRandom = math.Random.secure();

/// A random UUID v4: the bridge's `BaseMessage` shape, and the frame id a
/// netwatch capture joins the two ends on.
String _uuidV4() {
  final b = List<int>.generate(16, (_) => _idRandom.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<String, dynamic> _message(Map<String, dynamic> fields) => {
  'id': _uuidV4(),
  'timestamp': DateTime.now().millisecondsSinceEpoch,
  ...fields,
};

class _SocketUploadExchange implements UploadExchange {
  _SocketUploadExchange({required this.requestId, required void Function() onEnded})
    : _onEnded = onEnded;

  @override
  final String requestId;

  final void Function() _onEnded;
  final Completer<UploadStreamResult> _resultCompleter = Completer();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  bool _cancelled = false;
  bool _ended = false;

  @override
  Future<UploadStreamResult> get result => _resultCompleter.future;

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // Wakes whichever step this upload is currently waiting on now, instead
    // of leaving it to run out kUploadResultTimeout.
    final keys = _pending.keys.toList();
    for (final key in keys) {
      _pending.remove(key)?.completeError(const UploadFailure('CANCELLED'));
    }
  }

  final Map<String, Timer> _stepTimers = {};

  /// Registered before the step's send goes out, so the returned future can
  /// fail (a cancel, the timeout) before anything awaits it; it is marked
  /// ignored so that failure is never an unhandled error, while an await
  /// still sees it.
  Future<Map<String, dynamic>> _awaitStep(String key) {
    final completer = Completer<Map<String, dynamic>>();
    _pending[key] = completer;
    _stepTimers[key] = Timer(kUploadResultTimeout, () {
      if (identical(_pending[key], completer)) {
        _pending.remove(key);
        completer.completeError(const UploadFailure('TIMEOUT'));
      }
    });
    final future = completer.future.whenComplete(
      () => _stepTimers.remove(key)?.cancel(),
    );
    future.ignore();
    return future;
  }

  /// Drops every waiter the run left behind (a send that threw after its
  /// step was registered), timers included.
  void _dropPendingSteps() {
    _pending.clear();
    for (final timer in _stepTimers.values) {
      timer.cancel();
    }
    _stepTimers.clear();
  }

  void _completeStep(String key, Map<String, dynamic> json) {
    _pending.remove(key)?.complete(json);
  }

  void _failPendingAcks(Map<String, dynamic> json) {
    final ackKeys = _pending.keys.where((k) => k.startsWith('ack:')).toList();
    for (final key in ackKeys) {
      _pending.remove(key)?.complete(json);
    }
  }

  void _fail(UploadFailure failure) {
    if (_ended) return;
    _ended = true;
    _onEnded();
    if (!_resultCompleter.isCompleted) _resultCompleter.completeError(failure);
  }

  void _complete(UploadStreamResult result) {
    if (_ended) return;
    _ended = true;
    _onEnded();
    if (!_resultCompleter.isCompleted) _resultCompleter.complete(result);
  }
}
