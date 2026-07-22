import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../portable_pty.dart';

/// PTY session controller for native targets.
///
/// Manages a local PTY subprocess and buffers output lines. Uses
/// [PtyListenable] for change notifications so it works in pure Dart
/// without a Flutter dependency.
class PortablePtyController with PtyListenable {
  /// Creates a controller that runs a local PTY subprocess.
  ///
  /// Supply [defaultShell], [rows], and [cols] to tune default launch behavior
  /// and provide [transport] for advanced backends.
  PortablePtyController({
    this.maxLines = 1000,
    this.defaultShell,
    this.rows = 24,
    this.cols = 80,
    this.webSocketUrl,
    this.webTransportUrl,
    this.transport,
  }) : assert(maxLines > 0);

  /// Maximum retained line count in the internal line buffer.
  final int maxLines;

  /// Optional shell path used when [start] is called without `shell`.
  final String? defaultShell;

  /// Initial terminal rows.
  final int rows;

  /// Initial terminal columns.
  final int cols;

  /// Optional transport override; defaults to the platform-native implementation.
  final PortablePtyTransport? transport;

  /// WebSocket endpoint — ignored on native, kept for API parity with web.
  final String? webSocketUrl;

  /// WebTransport endpoint — ignored on native, kept for API parity with web.
  final String? webTransportUrl;

  PortablePty? _pty;
  bool _running = false;
  int _revision = 0;
  final List<String> _lines = <String>[''];

  /// Monotonic revision counter, incremented on every state change.
  int get revision => _revision;

  /// Whether a PTY session is currently running.
  bool get isRunning => _running;

  /// A read-only snapshot of terminal output lines.
  List<String> get lines => List.unmodifiable(_lines);

  /// Current buffered line count.
  int get lineCount => _lines.length;

  /// Start a PTY session.
  Future<void> start({
    String? shell,
    List<String> arguments = const <String>[],
  }) async {
    if (_running) {
      return;
    }

    final resolvedShell =
        shell ??
        defaultShell ??
        switch (Platform.operatingSystem) {
          'windows' => 'C:\\Windows\\System32\\cmd.exe',
          'android' => '/system/bin/sh',
          _ => '/bin/sh',
        };

    _pty = PortablePty.open(rows: rows, cols: cols, transport: transport);
    _pty!.spawn(resolvedShell, args: arguments.isNotEmpty ? arguments : null);
    _running = true;
    _appendLine('[started $resolvedShell]');
    _markDirty();
  }

  /// Stop the current PTY session.
  Future<void> stop() async {
    final pty = _pty;
    if (pty == null) {
      _running = false;
      _markDirty();
      return;
    }

    Object? stopError;
    try {
      pty.kill();
    } catch (error) {
      // The process may have already exited between UI state checks and stop.
      // We still close the PTY handle and treat stop as successful cleanup.
      stopError = error;
    }

    try {
      pty.close();
    } catch (error) {
      stopError ??= error;
    }

    _pty = null;
    _running = false;
    _appendLine(
      stopError == null
          ? '[terminated]'
          : '[terminated with recovery: $stopError]',
    );
    _markDirty();
  }

  /// Read output from the PTY.
  String readOutput({int maxBytes = 4096}) {
    final pty = _pty;
    if (pty == null) {
      return '';
    }

    final bytes = pty.readSync(maxBytes);
    if (bytes.isEmpty) {
      return '';
    }

    final text = utf8.decode(bytes, allowMalformed: true);
    _appendText(text);
    _markDirty();
    return text;
  }

  /// Write plain text to stdin.
  bool write(String text) {
    final pty = _pty;
    if (pty == null) {
      return false;
    }

    pty.writeString(text);
    return true;
  }

  /// Write raw bytes to stdin.
  bool writeBytes(Uint8List bytes) {
    final pty = _pty;
    if (pty == null) {
      return false;
    }

    pty.writeBytes(bytes);
    return true;
  }

  /// Inject debug text for tests/preview.
  void appendDebugOutput(String text) {
    _appendText(text);
    _markDirty();
  }

  /// Check process exit status.
  int? tryWait() {
    return _pty?.tryWait();
  }

  /// Clears output history.
  void clear() {
    _lines
      ..clear()
      ..add('');
    _markDirty();
  }

  void _appendLine(String line) {
    if (_lines.isEmpty) {
      _lines.add('');
    }
    _lines.add(line);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  void _appendText(String text) {
    if (_lines.isEmpty) {
      _lines.add('');
    }

    for (final rune in text.runes) {
      if (_lines.isEmpty) {
        _lines.add('');
      }
      switch (rune) {
        case 0x0A:
          _lines.add('');
        case 0x0D:
          _lines[_lines.length - 1] = '';
        case 0x08:
          final current = _lines[_lines.length - 1];
          if (current.isNotEmpty) {
            _lines[_lines.length - 1] = current.substring(
              0,
              current.length - 1,
            );
          }
        default:
          _lines[_lines.length - 1] += String.fromCharCode(rune);
      }
    }

    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  void _markDirty() {
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
