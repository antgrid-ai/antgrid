import 'dart:typed_data';

/// Transport contract for byte-stream PTY/terminal backends.
///
/// Platform implementations can adapt this contract to local PTY handles,
/// remote websocket endpoints, SSH bridges, or any other stream-capable
/// terminal transport.
///
/// ```dart
/// class EchoPtyTransport implements PortablePtyTransport {
///   final _buf = <int>[];
///
///   @override
///   void spawn(String command, {List<String>? args, Map<String, String>? environment}) {}
///
///   @override
///   Uint8List readSync(int maxBytes) {
///     final chunk = Uint8List.fromList(_buf.take(maxBytes).toList());
///     _buf.removeRange(0, chunk.length);
///     return chunk;
///   }
///
///   @override
///   int writeBytes(Uint8List data) {
///     _buf.addAll(data); // echo back
///     return data.length;
///   }
///
///   // ... remaining overrides ...
/// }
/// ```
abstract class PortablePtyTransport {
  /// Launches the backend process on this transport.
  ///
  /// [command] is interpreted by the transport implementation. Native
  /// transports typically treat this as an executable path, while websocket
  /// transports commonly treat it as the transport endpoint.
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  });

  /// Reads up to [maxBytes] bytes from the terminal stream.
  Uint8List readSync(int maxBytes);

  /// Writes raw bytes to the terminal input stream.
  ///
  /// Returns the number of bytes written.
  int writeBytes(Uint8List data);

  /// Writes UTF-8 text to the terminal input stream.
  int writeString(String text);

  /// Resizes the terminal.
  void resize({required int rows, required int cols});

  /// Returns the current process identifier for native backends.
  ///
  /// Some web transport implementations may return `-1` when process IDs are
  /// unavailable.
  int get childPid;

  /// Returns a transport-specific file descriptor for native backends.
  ///
  /// Web implementations may return `-1` when descriptors are not available.
  int get masterFd;

  /// Returns the current terminal size as reported by the backend.
  ///
  /// Implementations that cannot query terminal size should throw
  /// [UnsupportedError].
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() {
    throw UnsupportedError('PortablePtyTransport.getSize is not supported.');
  }

  /// Returns the process group identifier when available.
  ///
  /// Implementations that cannot resolve a process group should return `-1`.
  int get processGroup => -1;

  /// Non-blocking check for process exit.
  int? tryWait();

  /// Blocks until the child process exits and returns exit code.
  ///
  /// Implementations that cannot block should throw [UnsupportedError].
  int wait() {
    throw UnsupportedError('PortablePtyTransport.wait is not supported.');
  }

  /// Returns the current terminal mode when available.
  ({bool canonical, bool echo}) getMode();

  /// Sends a signal to the running process, when supported.
  void kill([int signal = 15]);

  /// Closes the transport.
  void close();
}
