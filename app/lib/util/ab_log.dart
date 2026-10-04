import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'jsonl_sink.dart';
import 'log_location.dart';

/// Structured JSONL logger for the Flutter app. Writes pino-shaped lines
/// (numeric level, epoch-ms time, pid, component, msg, flat fields) to
/// `<hostDir>/app.log` on desktop, sibling to the bridge's host.log, and inside
/// the app's own sandbox on Android/iOS, where hostDir() is not writable.
/// A phone learns that directory asynchronously, so lines logged before
/// [initLogDirectory] answers are held (bounded) and written on attach.
/// Buffered + async:
/// calls never block on disk I/O, so latency-sensitive paths (handshake,
/// transcript render) stay jank-free; a hard crash may lose up to ~250ms of
/// unflushed lines — acceptable for a local debug log. Fail-open: never throws.
class AbLog {
  AbLog._();

  static _AbLogWriter? _writer;

  /// `flutter test` resolves the same `hostDir()` a debug build does, so an
  /// unconfigured writer appends the suite's own output to the dev rig's live
  /// `app.log` — where a fixture supervisor's zero-delay backoff and its march
  /// through every block reason are indistinguishable from a fault on the
  /// running app. Tests that assert on logging name their own file through
  /// [configureForTest].
  static final bool _underTest = Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// Lines held while a mobile log directory is still being resolved.
  @visibleForTesting
  static const int kPreInitCapacity = 1000;

  static String? _dir;
  static Future<String?>? _dirInit;

  /// The directory app.log is written to, or null while unresolved, under test
  /// (unless [configureForTest] named a file), or after resolution failed.
  static String? get logDirectory => _dir;

  static _AbLogWriter _w() => _writer ??= _defaultWriter();

  static _AbLogWriter _defaultWriter() {
    if (_underTest) return _AbLogWriter(null);
    final dir = syncLogDir();
    if (dir != null) {
      _dir = dir;
      return _AbLogWriter('$dir/$kAppLogFileName');
    }
    return _AbLogWriter.pending();
  }

  /// Resolves and attaches the mobile log directory; returns the directory.
  /// Desktop and tests return at once without touching path_provider.
  /// Memoised while in flight or after success; a failure clears the memo so a
  /// later caller (the share action) retries. [fileName] names the file inside
  /// the directory and is honoured only by the call that performs the attach.
  static Future<String?> initLogDirectory({
    Future<Directory> Function()? supportDir,
    String fileName = kAppLogFileName,
  }) {
    final init = _dirInit ??= _initLogDirectory(supportDir, fileName);
    // Cleared here rather than inside _initLogDirectory because its early
    // returns also yield null without reaching the catch (writer not pending,
    // or replaced while the lookup was in flight), and those must not stay
    // memoised either.
    unawaited(
      init.then((dir) {
        if (dir == null && identical(_dirInit, init)) _dirInit = null;
      }),
    );
    return init;
  }

  static Future<String?> _initLogDirectory(
    Future<Directory> Function()? supportDir,
    String fileName,
  ) async {
    final writer = _w();
    if (_dir != null || !writer.isPending) return _dir;
    try {
      final dir = await resolveMobileLogDir(supportDir: supportDir);
      // configureForTest/dispose may have replaced the writer mid-await; a
      // stale attach would report a directory the live writer never opened.
      if (!identical(_writer, writer)) return _dir;
      _dir = dir;
      writer.attach('$dir/$fileName');
      return dir;
    } catch (e) {
      // The writer stays pending with its held lines: they are bounded by the
      // buffer capacity, and a later successful lookup (the share action
      // retries) writes them instead of losing them to one failed lookup.
      if (kDebugMode) debugPrint('[AbLog] log directory unresolvable: $e');
      return null;
    }
  }

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
    _dir = File(path).parent.path;
    _dirInit = null;
  }

  /// Test seam: a writer that holds lines until [initLogDirectory] attaches a
  /// directory, as on a phone, with a [capacity] small enough to overflow.
  @visibleForTesting
  static void configurePendingForTest({
    int capacity = kPreInitCapacity,
    bool mirror = false,
  }) {
    _writer?.dispose();
    _writer = _AbLogWriter.pending(capacity: capacity, mirror: mirror);
    _dir = null;
    _dirInit = null;
  }

  /// Drain queued lines to disk now: before sharing the file, before a
  /// headless isolate is torn down, and in tests before asserting.
  static Future<void> flush() => _w().flush();

  /// Cancel the flush timer and drop the writer (test teardown).
  @visibleForTesting
  static void dispose() {
    _writer?.dispose();
    _writer = null;
    _dir = null;
    _dirInit = null;
  }
}

class _AbLogWriter {
  _AbLogWriter(String? path, {bool? mirror})
    : _mirror = mirror ?? kDebugMode,
      _sink = path == null ? null : JsonlSink(path),
      _pending = null,
      _capacity = 0;

  _AbLogWriter.pending({int capacity = AbLog.kPreInitCapacity, bool? mirror})
    : _mirror = mirror ?? kDebugMode,
      _sink = null,
      _pending = ListQueue<String>(),
      _capacity = capacity;

  final bool _mirror;
  JsonlSink? _sink;
  ListQueue<String>? _pending;
  final int _capacity;
  int _overflow = 0;

  bool get isPending => _pending != null;

  void log(
    int level,
    String component,
    String msg,
    Map<String, Object?>? fields,
  ) {
    // Encoded now, not at attach, so a held line keeps its original timestamp.
    final line = _encode(level, component, msg, fields);
    final sink = _sink;
    final pending = _pending;
    if (sink != null) {
      sink.add(line);
    } else if (pending != null) {
      if (pending.length >= _capacity) {
        pending.removeFirst();
        _overflow++;
      }
      pending.add(line);
    }
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

  /// Opens the file sink and writes every held line to it, in order.
  void attach(String path) {
    final pending = _pending;
    if (_sink != null || pending == null) return;
    final sink = JsonlSink(path);
    // First, because the lines that overflowed were the earliest ones.
    if (_overflow > 0) {
      sink.add(
        _encode(
          40,
          'AbLog',
          'early lines dropped before the log directory resolved',
          {'dropped': _overflow},
        ),
      );
    }
    for (final line in pending) {
      sink.add(line);
    }
    _pending = null;
    _overflow = 0;
    _sink = sink;
  }

  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  void dispose() {
    _sink?.dispose();
    _pending = null;
  }
}
