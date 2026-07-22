import 'dart:convert';
import 'dart:typed_data';

import 'package:portable_pty/portable_pty.dart';

/// Example custom transport for users who want to provide a remote PTY transport.
///
/// This transport mirrors a tiny echo server: everything written to stdin is
/// pushed back into the read buffer with a prefix so consumers can verify the
/// transport wiring.
final class _EchoTransport implements PortablePtyTransport {
  bool _closed = false;
  bool _spawned = false;
  final List<int> _inputBuffer = <int>[];
  int _rows = 24;
  int _cols = 80;

  @override
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    if (_closed) {
      throw StateError('transport already closed');
    }
    if (_spawned) {
      throw StateError('transport already spawned');
    }
    _spawned = true;

    final header = <int>[...utf8.encode('[session=$command]\n')];
    if (args != null && args.isNotEmpty) {
      header.addAll(utf8.encode('args=${args.join(' ')}\n'));
    }
    _inputBuffer.insertAll(0, header);
  }

  @override
  Uint8List readSync(int maxBytes) {
    if (_closed || !_spawned || maxBytes <= 0 || _inputBuffer.isEmpty) {
      return Uint8List(0);
    }
    final take = maxBytes.clamp(0, _inputBuffer.length);
    final out = Uint8List(take);
    for (var i = 0; i < take; i++) {
      out[i] = _inputBuffer.removeAt(0);
    }
    return out;
  }

  @override
  int writeBytes(Uint8List data) {
    if (_closed || !_spawned) {
      throw StateError('transport not active');
    }
    if (data.isEmpty) {
      return 0;
    }
    final echoed = <int>[
      ...utf8.encode('echo> '),
      ...data,
      ...utf8.encode('\n'),
    ];
    _inputBuffer.addAll(echoed);
    return data.length;
  }

  @override
  int writeString(String text) {
    return writeBytes(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void resize({required int rows, required int cols}) {
    _rows = rows;
    _cols = cols;
  }

  @override
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() {
    return (rows: _rows, cols: _cols, pixelWidth: 0, pixelHeight: 0);
  }

  @override
  int get processGroup => -1;

  @override
  int get masterFd => -1;

  @override
  int get childPid => -1;

  @override
  int? tryWait() => 0;

  @override
  int wait() {
    return 0;
  }

  @override
  ({bool canonical, bool echo}) getMode() => (canonical: true, echo: true);

  @override
  void kill([int signal = 15]) {
    _inputBuffer.clear();
    _closed = true;
  }

  @override
  void close() {
    _inputBuffer.clear();
    _closed = true;
  }
}

void main() {
  final pty = PortablePty.open(transport: _EchoTransport(), rows: 24, cols: 80);

  pty.spawn('mock-session');
  pty.writeString('hello');

  final out = pty.readSync(4096);
  print(utf8.decode(out));

  pty.close();
}
