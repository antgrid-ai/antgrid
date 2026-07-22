import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../portable_pty.dart';

/// Web-compatible PTY controller.
///
/// Delegates process I/O to [PortablePty] which is expected to be backed by a
/// remote transport (WebSocket or WebTransport). Uses [PtyListenable] for
/// change notifications so the controller works in pure Dart without Flutter.
class PortablePtyController with PtyListenable {
  /// Creates a web PTY controller.
  PortablePtyController({
    this.maxLines = 1000,
    this.defaultShell,
    this.rows = 24,
    this.cols = 80,
    this.webSocketUrl,
    this.webTransportUrl,
    this.transport,
  }) : assert(maxLines > 0);

  /// Maximum number of lines retained in the output buffer.
  final int maxLines;

  /// Optional default shell/target used by [start] when no explicit command is
  /// given.
  final String? defaultShell;

  /// Initial terminal row count.
  final int rows;

  /// Initial terminal column count.
  final int cols;

  /// Optional WebSocket endpoint.
  final String? webSocketUrl;

  /// Optional WebTransport endpoint.
  final String? webTransportUrl;

  /// Optional transport override for testing or custom backends.
  final PortablePtyTransport? transport;

  PortablePty? _pty;
  bool _running = false;
  bool _disposed = false;
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

  /// Starts a remote PTY session.
  ///
  /// [shell] is forwarded as the [PortablePty.spawn] command on web targets.
  /// If omitted, [defaultShell] and finally configured endpoint URLs are used
  /// as a fallback target.
  ///
  /// If no command or endpoint is available, the controller emits a diagnostic
  /// line and returns without opening a transport.
  Future<void> start({
    String? shell,
    List<String> arguments = const <String>[],
  }) async {
    if (_running) {
      return;
    }

    final hasRemoteEndpoint =
        transport != null || webSocketUrl != null || webTransportUrl != null;
    final target =
        (shell ?? defaultShell ?? webTransportUrl ?? webSocketUrl ?? '').trim();
    if (target.isEmpty && !hasRemoteEndpoint) {
      _appendLine(
        '[web target]: provide a remote endpoint via shell, webSocketUrl, or webTransportUrl',
      );
      _markDirty();
      return;
    }

    _pty = PortablePty.open(
      rows: rows,
      cols: cols,
      webSocketUrl: webSocketUrl,
      webTransportUrl: webTransportUrl,
      transport: transport,
    );
    try {
      _pty!.spawn(target, args: arguments.isNotEmpty ? arguments : null);
      _running = true;
      _appendLine('[started $target]');
      _markDirty();
    } on Object catch (error) {
      _appendLine('[web target] failed to start: $error');
      _pty = null;
      _running = false;
      _markDirty();
    }
  }

  /// Stops the current session.
  Future<void> stop() async {
    final pty = _pty;
    if (pty == null) {
      _running = false;
      _markDirty();
      return;
    }

    pty.kill();
    pty.close();
    _pty = null;
    _running = false;
    _appendLine('[terminated]');
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
  ///
  /// Returns `false` when no PTY is connected or write fails.
  bool write(String text) {
    final pty = _pty;
    if (pty == null) {
      return false;
    }

    try {
      pty.writeString(text);
      return true;
    } on Object catch (error) {
      _appendLine('[write failed] $error');
      _running = false;
      _pty = null;
      _markDirty();
      return false;
    }
  }

  /// Write raw bytes to stdin.
  ///
  /// Returns `false` when no PTY is connected or write fails.
  bool writeBytes(Uint8List bytes) {
    final pty = _pty;
    if (pty == null) {
      return false;
    }

    try {
      pty.writeBytes(bytes);
      return true;
    } on Object catch (error) {
      _appendLine('[write failed] $error');
      _running = false;
      _pty = null;
      _markDirty();
      return false;
    }
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
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
