import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/upload_service.dart';
import 'attach_progress.dart';

/// Exactly [UploadService.upload]'s signature, so a live service's method
/// tears off straight into [TerminalAttachmentUploader.resolveUpload].
typedef UploadRunner =
    Future<String> Function({
      required String fileName,
      required Uint8List bytes,
      String? mimeType,
      void Function(int sent, int total)? onProgress,
    });

/// Attach progress per terminal rather than per view of it. On a phone the
/// file picker backgrounds the app, the reconnect rebuilds the terminal view,
/// and the upload finishes in the uploader of a view that is gone — a board
/// keyed by terminal is how the view built in its place still shows it.
///
/// Reference-counted: every view showing a terminal, every attach running
/// against it and every finished state still on show holds the key, and the
/// entry goes when the last one lets go.
class TerminalAttachBoard {
  final Map<String, _Entry> _entries = {};

  bool _reserve(String key, Object owner) {
    final entry = _entries[key];
    if (entry?.owner != null ||
        (entry?.progress.value != null &&
            entry!.progress.value!.phase != AttachPhase.done)) {
      return false;
    }
    acquire(key);
    _entries[key]!.owner = owner;
    return true;
  }

  void _releaseReservation(String key, Object owner) {
    if (!identical(_entries[key]?.owner, owner)) return;
    _entries[key]!.owner = null;
    release(key);
  }

  ValueNotifier<AttachProgress?> acquire(String key) {
    final entry = _entries.putIfAbsent(key, _Entry.new);
    entry.holders++;
    return entry.progress;
  }

  void release(String key) {
    final entry = _entries[key];
    if (entry == null || --entry.holders > 0) return;
    _entries.remove(key);
    entry.progress.dispose();
  }

  /// Whether a view, not just this attach's own holds, is showing [key].
  bool shownElsewhere(String key, {required int ownHolds}) =>
      (_entries[key]?.holders ?? 0) > ownHolds;
}

final class _Entry {
  final ValueNotifier<AttachProgress?> progress = ValueNotifier(null);
  int holders = 0;
  Object? owner;
}

final terminalAttachBoardProvider = Provider<TerminalAttachBoard>(
  (ref) => TerminalAttachBoard(),
);

/// Uploads bytes to the bridge's staging dir and types the returned host path
/// into the terminal. The single pipeline behind every attach gesture (the
/// attach button, an image paste, a file drop) so they cannot diverge on the
/// busy state, the size cap, or the inserted text.
///
/// [attach] never throws or returns a path: every outcome leaves through
/// [insert], [onError] or the [board], so a `void` callback can fire it
/// through `detached(...)` with nothing left to handle.
class TerminalAttachmentUploader {
  TerminalAttachmentUploader({
    required this.board,
    required this.boardKey,
    required this.resolveUpload,
    required this.insert,
    required this.onError,
  });

  final TerminalAttachBoard board;

  /// The [board] key of the terminal an attach starting now would type into.
  final String Function() boardKey;

  /// Resolved per call, never captured: an upload takes seconds, and the
  /// checkout's service bundle can be swept out from under one in that window.
  final UploadRunner? Function() resolveUpload;

  /// Receives the ready-to-type text, quotes and trailing space included.
  /// May wait (a terminal still re-attaching after a reconnect); the strip
  /// stays up until it settles, and a throw is reported like any failure.
  final FutureOr<void> Function(String text) insert;

  /// Receives [uploadErrorText] copy for every failure.
  final void Function(String message) onError;

  /// How long the finished state stays up before the strip clears. Long enough
  /// to be read by someone whose eyes were on the prompt line, short enough not
  /// to linger over the output it overlays.
  static const Duration kDoneHold = Duration(milliseconds: 1200);

  bool _disposed = false;
  bool _disposeRequested = false;
  int _holders = 0;
  String? _batchKey;
  bool _attaching = false;
  ({Timer timer, String key, VoidCallback clear})? _pendingClear;

  /// Reserves the terminal even while a batch is reading its next file. The
  /// board also excludes attachments started by a replacement view.
  Future<T?> exclusive<T>(Future<T> Function() operation) async {
    if (_disposed) return null;
    final key = boardKey();
    if (_batchKey != null || !board._reserve(key, this)) {
      onError(uploadErrorText(const UploadException('BUSY', ''), 'clipboard'));
      return null;
    }
    _batchKey = key;
    _holders++;
    try {
      return await operation();
    } finally {
      _batchKey = null;
      board._releaseReservation(key, this);
      _holders--;
      if (_disposeRequested && _holders == 0) dispose();
    }
  }

  /// A native picker can outlive the terminal view during reconnection.
  Future<void> keepAliveDuring(Future<void> Function() operation) async {
    if (_disposed) return;
    _holders++;
    try {
      await operation();
    } finally {
      _holders--;
      if (_disposeRequested && _holders == 0) dispose();
    }
  }

  Future<void> attach({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    if (_disposed) return;
    // Checked here rather than left to the bridge: the bytes are already in app
    // memory, and the wire round trip only ends in the same TOO_LARGE.
    if (bytes.length > UploadService.kMaxUploadBytes) {
      onError(
        uploadErrorText(const UploadException('TOO_LARGE', ''), fileName),
      );
      return;
    }
    final key = boardKey();
    final inBatch = _batchKey == key;
    if (_attaching || (!inBatch && !board._reserve(key, this))) {
      onError(uploadErrorText(const UploadException('BUSY', ''), fileName));
      return;
    }
    _attaching = true;
    final progress = board.acquire(key);
    try {
      // The board, not this uploader, is what says busy: the view that
      // started an upload may be gone, and its successor's uploader with it.
      final shown = progress.value;
      if (shown != null && shown.phase != AttachPhase.done) {
        onError(uploadErrorText(const UploadException('BUSY', ''), fileName));
        return;
      }
      final run = resolveUpload();
      if (run == null) {
        onError(
          uploadErrorText(const UploadException('OFFLINE', ''), fileName),
        );
        return;
      }

      _settlePendingClear();
      progress.value = AttachProgress.staging(fileName);
      try {
        final path = await run(
          fileName: fileName,
          bytes: bytes,
          mimeType: mimeType,
          onProgress: (sent, total) => progress.value = AttachProgress.tick(
            fileName: fileName,
            sent: sent,
            total: total,
          ),
        );
        await insert('"$path" ');
        final done = AttachProgress(
          fileName: fileName,
          phase: AttachPhase.done,
        );
        progress.value = done;
        // Its own hold, so the finished state outlives this attach's.
        board.acquire(key);
        _pendingClear = (
          timer: Timer(kDoneHold, _settlePendingClear),
          key: key,
          clear: () {
            if (identical(progress.value, done)) progress.value = null;
            board.release(key);
          },
        );
      } catch (error) {
        // The strip has no room for a failure state that a snackbar states
        // better, and leaving a dead bar over the output would outlive the
        // read.
        progress.value = null;
        onError(uploadErrorText(error, fileName));
      }
    } finally {
      board.release(key);
      _attaching = false;
      if (!inBatch) board._releaseReservation(key, this);
    }
  }

  void _settlePendingClear() {
    final pending = _pendingClear;
    _pendingClear = null;
    pending?.timer.cancel();
    pending?.clear();
  }

  void dispose() {
    _disposeRequested = true;
    if (_holders > 0) return;
    if (_disposed) return;
    _disposed = true;
    // A view still showing the terminal keeps the finished state up for the
    // whole hold; with nobody watching there is nothing left to hold for.
    final key = _pendingClear?.key;
    if (key == null || !board.shownElsewhere(key, ownHolds: 1)) {
      _settlePendingClear();
    }
  }
}
