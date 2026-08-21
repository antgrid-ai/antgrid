import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/upload_service.dart';

/// Exactly [UploadService.upload]'s signature, so a live service's method
/// tears off straight into [TerminalAttachmentUploader.resolveUpload].
typedef UploadRunner =
    Future<String> Function({
      required String fileName,
      required Uint8List bytes,
      String? mimeType,
      void Function(int sent, int total)? onProgress,
    });

/// Where an attach is in the round trip. [staging] and [finishing] are the
/// request/response hops either side of the chunk stream and report no
/// fraction: a sub-chunk screenshot emits exactly one progress tick, so a
/// bar pinned at 0% for both hops is all a user would ever see of it.
enum AttachPhase { staging, sending, finishing, done }

@immutable
class AttachProgress {
  const AttachProgress({
    required this.fileName,
    required this.phase,
    this.sent = 0,
    this.total = 0,
  });

  final String fileName;
  final AttachPhase phase;
  final int sent;
  final int total;

  /// Null while the size of the current step is unknown — see [AttachPhase].
  double? get fraction =>
      phase == AttachPhase.sending && total > 0 ? sent / total : null;
}

/// Uploads bytes to the bridge's staging dir and types the returned host path
/// into the terminal. The single pipeline behind every attach gesture (the
/// attach button, an image paste, a file drop) so they cannot diverge on the
/// busy state, the size cap, or the inserted text.
///
/// Never throws and never returns a path: every outcome leaves through
/// [insert], [onError] or [progress], so a `void` callback can fire it through
/// `detached(...)` with nothing left to handle.
class TerminalAttachmentUploader {
  TerminalAttachmentUploader({
    required this.resolveUpload,
    required this.insert,
    required this.onError,
  });

  /// Resolved per call, never captured: an upload takes seconds, and the
  /// checkout's service bundle can be swept out from under one in that window.
  final UploadRunner? Function() resolveUpload;

  /// Receives the ready-to-type text, quotes and trailing space included.
  final void Function(String text) insert;

  /// Receives [uploadErrorText] copy for every failure.
  final void Function(String message) onError;

  /// How long the finished state stays up before the strip clears. Long enough
  /// to be read by someone whose eyes were on the prompt line, short enough not
  /// to linger over the output it overlays.
  static const Duration kDoneHold = Duration(milliseconds: 1200);

  /// Null while idle. Both the progress strip and every attach affordance's
  /// disabled state read this, so "busy" has one definition.
  final ValueNotifier<AttachProgress?> progress = ValueNotifier(null);

  bool _inFlight = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _clearTimer;

  bool get busy => _inFlight;

  Future<void> attach({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    if (_disposed) return;
    if (_inFlight) {
      onError(uploadErrorText(const UploadException('BUSY', ''), fileName));
      return;
    }
    // Checked here rather than left to the bridge: the bytes are already in app
    // memory, and the wire round trip only ends in the same TOO_LARGE.
    if (bytes.length > UploadService.kMaxUploadBytes) {
      onError(
        uploadErrorText(const UploadException('TOO_LARGE', ''), fileName),
      );
      return;
    }
    final run = resolveUpload();
    if (run == null) {
      onError(uploadErrorText(const UploadException('OFFLINE', ''), fileName));
      return;
    }

    _inFlight = true;
    _clearTimer?.cancel();
    final generation = ++_generation;
    _publish(
      generation,
      AttachProgress(fileName: fileName, phase: AttachPhase.staging),
    );
    try {
      final path = await run(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        onProgress: (sent, total) => _publish(
          generation,
          AttachProgress(
            fileName: fileName,
            phase: sent >= total ? AttachPhase.finishing : AttachPhase.sending,
            sent: sent,
            total: total,
          ),
        ),
      );
      insert('"$path" ');
      _publish(
        generation,
        AttachProgress(fileName: fileName, phase: AttachPhase.done),
      );
      _clearTimer = Timer(kDoneHold, () => _publish(generation, null));
    } catch (error) {
      // The strip has no room for a failure state that a snackbar states
      // better, and leaving a dead bar over the output would outlive the read.
      _publish(generation, null);
      onError(uploadErrorText(error, fileName));
    } finally {
      _inFlight = false;
    }
  }

  void _publish(int generation, AttachProgress? value) {
    if (_disposed || generation != _generation) return;
    progress.value = value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearTimer?.cancel();
    progress.dispose();
  }
}
