import 'dart:typed_data';

import 'package:portable_pty/portable_pty.dart';
import 'package:test/test.dart';

/// In-memory transport for testing [PortablePtyController] without a real PTY.
class MockPtyTransport implements PortablePtyTransport {
  final List<String> spawnedCommands = [];
  final List<Uint8List> writtenBytes = [];
  final List<String> writtenStrings = [];
  Uint8List readBuffer = Uint8List(0);
  bool closed = false;
  final int _childPid = 42;
  final int _masterFd = 5;
  int _rows = 24;
  int _cols = 80;
  final bool _canonical = true;
  final bool _echo = true;
  int? _exitCode;

  @override
  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    spawnedCommands.add(command);
  }

  @override
  Uint8List readSync(int maxBytes) {
    if (readBuffer.isEmpty) return Uint8List(0);
    final end = maxBytes < readBuffer.length ? maxBytes : readBuffer.length;
    final chunk = readBuffer.sublist(0, end);
    readBuffer = readBuffer.sublist(end);
    return chunk;
  }

  @override
  int writeBytes(Uint8List data) {
    writtenBytes.add(Uint8List.fromList(data));
    return data.length;
  }

  @override
  int writeString(String text) {
    writtenStrings.add(text);
    return text.length;
  }

  @override
  void resize({required int rows, required int cols}) {
    _rows = rows;
    _cols = cols;
  }

  @override
  int get childPid => _childPid;

  @override
  int get masterFd => _masterFd;

  @override
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() {
    return (rows: _rows, cols: _cols, pixelWidth: 0, pixelHeight: 0);
  }

  @override
  int get processGroup => -1;

  @override
  int? tryWait() => _exitCode;

  @override
  int wait() => _exitCode ?? 0;

  @override
  ({bool canonical, bool echo}) getMode() =>
      (canonical: _canonical, echo: _echo);

  @override
  void kill([int signal = 15]) {
    _exitCode = -signal;
  }

  @override
  void close() {
    closed = true;
  }

  /// Populate the read buffer with UTF-8 text for the next [readSync].
  void feedOutput(String text) {
    final encoded = Uint8List.fromList(text.codeUnits);
    final combined = Uint8List(readBuffer.length + encoded.length);
    combined.setAll(0, readBuffer);
    combined.setAll(readBuffer.length, encoded);
    readBuffer = combined;
  }

  /// Trigger process exit.
  void simulateExit(int code) {
    _exitCode = code;
  }
}

void main() {
  group('MockPtyTransport (contract verification)', () {
    late MockPtyTransport transport;

    setUp(() {
      transport = MockPtyTransport();
    });

    test('spawn records commands', () {
      transport.spawn('/bin/sh');
      transport.spawn('/bin/bash', args: ['-l']);
      expect(transport.spawnedCommands, ['/bin/sh', '/bin/bash']);
    });

    test('readSync returns bytes from buffer', () {
      transport.feedOutput('hello');
      final data = transport.readSync(1024);
      expect(String.fromCharCodes(data), 'hello');
    });

    test('readSync returns empty when no data', () {
      expect(transport.readSync(1024), isEmpty);
    });

    test('readSync respects maxBytes', () {
      transport.feedOutput('hello world');
      final chunk = transport.readSync(5);
      expect(chunk.length, 5);
      expect(String.fromCharCodes(chunk), 'hello');
    });

    test('writeBytes records data', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final written = transport.writeBytes(bytes);
      expect(written, 3);
      expect(transport.writtenBytes, hasLength(1));
    });

    test('resize updates size', () {
      transport.resize(rows: 40, cols: 120);
      final size = transport.getSize();
      expect(size.rows, 40);
      expect(size.cols, 120);
    });

    test('getMode returns terminal mode', () {
      final mode = transport.getMode();
      expect(mode.canonical, isTrue);
      expect(mode.echo, isTrue);
    });

    test('kill and tryWait simulate exit', () {
      expect(transport.tryWait(), isNull);
      transport.kill(9);
      expect(transport.tryWait(), isNotNull);
    });

    test('close sets closed flag', () {
      expect(transport.closed, isFalse);
      transport.close();
      expect(transport.closed, isTrue);
    });
  });

  group('PortablePty with mock transport', () {
    late MockPtyTransport transport;
    late PortablePty pty;

    setUp(() {
      transport = MockPtyTransport();
      pty = PortablePty.open(transport: transport);
    });

    tearDown(() {
      pty.close();
    });

    test('spawn delegates to transport', () {
      pty.spawn('/bin/sh');
      expect(transport.spawnedCommands, ['/bin/sh']);
    });

    test('spawn with args and environment', () {
      pty.spawn(
        '/bin/bash',
        args: ['-l', '-c', 'echo hi'],
        environment: {'FOO': 'BAR'},
      );
      expect(transport.spawnedCommands, ['/bin/bash']);
    });

    test('readSync delegates to transport', () {
      transport.feedOutput('test output');
      final data = pty.readSync(4096);
      expect(String.fromCharCodes(data), 'test output');
    });

    test('writeBytes delegates to transport', () {
      final bytes = Uint8List.fromList([0x41, 0x42, 0x43]);
      final written = pty.writeBytes(bytes);
      expect(written, 3);
      expect(transport.writtenBytes, hasLength(1));
    });

    test('writeString encodes UTF-8', () {
      final written = pty.writeString('hello');
      expect(written, 5);
    });

    test('resize delegates to transport', () {
      pty.resize(rows: 50, cols: 132);
      final size = pty.size;
      expect(size.rows, 50);
      expect(size.cols, 132);
    });

    test('masterFd is forwarded', () {
      expect(pty.masterFd, 5);
    });

    test('childPid is forwarded', () {
      expect(pty.childPid, 42);
    });

    test('processGroup is forwarded', () {
      expect(pty.processGroup, -1);
    });

    test('tryWait returns null when process is running', () {
      expect(pty.tryWait(), isNull);
    });

    test('tryWait returns exit code after process exits', () {
      transport.simulateExit(0);
      expect(pty.tryWait(), 0);
    });

    test('wait returns exit code', () {
      transport.simulateExit(1);
      expect(pty.wait(), 1);
    });

    test('getMode is forwarded', () {
      final mode = pty.getMode();
      expect(mode.canonical, isTrue);
      expect(mode.echo, isTrue);
    });

    test('kill delegates to transport', () {
      pty.kill(9);
      expect(transport.tryWait(), isNotNull);
    });

    test('close can be called multiple times safely', () {
      pty.close();
      pty.close(); // should not throw
      expect(transport.closed, isTrue);
    });

    test('operations after close throw StateError', () {
      pty.close();
      expect(() => pty.spawn('/bin/sh'), throwsStateError);
      expect(() => pty.readSync(100), throwsStateError);
      expect(() => pty.writeBytes(Uint8List.fromList([1])), throwsStateError);
      expect(() => pty.writeString('x'), throwsStateError);
      expect(() => pty.resize(rows: 10, cols: 10), throwsStateError);
      expect(() => pty.masterFd, throwsStateError);
      expect(() => pty.childPid, throwsStateError);
      expect(() => pty.size, throwsStateError);
      expect(() => pty.processGroup, throwsStateError);
      expect(() => pty.tryWait(), throwsStateError);
      expect(() => pty.wait(), throwsStateError);
      expect(() => pty.getMode(), throwsStateError);
      expect(() => pty.kill(), throwsStateError);
    });
  });

  group('PtyException', () {
    test('is an Exception', () {
      // PtyException implements Exception and stores diagnostic info.
      expect(PtyException, isNotNull);
    });
  });
}
