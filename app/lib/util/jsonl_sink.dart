import 'dart:async';
import 'dart:io';

import 'log_rotation.dart';

/// Buffered, rotated, append-only JSONL file.
///
/// Callers never wait on disk: lines queue in memory and drain on a timer, so a
/// hard crash may lose up to ~250ms of them — acceptable for local diagnostics,
/// and the reason latency-sensitive paths (handshake, transcript render, every
/// relay frame) can log at all. Fail-open: a filesystem error costs lines, never
/// an exception to the caller.
///
/// Shared by [AbLog] and the netwatch capture, which need the same batching and
/// rotation but must NOT share one file — `rotateLogIfNeeded` keeps a single
/// 10 MiB generation, so a frame flood in app.log would roll real diagnostics
/// off the end of the disk.
class JsonlSink {
  JsonlSink(this.path);

  final String path;

  final List<String> _queue = <String>[];
  static const Duration _flushInterval = Duration(milliseconds: 250);
  static const int _flushAt = 64; // flush eagerly once the queue is this deep
  Timer? _timer;
  Future<void>? _inFlight;
  bool _dirReady = false;
  bool _disposed = false;

  // Under `flutter test`, a live periodic flush Timer outlives the widget tree
  // and trips the "Timer is still pending after dispose" binding assertion in
  // any widget test that happens to log. Tests drain explicitly with flush(),
  // so skip the timer entirely there and nothing dangles. FLUTTER_TEST is a
  // process env var set by the harness, so a runtime lookup (not
  // `bool.fromEnvironment`, which is compile-time) sees it.
  static final bool _underTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// Queue one already-encoded JSON line (no trailing newline).
  void add(String line) {
    // A disposed sink has no drain: its timer is cancelled and, under
    // `flutter test`, there is no timer to re-arm at all — so a line queued
    // after dispose either sits forever or lands on disk from a sink its owner
    // believes is gone.
    if (_disposed) return;
    _queue.add(line);
    if (_queue.length >= _flushAt) {
      unawaited(flush());
    } else if (!_underTest) {
      _timer ??= Timer(_flushInterval, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  /// Drain queued lines to disk now (tests await before asserting).
  ///
  /// The completion hook clears the latch, NEVER `_drain`'s own `finally`. With
  /// nothing queued and the directory already made, `_drain` reaches no `await`
  /// and its body — the `finally` included — runs to completion BEFORE the
  /// future it returns is assigned here. A self-clearing `_drain` would then be
  /// storing a latch nothing can ever clear, and every later flush would
  /// short-circuit on it: the sink queues forever and writes nothing again for
  /// the life of the process. `whenComplete` cannot run early — its callback is
  /// a microtask at the soonest — so the clear always follows the assignment.
  Future<void> flush() => _inFlight ??= _drain().whenComplete(() {
    _inFlight = null;
  });

  Future<void> _drain() async {
    _timer?.cancel();
    _timer = null;
    try {
      // On a clean mobile install no local host runs, so the parent may not
      // exist yet; writeAsString won't create missing parents, and in release
      // mode (no debugPrint mirror) the swallowed failure would silently drop
      // every diagnostic. Ensure it once — cheap after the first pass.
      if (!_dirReady) {
        await File(path).parent.create(recursive: true);
        _dirReady = true;
      }
      // Drain to empty: lines enqueued during an await are caught by the next
      // loop iteration, so a coalesced caller's await resolves only once every
      // line logged before it is on disk.
      while (_queue.isNotEmpty) {
        final batch = _queue.toList(growable: false);
        _queue.clear();
        rotateLogIfNeeded(path);
        final buf = StringBuffer();
        for (final l in batch) {
          buf.writeln(l);
        }
        await File(
          path,
        ).writeAsString(buf.toString(), mode: FileMode.append, flush: false);
      }
    } catch (_) {
      // Fail-open: never let logging crash a caller.
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }
}
