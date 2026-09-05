import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../models/ab_message.dart';
import '../project/project_session.dart';
import 'pending_reply.dart';

/// Upload failure with a machine [code] (mirrors the bridge's
/// file:upload-result error codes, plus app-side OFFLINE/TIMEOUT/CANCELLED).
class UploadException implements Exception {
  final String code;
  final String message;
  const UploadException(this.code, this.message);

  @override
  String toString() => 'UploadException($code): $message';
}

/// A one-shot cancel signal for [UploadService.upload]. Cancelling stops the
/// chunk loop at its next check and races any in-flight ack wait (see
/// `_raceCancel`), so the upload aborts within one round trip rather than
/// waiting out the 30s step timeout — the bridge is left to sweep the
/// abandoned uploadId itself, the same path an expired upload already takes.
class UploadCancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Snackbar copy for any upload failure. Every failure path in the attach and
/// terminal-upload flows funnels through this so the user always sees a
/// specific, human-readable reason.
String uploadErrorText(Object error, String fileName) {
  if (error is UploadException) {
    switch (error.code) {
      case 'TOO_LARGE':
        return '"$fileName" is larger than the 20 MB upload limit';
      case 'OFFLINE':
        return 'Not connected to the agent — cannot upload "$fileName"';
      case 'TIMEOUT':
        return 'Upload of "$fileName" timed out';
      case 'CANCELLED':
        return 'Upload of "$fileName" was cancelled';
      case 'BUSY':
        return 'Too many uploads in progress — try again in a moment';
      case 'INVALID_NAME':
        return '"$fileName" has an unsupported file name';
      default:
        return 'Upload of "$fileName" failed: '
            '${error.message.isEmpty ? error.code : error.message}';
    }
  }
  if (error is TimeoutException) return 'Upload of "$fileName" timed out';
  return 'Upload of "$fileName" failed';
}

/// A file staged on the bridge, as reported by `file:upload-result`.
class UploadResult {
  const UploadResult({required this.path, this.relPath, this.mimeType});

  /// Absolute on the bridge machine — what goes into the prompt text, since
  /// that is the form every agent CLI can open.
  final String path;

  /// Project-relative twin of [path], the only form `file:read` accepts. The
  /// app never learns the checkout root, so it cannot derive this itself.
  /// Null from a bridge predating the field — such an attachment simply
  /// offers no preview rather than guessing a path.
  final String? relPath;

  /// Set only when the bridge can render this type (its own
  /// `RENDERABLE_BINARY_MIME` table, the same one `file:read` answers from).
  /// Null means there is no viewer for it — which is exactly the
  /// "supported files only" gate, without an app-side allowlist to drift.
  final String? mimeType;

  /// Whether a preview can be offered at all: the bridge both named a
  /// readable path and admitted to having a viewer for it.
  bool get isPreviewable => relPath != null && mimeType != null;
}

/// Chunked file upload to the bridge's project-local staging dir.
///
/// One ack per chunk, next chunk sent only after the ack: every wire message
/// stays under the local transport's 1 MiB frame cap and the relay's frag
/// threshold, and a slow mobile uplink can't trip the 10s frag-reassembly
/// timeout that a single 20 MB message would hit.
class UploadService {
  static const int kMaxUploadBytes = 20 * 1024 * 1024;
  static const int kChunkBytes = 512 * 1024;
  static const Duration _kStepTimeout = Duration(seconds: 30);

  final ProjectSession session;
  final String checkoutId;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  final Map<String, PendingReply<Map<String, dynamic>>> _pending = {};
  // uploadId → the requestId its done-waiter is keyed by. Lets a failure result
  // that can only cite the uploadId (the bridge replies requestId:"" for a
  // swept/expired upload) still wake the pending `done:` wait instead of hanging.
  final Map<String, String> _requestIdByUpload = {};
  bool _disposed = false;

  UploadService.fromSession(this.session, {this.checkoutId = 'main'}) {
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onStatusJson);
  }

  void _onStatusJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'file:upload-ready':
        _complete('start:${j['requestId']}', j);
      case 'file:upload-ack':
        _complete('ack:${j['uploadId']}:${j['seq']}', j);
      case 'file:upload-result':
        _complete('start:${j['requestId']}', j);
        _complete('done:${j['requestId']}', j);
        // A mid-transfer abort (BAD_SEQUENCE/TIMEOUT/...) arrives while the
        // uploader is awaiting a chunk ack — fail that wait too.
        final uploadId = j['uploadId'];
        if (j['ok'] == false && uploadId is String) {
          // The result may cite requestId:"" (dead upload) — recover the real
          // requestId so a pending `done:` wait fails now instead of timing out.
          final rid = _requestIdByUpload[uploadId];
          if (rid != null) _complete('done:$rid', j);
          final ackKeys = _pending.keys
              .where((k) => k.startsWith('ack:$uploadId:'))
              .toList();
          for (final k in ackKeys) {
            _complete(k, j);
          }
        }
    }
  }

  void _complete(String key, Map<String, dynamic> j) {
    _pending.remove(key)?.complete(j);
  }

  Future<Map<String, dynamic>> _await(String key) {
    final pending = PendingReply<Map<String, dynamic>>(
      timeout: _kStepTimeout,
      onTimeout: () => _pending.remove(key),
      timeoutError: () =>
          const UploadException('TIMEOUT', 'No reply from the agent'),
    );
    _pending[key] = pending;
    return pending.future;
  }

  void _throwIfError(Map<String, dynamic> j) {
    if (j['ok'] == false || j['error'] != null) {
      throw UploadException(
        j['error'] as String? ?? 'UNKNOWN',
        j['message'] as String? ?? 'Upload failed',
      );
    }
  }

  /// Uploads [bytes] and returns where the bridge staged it. Throws
  /// [UploadException] on any failure, including `CANCELLED` once
  /// [cancelToken] has been cancelled.
  Future<UploadResult> upload({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    if (_disposed) {
      throw const UploadException('OFFLINE', 'Session closed');
    }
    if (bytes.length > kMaxUploadBytes) {
      throw const UploadException('TOO_LARGE', 'File exceeds 20 MB limit');
    }

    final requestId = const Uuid().v4();
    final startReplyF = _await('start:$requestId');
    await session.sendForCheckout(
      checkoutId,
      createAbMessage('file:upload-start', {
        'projectId': session.projectId,
        'requestId': requestId,
        'fileName': fileName,
        'size': bytes.length,
        'mimeType': ?mimeType,
      }),
    );
    final startReply = await _raceCancel(startReplyF, cancelToken);
    _throwIfError(startReply);
    final uploadId = startReply['uploadId'] as String;
    _requestIdByUpload[uploadId] = requestId;
    try {
      return await _streamChunksAndFinish(
        uploadId: uploadId,
        requestId: requestId,
        bytes: bytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } finally {
      _requestIdByUpload.remove(uploadId);
    }
  }

  /// Races a pending reply against [cancelToken] so a cancel lands within one
  /// round trip instead of waiting out [_kStepTimeout]. The losing side is
  /// left to resolve on its own — a late ack just completes an entry nothing
  /// is awaiting any more, same as it does today for a reply that arrives
  /// after this request already failed.
  Future<Map<String, dynamic>> _raceCancel(
    Future<Map<String, dynamic>> reply,
    UploadCancelToken? cancelToken,
  ) {
    if (cancelToken == null) return reply;
    return Future.any([
      reply,
      cancelToken.whenCancelled.then<Map<String, dynamic>>(
        (_) => throw const UploadException('CANCELLED', 'Upload cancelled'),
      ),
    ]);
  }

  Future<UploadResult> _streamChunksAndFinish({
    required String uploadId,
    required String requestId,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    var seq = 0;
    for (var off = 0; off < bytes.length; off += kChunkBytes) {
      if (cancelToken?.isCancelled ?? false) {
        throw const UploadException('CANCELLED', 'Upload cancelled');
      }
      final end = math.min(off + kChunkBytes, bytes.length);
      final ackF = _await('ack:$uploadId:$seq');
      await session.sendForCheckout(
        checkoutId,
        createAbMessage('file:upload-chunk', {
          'uploadId': uploadId,
          'seq': seq,
          'data': base64Encode(Uint8List.sublistView(bytes, off, end)),
        }),
      );
      _throwIfError(await _raceCancel(ackF, cancelToken));
      onProgress?.call(end, bytes.length);
      seq++;
    }
    if (cancelToken?.isCancelled ?? false) {
      throw const UploadException('CANCELLED', 'Upload cancelled');
    }

    final resultF = _await('done:$requestId');
    await session.sendForCheckout(
      checkoutId,
      createAbMessage('file:upload-done', {'uploadId': uploadId}),
    );
    final result = await _raceCancel(resultF, cancelToken);
    _throwIfError(result);
    return UploadResult(
      path: result['path'] as String,
      relPath: result['relPath'] as String?,
      mimeType: result['mimeType'] as String?,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final p in _pending.values) {
      p.fail(const UploadException('OFFLINE', 'Session closed'));
    }
    _pending.clear();
    _requestIdByUpload.clear();
    await _statusSub?.cancel();
    _statusSub = null;
  }
}
