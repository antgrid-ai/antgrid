import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../launcher/host_discovery.dart' show hostDir;
import 'log_rotation.dart';

/// Structured JSONL logger for the Flutter app. Writes pino-shaped lines
/// (numeric level, epoch-ms time, pid, component, msg, flat fields) to
/// `<hostDir>/app.log`, sibling to the bridge's host.log. Buffered + async:
/// calls never block on disk I/O, so latency-sensitive paths (handshake,
/// transcript render) stay jank-free; a hard crash may lose up to ~250ms of
/// unflushed lines — acceptable for a local debug log. Fail-open: never throws.
class AbLog {
  AbLog._();

  static _AbLogWriter? _writer;
  static _AbLogWriter _w() => _writer ??= _AbLogWriter('${hostDir()}/app.log');

  static void debug(
    String component,
    String msg, {
    Map<String, Object?>? fields,
  }) => _w().log(20, component, msg, fields);
  static void info(
    String component,
    String msg, {
    Map<String, Object?>? fields,
  }) => _w().log(30, component, msg, fields);
  static void warn(
    String component,
    String msg, {
    Map<String, Object?>? fields,
  }) => _w().log(40, component, msg, fields);
  static void error(
    String component,
    String msg, {
    Map<String, Object?>? fields,
  }) => _w().log(50, component, msg, fields);

  /// Test seam: redirect output to [path] and force [mirror] on/off (bypassing
  /// the kDebugMode default) so mirroring is assertable in any build mode.
  @visibleForTesting
  static void configureForTest(String path, {bool mirror = false}) {
    _writer?.dispose();
    _writer = _AbLogWriter(path, mirror: mirror);
  }

  /// Drain queued lines to disk now (tests await before asserting).
  @visibleForTesting
  static Future<void> flush() => _w().flush();

  /// Cancel the flush timer and drop the writer (test teardown).
  @visibleForTesting
  static void dispose() {
    _writer?.dispose();
    _writer = null;
  }
}

class _AbLogWriter {
  _AbLogWriter(this.path, {bool? mirror}) : _mirror = mirror ?? kDebugMode;

  final String path;
  final bool _mirror;
  final List<String> _queue = <String>[];
  static const Duration _flushInterval = Duration(milliseconds: 250);
  static const int _flushAt = 64; // flush eagerly once the queue is this deep
  Timer? _timer;
  Future<void>? _inFlight;
  bool _dirReady = false;

  // Under `flutter test`, a live periodic flush Timer outlives the widget tree
  // and trips the "Timer is still pending after dispose" binding assertion in
  // any widget test that happens to log (e.g. via agentTransportForProvider).
  // Tests drain explicitly with AbLog.flush(), so skip the timer entirely there
  // and nothing dangles. FLUTTER_TEST is a process env var set by the harness,
  // so a runtime lookup (not `bool.fromEnvironment`, which is compile-time) sees it.
  static final bool _underTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  void log(
    int level,
    String component,
    String msg,
    Map<String, Object?>? fields,
  ) {
    _queue.add(_encode(level, component, msg, fields));
    if (_mirror) debugPrint('[$component] $msg');
    if (_queue.length >= _flushAt) {
      unawaited(flush());
    } else if (!_underTest) {
      _timer ??= Timer(_flushInterval, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  String _encode(
    int level,
    String component,
    String msg,
    Map<String, Object?>? fields,
  ) {
    try {
      final line = <String, Object?>{
        'level': level,
        'time': DateTime.now().millisecondsSinceEpoch,
        'pid': pid,
        'component': component,
        'msg': msg,
      };
      if (fields != null) line.addAll(fields);
      return jsonEncode(line);
    } catch (_) {
      // A field value was non-encodable (or its toString/iterator misbehaved).
      // Never lose the message: stringify each field defensively (a value's
      // toString() may itself throw), and if even that fails, emit message-only.
      try {
        return jsonEncode(<String, Object?>{
          'level': level,
          'time': DateTime.now().millisecondsSinceEpoch,
          'pid': pid,
          'component': component,
          'msg': msg,
          if (fields != null)
            'fields': fields.map((k, v) => MapEntry(k, _safeString(v))),
        });
      } catch (_) {
        return jsonEncode(<String, Object?>{
          'level': level,
          'time': DateTime.now().millisecondsSinceEpoch,
          'pid': pid,
          'component': component,
          'msg': msg,
        });
      }
    }
  }

  static String _safeString(Object? v) {
    try {
      return '$v';
    } catch (_) {
      return '<unprintable>';
    }
  }

  Future<void> flush() => _inFlight ??= _drain();

  Future<void> _drain() async {
    _timer?.cancel();
    _timer = null;
    try {
      // On a clean mobile install no local host runs, so hostDir() may not
      // exist yet; writeAsString won't create missing parents, and in release
      // mode (no debugPrint mirror) the swallowed failure would silently drop
      // every app diagnostic. Ensure the parent once — cheap after first pass.
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
    } finally {
      _inFlight = null;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }
}
