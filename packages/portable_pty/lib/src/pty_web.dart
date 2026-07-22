/// Web compatibility layer for environments where native PTY is unavailable.
///
/// On web, PTY transport is provided by a remote backend (WebSocket or
/// WebTransport). The `PortablePtyTransport` interface allows plugging
/// alternative web transports.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'pty_transport.dart';

/// Open a PTY-like connection in browser targets.
///
/// On web this delegates to a [PortablePtyTransport], allowing custom
/// implementations to integrate with remote pty APIs.
///
/// Transports are expected to manage their own socket lifecycle; this class only
/// provides a normalizing facade for the core PTY surface.
final class PortablePty {
  PortablePty._(this._transport);

  /// Open a new portable PTY transport handle.
  ///
  /// [webSocketUrl] and [webTransportUrl], when provided, act as default
  /// endpoint fallbacks for [spawn]. `webTransportUrl` has precedence when both
  /// are supplied.
  factory PortablePty.open({
    int rows = 24,
    int cols = 80,
    String? webSocketUrl,
    String? webTransportUrl,
    PortablePtyTransport? transport,
  }) {
    if (rows <= 0 || cols <= 0) {
      throw RangeError('rows and cols must be greater than zero.');
    }

    final resolvedTransport =
        transport ??
        (webTransportUrl != null
            ? PortablePtyWebTransportTransport(
                webTransportEndpoint: webTransportUrl,
              )
            : PortablePtyWebSocketTransport(webSocketEndpoint: webSocketUrl));
    return PortablePty._(resolvedTransport);
  }

  /// Whether this implementation is available on web targets.
  static const bool isSupported = true;

  final PortablePtyTransport _transport;

  bool get isConnected => _transport is PortablePtyWebSocketTransport
      ? (_transport as PortablePtyWebSocketTransport).isConnected
      : true;

  void _ensureOpen() {
    // The web transport handles open/close lifecycle internally.
  }

  /// Starts the remote PTY session.
  ///
  /// The optional [command] becomes the spawn command for the selected transport.
  /// For the default websocket transport this is also interpreted as the remote
  /// endpoint when no explicit transport endpoint was set.
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    _ensureOpen();
    _transport.spawn(command, args: args, environment: environment);
  }

  /// Read output bytes from the transport receive queue.
  Uint8List readSync(int maxBytes) {
    _ensureOpen();
    return _transport.readSync(maxBytes);
  }

  /// Write raw bytes to the PTY transport.
  int writeBytes(Uint8List data) {
    _ensureOpen();
    return _transport.writeBytes(data);
  }

  /// Write a string to the PTY transport.
  int writeString(String text) {
    final bytes = utf8.encode(text);
    return writeBytes(Uint8List.fromList(bytes));
  }

  /// Resizing is not supported for browser transport targets.
  void resize({required int rows, required int cols}) {
    _transport.resize(rows: rows, cols: cols);
  }

  /// File descriptor access is transport-specific and not guaranteed in web.
  int get masterFd => _transport.masterFd;

  /// Child process id is transport-specific and may be unsupported on web.
  int get childPid => _transport.childPid;

  /// Non-blocking check for child exit.
  int? tryWait() => _transport.tryWait();

  /// Closes and releases the transport.
  void kill([int signal = 15]) {
    _transport.kill(signal);
  }

  /// Returns terminal mode data when supported by the backend transport.
  ({bool canonical, bool echo}) getMode() => _transport.getMode();

  /// Close transport and release resources.
  void close() {
    _transport.close();
  }
}

/// Exception thrown when a PTY operation fails.
class PtyException implements Exception {
  const PtyException(this.operation, this.result);

  final String operation;
  final Object? result;

  @override
  String toString() => 'PtyException: $operation failed ($result)';
}

/// Default websocket transport used by [PortablePty.open] on web targets.
///
/// This implementation is intentionally minimal and accepts a single websocket
/// endpoint. Consumers can provide their own transport by passing one to
/// [PortablePty.open].
///
/// Message boundaries are preserved to a best-effort queue-backed model. This
/// transport is intentionally simple and suitable for demos and tooling backends.
final class PortablePtyWebSocketTransport implements PortablePtyTransport {
  PortablePtyWebSocketTransport({required String? webSocketEndpoint})
    : _webSocketEndpoint = webSocketEndpoint;

  static Never _unsupported() {
    throw UnsupportedError(
      'PortablePty on web requires a ws/wss endpoint. '
      'Pass the endpoint as command to spawn(), or set webSocketUrl in open().',
    );
  }

  final String? _webSocketEndpoint;
  web.WebSocket? _socket;
  bool _closed = false;
  bool _spawned = false;
  bool _connected = false;
  final Queue<int> _buffer = Queue<int>();

  bool get isConnected => _connected;

  String _resolveEndpoint(String command) {
    if (command.trim().isNotEmpty) {
      return command.trim();
    }
    return _webSocketEndpoint?.trim() ?? '';
  }

  bool _isValidWebSocketEndpoint(String value) {
    return value.startsWith('ws://') || value.startsWith('wss://');
  }

  @override
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    if (_closed) {
      throw StateError('PTY transport is already closed.');
    }
    if (_spawned) {
      throw StateError('PortablePty already spawned.');
    }

    final endpoint = _resolveEndpoint(command);
    if (!_isValidWebSocketEndpoint(endpoint)) {
      _unsupported();
    }

    final socket = web.WebSocket(endpoint);
    try {
      socket.binaryType = 'arraybuffer';
    } catch (_) {
      // Some runtimes may not expose this setter.
    }

    socket.addEventListener(
      'open',
      ((web.Event _) {
        _connected = true;
        final startupArgs = args;
        if (startupArgs != null && startupArgs.isNotEmpty) {
          try {
            socket.send(startupArgs.join('\u0000').toJS);
          } on Object {
            // Ignore startup write failures; caller handles runtime errors on I/O.
          }
        }
        if (environment != null && environment.isNotEmpty) {
          try {
            socket.send('env:${jsonEncode(environment)}'.toJS);
          } on Object {
            // Ignore startup write failures.
          }
        }
      }).toJS,
    );

    socket.addEventListener(
      'message',
      ((web.MessageEvent event) {
        final data = event.data;
        if (data.isA<JSString>()) {
          _buffer.addAll(utf8.encode((data as JSString).toDart));
        } else if (data.isA<JSArrayBuffer>()) {
          _buffer.addAll((data as JSArrayBuffer).toDart.asUint8List());
        }
      }).toJS,
    );

    socket.addEventListener(
      'close',
      ((web.Event _) {
        _connected = false;
      }).toJS,
    );

    socket.addEventListener(
      'error',
      ((web.Event _) {
        _connected = false;
      }).toJS,
    );

    _socket = socket;
    _spawned = true;
  }

  @override
  Uint8List readSync(int maxBytes) {
    if (_closed || maxBytes <= 0 || !_connected) {
      return Uint8List(0);
    }

    final available = _buffer.length;
    final take = available < maxBytes ? available : maxBytes;
    if (take == 0) {
      return Uint8List(0);
    }

    final out = Uint8List(take);
    for (var i = 0; i < take; i++) {
      out[i] = _buffer.removeFirst();
    }
    return out;
  }

  @override
  int writeBytes(Uint8List data) {
    if (_closed) {
      throw StateError('PortablePty websocket is already closed.');
    }
    final socket = _socket;
    if (socket == null || !_connected) {
      throw StateError('PortablePty websocket is not connected.');
    }
    if (data.isEmpty) return 0;

    socket.send(data.toJS);
    return data.length;
  }

  @override
  int writeString(String text) {
    return writeBytes(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void resize({required int rows, required int cols}) {
    _unsupported();
  }

  @override
  int get masterFd {
    _unsupported();
  }

  @override
  int get childPid {
    _unsupported();
  }

  @override
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() {
    _unsupported();
  }

  @override
  int get processGroup {
    _unsupported();
  }

  @override
  int? tryWait() {
    return null;
  }

  @override
  int wait() {
    _unsupported();
  }

  @override
  ({bool canonical, bool echo}) getMode() {
    _unsupported();
  }

  @override
  void kill([int signal = 15]) {
    _close();
  }

  @override
  void close() {
    _close();
  }

  void _close() {
    if (_closed) {
      return;
    }

    _closed = true;
    _connected = false;
    _spawned = false;
    _socket?.close();
    _socket = null;
    _buffer.clear();
  }
}

/// Browser WebTransport transport.
///
/// This transport is intended for environments that expose `window.WebTransport`.
final class PortablePtyWebTransportTransport implements PortablePtyTransport {
  PortablePtyWebTransportTransport({required String webTransportEndpoint})
    : _webTransportEndpoint = webTransportEndpoint;

  static Never _unsupported() {
    throw UnsupportedError(
      'PortablePty on web requires a WebTransport-capable endpoint and browser.',
    );
  }

  final String _webTransportEndpoint;
  JSObject? _transport;
  JSObject? _writer;
  JSObject? _reader;
  bool _closed = false;
  bool _spawned = false;
  bool _connected = false;
  final Queue<int> _buffer = Queue<int>();

  bool get isConnected => _connected;

  bool _isValidWebTransportEndpoint(String value) {
    return value.startsWith('https://') || value.startsWith('http://');
  }

  String _resolveEndpoint(String command) {
    if (command.trim().isNotEmpty) {
      return command.trim();
    }
    return _webTransportEndpoint.trim();
  }

  void _appendDatagramChunk(JSObject chunk) {
    final byteLength = (chunk['byteLength'] as JSNumber?)?.toDartInt;
    if (byteLength == null || byteLength <= 0) {
      return;
    }

    for (var i = 0; i < byteLength; i++) {
      final value = (chunk[i.toString()] as JSNumber?)?.toDartInt;
      if (value != null) {
        _buffer.add(value & 0xff);
      }
    }
  }

  void _pumpReader() {
    final reader = _reader;
    if (reader == null) {
      return;
    }

    void loop() {
      if (_closed || !_connected) {
        return;
      }

      final readPromise = reader.callMethod<JSPromise>('read'.toJS);
      readPromise.toDart
          .then((JSAny? result) {
            if (_closed || result == null) {
              return;
            }

            final resultObj = result as JSObject;
            final done = (resultObj['done'] as JSBoolean?)?.toDart;
            if (done == true) {
              _connected = false;
              return;
            }

            final value = resultObj['value'];
            if (value.isA<JSString>()) {
              _buffer.addAll(utf8.encode((value as JSString).toDart));
            } else if (value != null) {
              _appendDatagramChunk(value as JSObject);
            }

            loop();
          })
          .catchError((_) {
            _connected = false;
            return null;
          });
    }

    loop();
  }

  void _sendText(String message) {
    final writer = _writer;
    if (writer == null) {
      throw StateError('PortablePty transport is not connected.');
    }

    final writePromise = writer.callMethod<JSPromise>(
      'write'.toJS,
      message.toJS,
    );
    writePromise.toDart.catchError((_) {
      _connected = false;
      return null;
    });
  }

  void _initialize() {
    final transport = _transport;
    if (transport == null) {
      return;
    }

    final datagrams = transport['datagrams'] as JSObject?;
    if (datagrams == null) {
      throw StateError('WebTransport datagrams are unavailable.');
    }

    final writable = datagrams['writable'] as JSObject?;
    if (writable == null) {
      throw StateError('WebTransport writable stream is unavailable.');
    }
    _writer = writable.callMethod<JSObject>('getWriter'.toJS);

    final readable = datagrams['readable'] as JSObject?;
    if (readable == null) {
      return;
    }

    _reader = readable.callMethod<JSObject>('getReader'.toJS);
    _pumpReader();
  }

  Future<void> _waitForOpen() {
    final transport = _transport;
    if (transport == null) {
      return Future<void>.value();
    }

    final ready = transport['ready'] as JSPromise;
    return ready.toDart
        .then((_) {
          if (_closed) {
            return null;
          }
          _connected = true;
          _initialize();
          return null;
        })
        .catchError((_) {
          _connected = false;
          _close();
          return null;
        });
  }

  @override
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    if (_closed) {
      throw StateError('PTY transport is already closed.');
    }
    if (_spawned) {
      throw StateError('PortablePty already spawned.');
    }

    final ctor = globalContext['WebTransport'];
    if (ctor == null) {
      _unsupported();
    }

    final endpoint = _resolveEndpoint(command);
    if (!_isValidWebTransportEndpoint(endpoint)) {
      _unsupported();
    }

    _transport = (ctor as JSFunction).callAsConstructor<JSObject>(
      endpoint.toJS,
    );

    final closed = _transport!['closed'] as JSPromise?;
    if (closed != null) {
      closed.toDart
          .then((_) {
            _connected = false;
            return null;
          })
          .catchError((_) {
            _connected = false;
            return null;
          });
    }

    final readyFuture = _waitForOpen();
    readyFuture
        .then((_) {
          if (!_connected) {
            return null;
          }

          if (args != null && args.isNotEmpty) {
            _sendText(jsonEncode({'args': args}));
          }
          if (environment != null && environment.isNotEmpty) {
            _sendText(jsonEncode({'environment': environment}));
          }
          return null;
        })
        .catchError((_) {
          _connected = false;
          return null;
        });

    _spawned = true;
  }

  @override
  Uint8List readSync(int maxBytes) {
    if (_closed || maxBytes <= 0 || !_connected) {
      return Uint8List(0);
    }

    final available = _buffer.length;
    final take = available < maxBytes ? available : maxBytes;
    if (take == 0) {
      return Uint8List(0);
    }

    final out = Uint8List(take);
    for (var i = 0; i < take; i++) {
      out[i] = _buffer.removeFirst();
    }
    return out;
  }

  @override
  int writeBytes(Uint8List data) {
    if (_closed) {
      throw StateError('PortablePty transport is already closed.');
    }
    if (_writer == null || !_connected) {
      throw StateError('PortablePty transport is not connected.');
    }
    if (data.isEmpty) {
      return 0;
    }

    _sendText(utf8.decode(data, allowMalformed: true));
    return data.length;
  }

  @override
  int writeString(String text) {
    return writeBytes(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void resize({required int rows, required int cols}) {
    _unsupported();
  }

  @override
  int get masterFd {
    _unsupported();
  }

  @override
  int get childPid {
    _unsupported();
  }

  @override
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() {
    _unsupported();
  }

  @override
  int get processGroup {
    _unsupported();
  }

  @override
  int? tryWait() {
    return null;
  }

  @override
  int wait() {
    _unsupported();
  }

  @override
  ({bool canonical, bool echo}) getMode() {
    _unsupported();
  }

  @override
  void kill([int signal = 15]) {
    _close();
  }

  @override
  void close() {
    _close();
  }

  void _close() {
    if (_closed) {
      return;
    }

    _closed = true;
    _connected = false;
    _spawned = false;
    final transport = _transport;
    if (transport != null) {
      try {
        transport.callMethod<JSAny?>('close'.toJS);
      } catch (_) {}
    }
    _transport = null;
    final writer = _writer;
    if (writer != null) {
      try {
        writer.callMethod<JSAny?>('releaseLock'.toJS);
      } catch (_) {}
    }
    _writer = null;
    _reader = null;
    _buffer.clear();
  }
}
