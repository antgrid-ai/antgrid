import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

typedef TerminalClipboardWriter = Future<void> Function(String text);

/// Serializes OS writes across projects and duplicate terminal surfaces.
class TerminalClipboardCoordinator {
  TerminalClipboardCoordinator({
    TerminalClipboardWriter? write,
    int Function()? now,
  }) : _write = write ?? _platformWrite,
       _now = now ?? (() => _clock.elapsedMilliseconds);

  static final _clock = Stopwatch()..start();
  static final instance = TerminalClipboardCoordinator();
  final TerminalClipboardWriter _write;
  final int Function() _now;
  final _queue = <_ClipboardOperation>[];
  bool _writing = false;
  final _seen = <(Object, String), int>{};
  final Map<Object, int> _latest = {};
  Object? _owner;
  Object? _connection;
  String? _terminal;
  void Function()? _release;
  void Function()? _onCopied;
  int _generation = 0;
  bool _programCopies = true;
  bool _allowed = true;

  static Future<void> _platformWrite(String text) =>
      Clipboard.setData(ClipboardData(text: text));
  int get generation => _generation;
  set allowed(bool value) {
    if (_allowed == value) return;
    _allowed = value;
    _generation++;
    if (!value) _release?.call();
  }

  bool eligible(Object connection, String terminal) =>
      _allowed &&
      _programCopies &&
      identical(_connection, connection) &&
      _terminal == terminal;
  bool foreground(Object connection, String terminal) =>
      identical(_connection, connection) && _terminal == terminal;

  void register(
    Object owner,
    Object connection,
    String terminal, {
    required bool programCopies,
    required void Function() release,
    void Function()? onCopied,
  }) {
    _onCopied = onCopied;
    if (identical(owner, _owner) &&
        identical(connection, _connection) &&
        terminal == _terminal &&
        programCopies == _programCopies) {
      return;
    }
    _release?.call();
    _generation++;
    _owner = owner;
    _connection = connection;
    _terminal = terminal;
    _programCopies = programCopies;
    _release = release;
  }

  void unregister(Object owner) {
    if (!identical(owner, _owner)) return;
    _release?.call();
    _generation++;
    _owner = null;
    _connection = null;
    _terminal = null;
    _release = null;
    _onCopied = null;
  }

  void disconnect(Object connection) {
    if (identical(connection, _connection)) unregister(_owner!);
    _seen.removeWhere((key, _) => identical(key.$1, connection));
    _latest.remove(connection);
  }

  Future<bool> copyExplicit(String text) {
    _generation++;
    return _enqueue(text, () => true);
  }

  Future<bool> copyHost(
    String text, {
    required int generation,
    required bool Function() valid,
  }) => _enqueue(text, () => _generation == generation && valid());

  Future<String> copyProgram(
    String text, {
    required Object connection,
    required String terminal,
    required String eventId,
    required bool Function() valid,
  }) async {
    final now = _now();
    _seen.removeWhere((_, seenAt) => now - seenAt > 60000);
    final key = (connection, eventId);
    if (_seen.containsKey(key)) return 'stale';
    _seen[key] = now;
    while (_seen.length > 256) {
      _seen.remove(_seen.keys.first);
    }
    if (!eligible(connection, terminal)) return 'denied';
    final generation = _generation;
    final serial = (_latest[connection] ?? 0) + 1;
    _latest[connection] = serial;
    bool current() =>
        generation == _generation &&
        _latest[connection] == serial &&
        eligible(connection, terminal) &&
        valid();
    var started = false;
    final copied = await _enqueue(text, () {
      if (!current()) return false;
      started = true;
      return true;
    }, replaceKey: connection);
    if (copied && current()) _onCopied?.call();
    return copied
        ? 'copied'
        : started
        ? 'failed'
        : 'stale';
  }

  Future<bool> _enqueue(
    String text,
    bool Function() valid, {
    Object? replaceKey,
  }) {
    if (text.isEmpty ||
        text.contains('\x00') ||
        utf8.encode(text).length > 100000) {
      return Future.value(false);
    }
    if (replaceKey != null) {
      _queue.removeWhere((pending) {
        if (!identical(pending.replaceKey, replaceKey)) return false;
        pending.result.complete(false);
        return true;
      });
    }
    final operation = _ClipboardOperation(text, valid, replaceKey);
    _queue.add(operation);
    // The drain handles adapter failures and completes every queued operation.
    unawaited(_drain());
    return operation.result.future;
  }

  Future<void> _drain() async {
    if (_writing) return;
    _writing = true;
    try {
      while (_queue.isNotEmpty) {
        final operation = _queue.removeAt(0);
        try {
          if (!operation.valid()) {
            operation.result.complete(false);
            continue;
          }
          await _write(operation.text);
          operation.result.complete(true);
        } catch (_) {
          operation.result.complete(false);
        }
      }
    } finally {
      _writing = false;
    }
  }
}

class _ClipboardOperation {
  _ClipboardOperation(this.text, this.valid, this.replaceKey);
  final String text;
  final bool Function() valid;
  final Object? replaceKey;
  final result = Completer<bool>();
}
