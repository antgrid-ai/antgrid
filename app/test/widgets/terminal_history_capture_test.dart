import 'dart:convert';

import 'package:antgrid/widgets/terminal_history_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  late GhosttyTerminalController controller;
  setUp(() {
    controller = GhosttyTerminalController(initialCols: 8, initialRows: 3);
  });
  tearDown(() => controller.dispose());

  void write(String value) => controller.appendOutputBytes(utf8.encode(value));

  test('captures native Unicode cells and continuation geometry', () {
    write('abcde界e\u0301Z');
    final rows = captureTerminalHistoryScreen(controller, 42);
    expect(rows.map((row) => row.rowId), [42, 43, 44]);
    expect(rows.first.cols, 8);
    expect(rows.first.spans.map((span) => span.text).join(), 'abcde界e\u0301');
    expect(
      rows.first.spans.map((span) => span.cells).reduce((a, b) => a + b),
      8,
    );
    expect(rows.first.spans[5].cells, 2);
    expect(rows.first.wrapped, isFalse);
    expect(rows[1].wrapped, isTrue);
    expect(rows[1].spans.first.text, 'Z');
  });

  test('retains native extended styling and OSC 8 targets', () {
    write(
      '\x1b[1;2;3;4:3;5;7;8;9;53;38;2;12;34;56;48;5;123;58;2;9;8;7m'
      '\x1b]8;;https://example.com/path\x1b\\X\x1b]8;;\x1b\\\x1b[0mY',
    );
    final spans = captureTerminalHistoryScreen(controller, 0).first.spans;
    expect(spans.first.uri, 'https://example.com/path');
    expect(spans[1].uri, isNull);
    for (final code in [
      '1',
      '2',
      '3',
      '4:3',
      '5',
      '7',
      '8',
      '9',
      '53',
      '38;2;12;34;56',
      '48;5;123',
      '58;2;9;8;7',
    ]) {
      expect(spans.first.sgr, contains(code));
    }
    expect(spans[1].sgr, '\x1b[0m');
  });

  test('copies screen independently of later output and resize', () {
    write('first');
    final rows = captureTerminalHistoryScreen(controller, 12);
    write('\x1b[2J\x1b[Hsecond');
    controller.resize(cols: 4, rows: 2);
    expect(rows.first.cols, 8);
    expect(rows.first.spans.map((span) => span.text).join(), 'first   ');
    expect(() => rows.clear(), throwsUnsupportedError);
    expect(() => rows.first.spans.clear(), throwsUnsupportedError);
  });

  test('alternate screen is excluded and normal screen survives return', () {
    write('shell\x1b[?1049hfullscreen');
    expect(captureTerminalHistoryScreen(controller, 0), isEmpty);
    write('\x1b[?1049l');
    expect(
      captureTerminalHistoryScreen(
        controller,
        0,
      ).first.spans.map((span) => span.text).join(),
      'shell   ',
    );
  });

  test('background-only erased cells preserve their fill', () {
    write('\x1b[48;2;12;34;56m\x1b[2K');
    final spans = captureTerminalHistoryScreen(controller, 0).first.spans;
    expect(spans.every((span) => span.text == ' '), isTrue);
    expect(spans.every((span) => span.sgr.contains('48;2;12;34;56')), isTrue);
  });

  test('wide wrap padding does not become a logical space', () {
    write('1234567界Z');
    final rows = captureTerminalHistoryScreen(controller, 0);
    expect(rows[1].wrapped, isTrue);
    expect(rows.first.spans.map((span) => span.text).join(), '1234567');
    expect(rows[1].spans.first.text, '界');
  });
}
