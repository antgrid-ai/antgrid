import 'dart:typed_data';

import 'package:portable_pty/portable_pty.dart';
import 'package:test/test.dart';

/// In-memory transport for testing [PortablePtyController] without a real PTY.
class MockPtyTransport implements PortablePtyTransport {
  final List<String> spawnedCommands = [];
  final List<Uint8List> writtenBytes = [];
  Uint8List readBuffer = Uint8List(0);
  bool closed = false;
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
    return writeBytes(Uint8List.fromList(text.codeUnits));
  }

  @override
  void resize({required int rows, required int cols}) {}

  @override
  int get childPid => 42;

  @override
  int get masterFd => 5;

  @override
  ({int rows, int cols, int pixelWidth, int pixelHeight}) getSize() =>
      (rows: 24, cols: 80, pixelWidth: 0, pixelHeight: 0);

  @override
  int get processGroup => -1;

  @override
  int? tryWait() => _exitCode;

  @override
  int wait() => _exitCode ?? 0;

  @override
  ({bool canonical, bool echo}) getMode() => (canonical: true, echo: true);

  @override
  void kill([int signal = 15]) {
    _exitCode = -signal;
  }

  @override
  void close() {
    closed = true;
  }

  void feedOutput(String text) {
    final encoded = Uint8List.fromList(text.codeUnits);
    final combined = Uint8List(readBuffer.length + encoded.length);
    combined.setAll(0, readBuffer);
    combined.setAll(readBuffer.length, encoded);
    readBuffer = combined;
  }
}

void main() {
  group('PortablePtyController', () {
    late PortablePtyController controller;
    late MockPtyTransport transport;

    setUp(() {
      transport = MockPtyTransport();
      controller = PortablePtyController(
        transport: transport,
        defaultShell: '/bin/sh',
      );
    });

    tearDown(() {
      if (!controller.isDisposed) {
        controller.dispose();
      }
    });

    test('initial state', () {
      expect(controller.isRunning, isFalse);
      expect(controller.revision, 0);
      expect(controller.lineCount, 1);
      expect(controller.lines, ['']);
    });

    test('start spawns PTY and sets running', () async {
      await controller.start();
      expect(controller.isRunning, isTrue);
      expect(controller.revision, greaterThan(0));
      // The started message should be in lines
      expect(controller.lines.any((l) => l.contains('started')), isTrue);
    });

    test('start is idempotent when already running', () async {
      await controller.start();
      final rev = controller.revision;
      await controller.start();
      expect(controller.revision, rev, reason: 'second start should be no-op');
    });

    test('stop kills process and sets not running', () async {
      await controller.start();
      await controller.stop();
      expect(controller.isRunning, isFalse);
      expect(controller.lines.any((l) => l.contains('terminated')), isTrue);
    });

    test('stop when not started is safe', () async {
      await controller.stop();
      expect(controller.isRunning, isFalse);
    });

    test('readOutput returns text and appends to lines', () async {
      await controller.start();
      transport.feedOutput('hello world');
      final text = controller.readOutput();
      expect(text, 'hello world');
      expect(controller.lines.any((l) => l.contains('hello world')), isTrue);
    });

    test('readOutput returns empty when no PTY', () {
      expect(controller.readOutput(), isEmpty);
    });

    test('write sends text to PTY', () async {
      await controller.start();
      final sent = controller.write('ls\n');
      expect(sent, isTrue);
    });

    test('write returns false when no PTY', () {
      expect(controller.write('x'), isFalse);
    });

    test('writeBytes sends bytes to PTY', () async {
      await controller.start();
      final sent = controller.writeBytes(Uint8List.fromList([0x41, 0x42]));
      expect(sent, isTrue);
    });

    test('writeBytes returns false when no PTY', () {
      expect(controller.writeBytes(Uint8List.fromList([1])), isFalse);
    });

    test('appendDebugOutput adds text to buffer', () {
      controller.appendDebugOutput('debug line');
      expect(controller.lines.any((l) => l.contains('debug line')), isTrue);
    });

    test('clear resets lines', () {
      controller.appendDebugOutput('some\ntext');
      expect(controller.lineCount, greaterThan(1));
      controller.clear();
      expect(controller.lines, ['']);
    });

    test('tryWait returns null when no PTY', () {
      expect(controller.tryWait(), isNull);
    });

    test('revision increments on state changes', () {
      final initial = controller.revision;
      controller.appendDebugOutput('x');
      expect(controller.revision, greaterThan(initial));
    });

    test('listener notifications on state changes', () {
      var notified = 0;
      controller.addListener(() => notified++);
      controller.appendDebugOutput('test');
      expect(notified, greaterThan(0));
    });

    test('dispose stops PTY and prevents further notifications', () async {
      await controller.start();
      var notified = 0;
      controller.addListener(() => notified++);
      controller.dispose();
      expect(controller.isDisposed, isTrue);
    });
  });

  group('PortablePtyController line buffer', () {
    late PortablePtyController controller;
    late MockPtyTransport transport;

    setUp(() {
      transport = MockPtyTransport();
      controller = PortablePtyController(transport: transport, maxLines: 5);
    });

    tearDown(() {
      if (!controller.isDisposed) {
        controller.dispose();
      }
    });

    test('newlines create new line entries', () {
      controller.appendDebugOutput('line1\nline2\nline3');
      // Lines: [''] + 'line1' on first, then '\n' creates new,
      // then 'line2', '\n' creates new, then 'line3'
      final lines = controller.lines;
      expect(lines.any((l) => l == 'line1'), isTrue);
      expect(lines.any((l) => l == 'line2'), isTrue);
      expect(lines.any((l) => l == 'line3'), isTrue);
    });

    test('carriage return resets current line', () {
      controller.appendDebugOutput('old text\rnew');
      final lines = controller.lines;
      expect(lines.last, 'new');
    });

    test('backspace removes last character', () {
      controller.appendDebugOutput('abc\x08');
      expect(controller.lines.last, 'ab');
    });

    test('backspace on empty line is safe', () {
      controller.appendDebugOutput('\x08');
      expect(controller.lines.last, '');
    });

    test('maxLines limit is enforced', () {
      controller.appendDebugOutput('1\n2\n3\n4\n5\n6\n7\n8');
      expect(controller.lineCount, lessThanOrEqualTo(5));
    });

    test('multiple newlines create multiple empty lines', () {
      controller.appendDebugOutput('\n\n');
      expect(controller.lineCount, greaterThanOrEqualTo(3));
    });
  });

  group('PortablePtyController with custom shell', () {
    test('uses defaultShell when start is called without args', () async {
      final transport = MockPtyTransport();
      final controller = PortablePtyController(
        transport: transport,
        defaultShell: '/usr/bin/zsh',
      );
      await controller.start();
      expect(controller.lines.any((l) => l.contains('/usr/bin/zsh')), isTrue);
      controller.dispose();
    });

    test('uses explicit shell over default', () async {
      final transport = MockPtyTransport();
      final controller = PortablePtyController(
        transport: transport,
        defaultShell: '/usr/bin/zsh',
      );
      await controller.start(shell: '/bin/fish');
      expect(controller.lines.any((l) => l.contains('/bin/fish')), isTrue);
      controller.dispose();
    });
  });
}
