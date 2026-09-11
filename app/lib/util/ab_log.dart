import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../launcher/host_discovery.dart' show hostDir;
import 'jsonl_sink.dart';

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
  _AbLogWriter(String path, {bool? mirror})
    : _mirror = mirror ?? kDebugMode,
      _sink = JsonlSink(path);

  final bool _mirror;
  final JsonlSink _sink;

  void log(
    int level,
    String component,
    String msg,
    Map<String, Object?>? fields,
  ) {
    _sink.add(_encode(level, component, msg, fields));
    if (_mirror) debugPrint('[$component] $msg');
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

  Future<void> flush() => _sink.flush();

  void dispose() => _sink.dispose();
}
