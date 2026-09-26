import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import '../project/project_session.dart';

/// Upload failure with a machine [code] (mirrors the bridge's
/// file:upload-result error codes, plus app-side OFFLINE/TIMEOUT/CANCELLED).
class UploadException implements Exception {
  final String code;
  final String message;
  const UploadException(this.code, this.message);

  @override
  String toString() => 'UploadException($code): $message';
}

/// A one-shot cancel signal for [UploadService.upload]. Cancelling calls
/// [UploadExchange.cancel] so the exchange resolves `CANCELLED` within one
/// round trip rather than waiting out [kUploadResultTimeout].
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

/// File upload to the bridge's project-local staging dir, over whatever
/// [UploadExchange] `session.transport.openUpload` hands back (its own native
/// QUIC stream, or the loopback socket's chunked exchange — see
/// `upload_stream.dart`).
class UploadService {
  static const int kMaxUploadBytes = 20 * 1024 * 1024;

  final ProjectSession session;
  final String checkoutId;
  bool _disposed = false;
  final Set<UploadExchange> _active = {};

  UploadService.fromSession(this.session, {this.checkoutId = 'main'});

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
    if (cancelToken?.isCancelled ?? false) {
      throw const UploadException('CANCELLED', 'Upload cancelled');
    }

    final exchange = session.transport.openUpload(
      requestId: const Uuid().v4(),
      projectId: session.wireProjectId,
      checkoutId: checkoutId,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      onProgress: onProgress,
    );
    _active.add(exchange);
    final cancelSub = cancelToken?.whenCancelled.then((_) => exchange.cancel());
    try {
      final result = await exchange.result;
      if (!result.ok) {
        throw UploadException(
          result.error ?? 'UNKNOWN',
          result.message ?? 'Upload failed',
        );
      }
      return UploadResult(
        path: result.path!,
        relPath: result.relPath,
        mimeType: result.mimeType,
      );
    } on UploadFailure catch (failure) {
      // dispose() ends live exchanges through cancel(), but the caller asked
      // for no cancel: to it the session went away underneath the upload.
      if (_disposed &&
          failure.code == 'CANCELLED' &&
          !(cancelToken?.isCancelled ?? false)) {
        throw const UploadException('OFFLINE', 'Session closed');
      }
      throw _mapFailure(failure);
    } finally {
      _active.remove(exchange);
      // Nothing left to cancel; drop the reference so it can't fire late.
      unawaited(cancelSub ?? Future.value());
    }
  }

  UploadException _mapFailure(UploadFailure failure) {
    switch (failure.code) {
      case 'CANCELLED':
      case 'TIMEOUT':
      case 'INVALID_NAME':
        return UploadException(failure.code, failure.message ?? failure.code);
      case 'REFUSED':
        // A cap refusal is transient (retry once traffic drains); every other
        // refusal reason (NOT_READY, NOT_ALLOWED, UPDATE_REQUIRED, INVALID)
        // reads the same as "can't reach the agent right now" to the user.
        return failure.refusedCode == StreamRefusedCode.capExceeded
            ? const UploadException('BUSY', 'Too many uploads in progress')
            : const UploadException('OFFLINE', 'Not connected to the agent');
      case 'NOT_SUPPORTED':
      case 'STREAM_OPEN_FAILED':
      case 'TRANSPORT_CLOSED':
        return const UploadException('OFFLINE', 'Not connected to the agent');
      default:
        return UploadException(failure.code, failure.message ?? failure.code);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final exchange in _active.toList()) {
      exchange.cancel();
    }
  }
}
