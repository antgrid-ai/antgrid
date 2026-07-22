import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../portable_pty_bindings_generated.dart' as bindings;
import 'pty_transport.dart';

/// High-level wrapper around the native PTY library.
///
/// ```dart
/// final pty = PortablePty.open(rows: 24, cols: 80);
/// pty.spawn('/bin/bash');
///
/// final output = pty.readSync(4096);
/// print(utf8.decode(output));
///
/// pty.writeString('ls -la\n');
/// pty.close();
/// ```
final class PortablePty {
  PortablePty._(this._transport);

  /// Opens a new PTY with the given dimensions.
  ///
  /// Use [transport] to inject a custom backend for testing or
  /// non-native platforms.
  ///
  /// ```dart
  /// final pty = PortablePty.open(rows: 30, cols: 120);
  /// pty.spawn('/bin/bash');
  /// ```
  factory PortablePty.open({
    int rows = 24,
    int cols = 80,
    String? webSocketUrl,
    String? webTransportUrl,
    PortablePtyTransport? transport,
  }) {
    // webSocketUrl/webTransportUrl are web-only options; they are ignored on
    // native targets but kept for API parity with the web implementation.
    return PortablePty._(
      transport ?? _NativePtyTransport.open(rows: rows, cols: cols),
    );
  }

  final PortablePtyTransport _transport;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('PTY is already closed.');
    }
  }

  /// Spawn a child process attached to this PTY.
  ///
  /// [command] is the executable path (e.g. `/bin/bash`).
  /// [args] is an optional list of arguments. If omitted, command is
  /// used as argv[0].
  /// [environment] is an optional map of environment variables. If omitted,
  /// the current environment is inherited.
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    _ensureOpen();
    _transport.spawn(command, args: args, environment: environment);
  }

  /// Read up to [maxBytes] from the PTY (child's stdout).
  ///
  /// Returns an empty list on EOF. Throws on error.
  /// This call blocks until data is available.
  Uint8List readSync(int maxBytes) {
    _ensureOpen();
    return _transport.readSync(maxBytes);
  }

  /// Write raw bytes to the PTY (child's stdin).
  ///
  /// Returns the number of bytes written.
  int writeBytes(Uint8List data) {
    _ensureOpen();
    return _transport.writeBytes(data);
  }

  /// Write a string to the PTY, encoded as UTF-8.
  int writeString(String text) {
    return writeBytes(Uint8List.fromList(utf8.encode(text)));
  }

  /// Resize the PTY to [rows] × [cols].
  void resize({required int rows, required int cols}) {
    _ensureOpen();
    _transport.resize(rows: rows, cols: cols);
  }

  /// The master file descriptor (POSIX) or -1 (Windows).
  int get masterFd {
    _ensureOpen();
    return _transport.masterFd;
  }

  /// The child process ID, or -1 if no child has been spawned.
  int get childPid {
    _ensureOpen();
    return _transport.childPid;
  }

  /// Current PTY size.
  ({int rows, int cols, int pixelWidth, int pixelHeight}) get size {
    _ensureOpen();
    return _transport.getSize();
  }

  /// Process group leader ID, or -1 if unavailable.
  int get processGroup {
    _ensureOpen();
    return _transport.processGroup;
  }

  /// Non-blocking check for child exit.
  ///
  /// Returns the exit code if the child has exited, or `null` if still
  /// running.
  int? tryWait() {
    _ensureOpen();
    return _transport.tryWait();
  }

  /// Block until the child process exits and return exit code.
  ///
  /// Returns the exit code from the native process.
  int wait() {
    _ensureOpen();
    return _transport.wait();
  }

  /// Send a POSIX signal to the child process.
  void kill([int signal = 15 /* SIGTERM */]) {
    _ensureOpen();
    _transport.kill(signal);
  }

  /// Get the current terminal mode.
  ({bool canonical, bool echo}) getMode() {
    _ensureOpen();
    return _transport.getMode();
  }

  /// Closes the PTY and frees all native resources.
  ///
  /// Kills the child process if still running. Safe to call multiple times.
  ///
  /// ```dart
  /// final pty = PortablePty.open();
  /// pty.spawn('/bin/sh');
  /// // ... use pty ...
  /// pty.close(); // always clean up
  /// ```
  void close() {
    if (_closed) return;
    _closed = true;
    _transport.close();
  }

  static void _check(bindings.PortablePtyResult result, String operation) {
    if (result != bindings.PortablePtyResult.Ok) {
      throw PtyException(operation, result);
    }
  }
}

/// Native transport implementation used on non-web targets.
final class _NativePtyTransport implements PortablePtyTransport {
  _NativePtyTransport._(this._handle);

  factory _NativePtyTransport.open({int rows = 24, int cols = 80}) {
    final out = calloc<ffi.Pointer<bindings.PortablePty>>();
    try {
      final result = bindings.portable_pty_open(rows, cols, out);
      PortablePty._check(result, 'portable_pty_open');
      final handle = out.value;
      if (handle == ffi.nullptr) {
        throw StateError('portable_pty_open returned null handle');
      }
      return _NativePtyTransport._(handle);
    } finally {
      calloc.free(out);
    }
  }

  final ffi.Pointer<bindings.PortablePty> _handle;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) {
      throw StateError('PTY is already closed.');
    }
  }

  @override
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    _ensureOpen();

    final cmdPtr = command.toNativeUtf8().cast<ffi.Char>();
    ffi.Pointer<ffi.Pointer<ffi.Char>> argvPtr = ffi.nullptr;
    ffi.Pointer<ffi.Pointer<ffi.Char>> envpPtr = ffi.nullptr;

    try {
      if (args != null && args.isNotEmpty) {
        final allArgs = <String>[command, ...args];
        argvPtr = calloc<ffi.Pointer<ffi.Char>>(allArgs.length + 1);
        for (var i = 0; i < allArgs.length; i++) {
          argvPtr[i] = allArgs[i].toNativeUtf8().cast<ffi.Char>();
        }
        argvPtr[allArgs.length] = ffi.nullptr;
      }

      if (environment != null) {
        final entries = environment.entries
            .map((e) => '${e.key}=${e.value}')
            .toList();
        envpPtr = calloc<ffi.Pointer<ffi.Char>>(entries.length + 1);
        for (var i = 0; i < entries.length; i++) {
          envpPtr[i] = entries[i].toNativeUtf8().cast<ffi.Char>();
        }
        envpPtr[entries.length] = ffi.nullptr;
      }

      final result = bindings.portable_pty_spawn(
        _handle,
        cmdPtr,
        argvPtr,
        envpPtr,
      );
      PortablePty._check(result, 'portable_pty_spawn');
    } finally {
      calloc.free(cmdPtr);

      if (argvPtr != ffi.nullptr) {
        for (var i = 0; argvPtr[i] != ffi.nullptr; i++) {
          calloc.free(argvPtr[i]);
        }
        calloc.free(argvPtr);
      }

      if (envpPtr != ffi.nullptr) {
        for (var i = 0; envpPtr[i] != ffi.nullptr; i++) {
          calloc.free(envpPtr[i]);
        }
        calloc.free(envpPtr);
      }
    }
  }

  @override
  Uint8List readSync(int maxBytes) {
    _ensureOpen();
    final buf = calloc<ffi.Uint8>(maxBytes);
    try {
      final n = bindings.portable_pty_read(_handle, buf, maxBytes);
      if (n < 0) {
        throw StateError('portable_pty_read failed');
      }
      if (n == 0) return Uint8List(0);
      return Uint8List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  int writeBytes(Uint8List data) {
    _ensureOpen();
    if (data.isEmpty) return 0;
    final buf = calloc<ffi.Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      final n = bindings.portable_pty_write(_handle, buf, data.length);
      if (n < 0) {
        throw StateError('portable_pty_write failed');
      }
      return n;
    } finally {
      calloc.free(buf);
    }
  }

  @override
  int writeString(String text) {
    return writeBytes(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void resize({required int rows, required int cols}) {
    _ensureOpen();
    final result = bindings.portable_pty_resize(_handle, rows, cols);
    PortablePty._check(result, 'portable_pty_resize');
  }

  @override
  int get masterFd {
    _ensureOpen();
    return bindings.portable_pty_master_fd(_handle);
  }

  @override
  int get childPid {
    _ensureOpen();
    return bindings.portable_pty_child_pid(_handle);
  }

  @override
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() {
    _ensureOpen();
    final rows = calloc<ffi.Uint16>();
    final cols = calloc<ffi.Uint16>();
    final pixelWidth = calloc<ffi.Uint16>();
    final pixelHeight = calloc<ffi.Uint16>();
    try {
      final result = bindings.portable_pty_get_size(
        _handle,
        rows,
        cols,
        pixelWidth,
        pixelHeight,
      );
      PortablePty._check(result, 'portable_pty_get_size');
      return (
        rows: rows.value,
        cols: cols.value,
        pixelWidth: pixelWidth.value,
        pixelHeight: pixelHeight.value,
      );
    } finally {
      calloc.free(rows);
      calloc.free(cols);
      calloc.free(pixelWidth);
      calloc.free(pixelHeight);
    }
  }

  @override
  int? tryWait() {
    _ensureOpen();
    final status = calloc<ffi.Int>();
    try {
      final result = bindings.portable_pty_wait(_handle, status);
      if (result == bindings.PortablePtyResult.Ok) {
        return status.value;
      }
      return null;
    } finally {
      calloc.free(status);
    }
  }

  @override
  int get processGroup {
    _ensureOpen();
    return bindings.portable_pty_process_group_leader(_handle);
  }

  @override
  int wait() {
    _ensureOpen();
    final status = calloc<ffi.Int>();
    try {
      final result = bindings.portable_pty_wait_blocking(_handle, status);
      PortablePty._check(result, 'portable_pty_wait_blocking');
      return status.value;
    } finally {
      calloc.free(status);
    }
  }

  @override
  ({bool canonical, bool echo}) getMode() {
    _ensureOpen();
    final canonical = calloc<ffi.Bool>();
    final echo = calloc<ffi.Bool>();
    try {
      final result = bindings.portable_pty_get_mode(_handle, canonical, echo);
      PortablePty._check(result, 'portable_pty_get_mode');
      return (canonical: canonical.value, echo: echo.value);
    } finally {
      calloc.free(canonical);
      calloc.free(echo);
    }
  }

  @override
  void kill([int signal = 15]) {
    _ensureOpen();
    final result = bindings.portable_pty_kill(_handle, signal);
    PortablePty._check(result, 'portable_pty_kill');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.portable_pty_close(_handle);
  }
}

/// Exception thrown when a PTY operation fails.
///
/// Contains the [operation] name and native [result] code for diagnostics.
///
/// ```dart
/// try {
///   pty.resize(rows: -1, cols: 80);
/// } on PtyException catch (e) {
///   print('${e.operation} failed: ${e.result}');
/// }
/// ```
class PtyException implements Exception {
  const PtyException(this.operation, this.result);

  final String operation;
  final bindings.PortablePtyResult result;

  @override
  String toString() => 'PtyException: $operation failed ($result)';
}
