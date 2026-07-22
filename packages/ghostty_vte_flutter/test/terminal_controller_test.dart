import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'support/native_terminal.dart';

final bool _hasNativeTerminal = hasNativeTerminal;

void main() {
  test('controller parses OSC title and CRLF-delimited line buffer', () {
    if (!_hasNativeTerminal) {
      return;
    }

    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);

    controller.appendDebugOutput('\x1b]0;Studio Title\x07hello\r\nworld');

    expect(controller.title, 'Studio Title');
    expect(controller.lines, isNotEmpty);
    expect(controller.lines[0], 'hello');
    expect(controller.lines[1], 'world');
  });

  test(
    'controller exposes a native render snapshot for live viewport data',
    () {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller = GhosttyTerminalController();
      addTearDown(controller.dispose);

      controller.appendDebugOutput('\x1b[31mA\x1b[0mB');

      final renderSnapshot = controller.renderSnapshot;
      expect(renderSnapshot, isNotNull);
      expect(renderSnapshot!.rowsData, isNotEmpty);
      expect(renderSnapshot.rowsData.first.cells.first.text, 'A');
    },
  );

  test(
    'engine viewport scrolls through scrollback and renders history rows',
    () {
      if (!_hasNativeTerminal) {
        return;
      }

      // 6 visible rows, plenty of scrollback. Emit 30 distinguishable lines so
      // the live viewport shows only the tail and history must be scrolled to.
      final controller = GhosttyTerminalController(
        initialCols: 20,
        initialRows: 6,
      );
      addTearDown(controller.dispose);

      final buffer = StringBuffer();
      for (var i = 0; i < 30; i++) {
        buffer.write('line$i\r\n');
      }
      controller.appendDebugOutput(buffer.toString());

      String firstCellOfRow(GhosttyTerminalRenderSnapshot snap, int row) =>
          snap.rowsData[row].cells
              .map((c) => c.text)
              .join()
              .trimRight();

      // Following the bottom: the viewport shows the latest lines, not line0.
      expect(controller.isViewportAtBottom, isTrue);
      final atBottom = controller.renderSnapshot!;
      final bottomText = atBottom.rowsData
          .map((r) => r.cells.map((c) => c.text).join().trimRight())
          .where((t) => t.isNotEmpty)
          .toList();
      expect(bottomText.any((t) => t.startsWith('line2')), isTrue);
      expect(bottomText.contains('line0'), isFalse);

      // Scroll to the very top — the engine must render scrollback row0.
      controller.scrollViewportToTop();
      expect(controller.isViewportAtBottom, isFalse);
      final atTop = controller.renderSnapshot!;
      expect(firstCellOfRow(atTop, 0), 'line0');

      // The engine scrollbar reports the viewport pinned at the top.
      final bar = controller.viewportScrollbar!;
      expect(bar.offset, 0);
      expect(bar.total, greaterThan(bar.length));

      // Scroll back to the bottom — follow state re-pins and the tail returns.
      controller.scrollViewportToBottom();
      expect(controller.isViewportAtBottom, isTrue);
      final backToBottom = controller.renderSnapshot!;
      final tailText = backToBottom.rowsData
          .map((r) => r.cells.map((c) => c.text).join().trimRight())
          .where((t) => t.isNotEmpty)
          .toList();
      expect(tailText.contains('line0'), isFalse);
      expect(tailText.any((t) => t.startsWith('line2')), isTrue);
    },
  );

  test(
    'scrolled-up viewport is held while new output is ingested',
    () {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller = GhosttyTerminalController(
        initialCols: 20,
        initialRows: 6,
      );
      addTearDown(controller.dispose);

      final buffer = StringBuffer();
      for (var i = 0; i < 30; i++) {
        buffer.write('line$i\r\n');
      }
      controller.appendDebugOutput(buffer.toString());

      controller.scrollViewportToTop();
      expect(controller.isViewportAtBottom, isFalse);
      final offsetBefore = controller.viewportScrollbar!.offset;

      // New output arrives while scrolled up: viewport must NOT snap to bottom.
      controller.appendDebugOutput('fresh-tail\r\n');
      expect(controller.isViewportAtBottom, isFalse);
      expect(
        controller.viewportScrollbar!.offset,
        offsetBefore,
        reason: 'scrolled-up viewport offset should be preserved on new output',
      );
    },
  );

  test('write/sendKey return false when process is not running', () {
    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);

    expect(controller.write('echo hello'), isFalse);
    expect(
      controller.sendKey(
        key: GhosttyKey.GHOSTTY_KEY_C,
        mods: GhosttyModsMask.ctrl,
      ),
      isFalse,
    );
    expect(
      controller.sendMouse(
        action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
        button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
        position: const VtMousePosition(x: 10, y: 10),
        size: const VtMouseEncoderSize(
          screenWidth: 800,
          screenHeight: 600,
          cellWidth: 10,
          cellHeight: 20,
        ),
      ),
      isFalse,
    );
  });

  test('controller stores explicit launch metadata from startLaunch', () async {
    final controller = _LaunchMetadataController();
    addTearDown(controller.dispose);

    await controller.startLaunch(
      const GhosttyTerminalShellLaunch(
        label: 'clean bash shell',
        shell: '/bin/bash',
        arguments: <String>['--noprofile', '--norc', '-i'],
        environment: <String, String>{
          'HOME': '/tmp/demo-home',
          'TERM': 'xterm-256color',
        },
      ),
    );

    expect(controller.activeShellLaunch?.label, 'clean bash shell');
    expect(
      controller.activeShellLaunch?.commandLine,
      '/bin/bash --noprofile --norc -i',
    );
    expect(
      controller.activeShellLaunch?.environment?['HOME'],
      '/tmp/demo-home',
    );
  });

  test('native controller uses the shared PTY backend on Unix', () async {
    if (!_hasNativeTerminal) {
      return;
    }

    if (!(Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    final controller = GhosttyTerminalController(defaultShell: '/bin/bash');
    addTearDown(controller.dispose);

    await controller.start(
      shell: '/bin/bash',
      arguments: const <String>['--noprofile', '--norc', '-i'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(controller.ptySession, isNotNull);
    expect(controller.isRunning, isTrue);

    await controller.stop();
  });

  test('render snapshot resolves hyperlink cells and explicit color flags', () {
    if (!_hasNativeTerminal) {
      return;
    }

    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);

    controller.appendDebugOutput(
      '\x1b]8;;https://example.com\x07open\x1b]8;;\x07\x1b[31mred\x1b[0m',
    );
    final renderSnapshot = controller.renderSnapshot;
    expect(renderSnapshot, isNotNull);

    final rows = renderSnapshot!.rowsData;
    expect(rows, isNotEmpty);
    final cells = rows.first.cells;
    expect(cells, isNotEmpty);

    final openCell = cells.firstWhere((cell) => cell.text == 'o');
    expect(openCell.hasHyperlink, isTrue);
    expect(openCell.style.hasExplicitForeground, isFalse);
    expect(openCell.style.hasExplicitBackground, isFalse);

    final redCell = cells.firstWhere(
      (cell) => cell.text == 'r' && !cell.hasHyperlink,
    );
    expect(redCell.style.hasExplicitForeground, isTrue);
  });

  test(
    'render snapshot distinguishes explicit and implicit underline colors',
    () {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller = GhosttyTerminalController();
      addTearDown(controller.dispose);

      controller.appendDebugOutput(
        '\x1b[58;2;255;0;0mexplicit\x1b[0mintrinsic',
      );

      final renderSnapshot = controller.renderSnapshot;
      expect(renderSnapshot, isNotNull);
      final row = renderSnapshot!.rowsData.first;
      final textCells = row.cells
          .where((cell) => cell.text.isNotEmpty)
          .toList(growable: false);
      final explicitCell = textCells.firstWhere((cell) => cell.text == 'e');
      final implicitCell = textCells[8];

      expect(explicitCell.style.hasExplicitUnderlineColor, isTrue);
      expect(implicitCell.style.hasExplicitUnderlineColor, isFalse);
      expect(
        explicitCell.style.underlineColor,
        isNot(equals(implicitCell.style.underlineColor)),
      );
      expect(
        implicitCell.style.underlineColor,
        equals(const Color(0x00000000)),
      );
    },
  );

  test('render snapshot preserves unresolved background as transparent', () {
    if (!_hasNativeTerminal) {
      return;
    }

    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);

    controller.appendDebugOutput('hello');
    final renderSnapshot = controller.renderSnapshot;
    expect(renderSnapshot, isNotNull);

    final cells = renderSnapshot!.rowsData.first.cells;
    final firstTextCell = cells.firstWhere((cell) => cell.text.isNotEmpty);
    expect(firstTextCell.style.hasExplicitBackground, isFalse);
    expect(firstTextCell.style.background, equals(const Color(0x00000000)));
  });

  test(
    'render snapshot preserves wide-cell widths for native viewport data',
    () {
      if (!_hasNativeTerminal) {
        return;
      }

      final controller = GhosttyTerminalController();
      addTearDown(controller.dispose);

      controller.appendDebugOutput('A🙂B');
      final renderSnapshot = controller.renderSnapshot;
      expect(renderSnapshot, isNotNull);

      final textCells = renderSnapshot!.rowsData.first.cells
          .where((cell) => cell.text.isNotEmpty)
          .toList(growable: false);
      expect(textCells.map((cell) => cell.text).toList(), ['A', '🙂', 'B']);
      expect(textCells.map((cell) => cell.width).toList(), [1, 2, 1]);
    },
  );

  test('applyEngineColors configures the engine default palette and fg/bg', () {
    if (!_hasNativeTerminal) {
      return;
    }

    final controller = GhosttyTerminalController(
      initialCols: 20,
      initialRows: 5,
    );
    addTearDown(controller.dispose);

    controller.applyEngineColors(
      ansiPalette: List<Color>.filled(16, const Color(0xFF112233)),
      foreground: const Color(0xFFCCCCCC),
      background: const Color(0xFF09090B),
      cursor: const Color(0xFFFFFFFF),
    );

    final colors = controller.terminal.defaultColors;
    expect(colors.palette.length, 256);
    expect(
      (colors.foreground!.r, colors.foreground!.g, colors.foreground!.b),
      (0xCC, 0xCC, 0xCC),
    );
    expect(
      (colors.background!.r, colors.background!.g, colors.background!.b),
      (0x09, 0x09, 0x0B),
    );
    expect(
      (colors.cursor!.r, colors.cursor!.g, colors.cursor!.b),
      (0xFF, 0xFF, 0xFF),
    );
  });

  test('engine colors are re-applied after clear() resets the terminal', () {
    if (!_hasNativeTerminal) {
      return;
    }

    final controller = GhosttyTerminalController(
      initialCols: 20,
      initialRows: 5,
    );
    addTearDown(controller.dispose);

    controller.applyEngineColors(
      ansiPalette: List<Color>.filled(16, const Color(0xFF112233)),
      foreground: const Color(0xFFCCCCCC),
      background: const Color(0xFF09090B),
    );
    controller.clear();

    final colors = controller.terminal.defaultColors;
    expect(
      (colors.foreground!.r, colors.foreground!.g, colors.foreground!.b),
      (0xCC, 0xCC, 0xCC),
    );
  });

  test('scrollViewportToOffsetFromBottom positions and clamps the viewport', () {
    if (!_hasNativeTerminal) {
      return;
    }
    final controller = GhosttyTerminalController(initialCols: 20, initialRows: 6);
    addTearDown(controller.dispose);

    final buffer = StringBuffer();
    for (var i = 0; i < 30; i++) {
      buffer.write('line$i\r\n');
    }
    controller.appendDebugOutput(buffer.toString());

    controller.scrollViewportToOffsetFromBottom(0);
    expect(controller.isViewportAtBottom, isTrue);

    controller.scrollViewportToOffsetFromBottom(5);
    final bar = controller.viewportScrollbar!;
    expect(bar.total - bar.length - bar.offset, 5);
    expect(controller.isViewportAtBottom, isFalse);

    controller.scrollViewportToOffsetFromBottom(100000);
    expect(controller.viewportScrollbar!.offset, 0);
  });

  test('cursor leaves the viewport when scrolled into history', () {
    if (!_hasNativeTerminal) {
      return;
    }
    final controller = GhosttyTerminalController(initialCols: 20, initialRows: 6);
    addTearDown(controller.dispose);

    final buffer = StringBuffer();
    for (var i = 0; i < 40; i++) {
      buffer.write('row$i\r\n');
    }
    controller.appendDebugOutput(buffer.toString());

    // At the bottom the cursor reports a viewport position.
    controller.scrollViewportToOffsetFromBottom(0);
    final bottomCursor = controller.renderSnapshot!.cursor;
    expect(bottomCursor.hasViewportPosition, isTrue);

    // Scrolled up into history, the live cursor (at the active bottom) is no
    // longer inside the viewport — so the renderState paint path must not draw
    // a phantom cursor in scrollback. Either the engine drops the viewport
    // position, or it reports a row outside the visible rows.
    controller.scrollViewportToOffsetFromBottom(30);
    final scrolled = controller.renderSnapshot!;
    final cursor = scrolled.cursor;
    final visibleRows = scrolled.rowsData.length;
    final inViewport = cursor.hasViewportPosition &&
        cursor.row != null &&
        cursor.row! >= 0 &&
        cursor.row! < visibleRows;
    expect(inViewport, isFalse);
  });

  test('engine renderSnapshot surfaces scrollback rows when scrolled up', () {
    if (!_hasNativeTerminal) {
      return;
    }
    final controller = GhosttyTerminalController(initialCols: 20, initialRows: 6);
    addTearDown(controller.dispose);
    final buffer = StringBuffer();
    for (var i = 0; i < 40; i++) {
      buffer.write('row$i\r\n');
    }
    controller.appendDebugOutput(buffer.toString());

    String topRowText() => controller.renderSnapshot!.rowsData.first.cells
        .map((c) => c.text)
        .join()
        .trimRight();

    // At the bottom: the top visible row is a late row, not row0.
    controller.scrollViewportToOffsetFromBottom(0);
    expect(controller.isViewportAtBottom, isTrue);
    final bottomTop = topRowText();
    expect(bottomTop, matches(RegExp(r'^row\d+$')));

    // Scrolled up: the top visible row is an earlier scrollback row.
    controller.scrollViewportToOffsetFromBottom(20);
    expect(controller.isViewportAtBottom, isFalse);
    final scrolledTop = topRowText();
    expect(scrolledTop, matches(RegExp(r'^row\d+$')));
    final bottomIdx = int.parse(bottomTop.substring(3));
    final scrolledIdx = int.parse(scrolledTop.substring(3));
    expect(scrolledIdx, lessThan(bottomIdx)); // scrolled up = earlier content

    // Returning to the bottom re-pins to the latest content.
    controller.scrollViewportToOffsetFromBottom(0);
    expect(controller.isViewportAtBottom, isTrue);
    expect(topRowText(), bottomTop);
  });

  test('follow state tracks scroll target before the terminal exists', () {
    if (!_hasNativeTerminal) {
      return;
    }
    // Freshly-constructed controller with no writes yet: the native terminal
    // has not been created, so these scroll calls hit the null-terminal branch.
    final controller = GhosttyTerminalController(initialCols: 20, initialRows: 6);
    addTearDown(controller.dispose);

    // Driving an offset away from the bottom must clear follow so the first
    // output after terminal creation honors the requested scroll position.
    controller.scrollViewportToOffsetFromBottom(20);
    expect(controller.isViewportAtBottom, isFalse);

    // Returning to the bottom (offset 0) re-pins follow.
    controller.scrollViewportToOffsetFromBottom(0);
    expect(controller.isViewportAtBottom, isTrue);
  });

  test(
    'renderState snapshot carries foreground, background, and underline attributes',
    () {
      if (!_hasNativeTerminal) {
        return;
      }
      final controller = GhosttyTerminalController(
        initialCols: 40,
        initialRows: 6,
      );
      addTearDown(controller.dispose);

      // Row 0: red foreground. Row 1: blue background. Row 2: underlined.
      controller.appendDebugOutput(
        '\x1b[31mRED\x1b[0m\r\n'
        '\x1b[44mBG\x1b[0m\r\n'
        '\x1b[4mUL\x1b[0m\r\n',
      );

      final snapshot = controller.renderSnapshot;
      expect(snapshot, isNotNull);
      final rows = snapshot!.rowsData;
      expect(rows.length, greaterThanOrEqualTo(3));

      // Foreground: SGR 31 maps to palette index 1 (red).
      final redCell = rows[0].cells.first;
      expect(redCell.text, 'R');
      expect(redCell.style.hasExplicitForeground, isTrue);
      expect(redCell.style.foregroundToken?.paletteIndex, 1);

      // Background: SGR 44 maps to palette index 4 (blue).
      final bgCell = rows[1].cells.first;
      expect(bgCell.text, 'B');
      expect(bgCell.style.hasExplicitBackground, isTrue);
      expect(bgCell.style.backgroundToken?.paletteIndex, 4);

      // Underline: SGR 4 sets single underline.
      final ulCell = rows[2].cells.first;
      expect(ulCell.text, 'U');
      expect(
        ulCell.style.underline,
        isNot(GhosttySgrUnderline.GHOSTTY_SGR_UNDERLINE_NONE),
      );
    },
  );

  test('selection text and hyperlinks resolve through the snapshot (Phase 2d guard)', () {
    if (!_hasNativeTerminal) {
      return;
    }
    final controller = GhosttyTerminalController(initialCols: 40, initialRows: 6);
    addTearDown(controller.dispose);
    controller.appendDebugOutput(
      '\x1b[31mhello\x1b[0m world\r\n'
      'visit https://example.com now\r\n',
    );

    // Colored text still copies as plain text (color runs become unread once
    // the formatter color paint branch is deleted; the snapshot keeps the text).
    final sel = controller.snapshot.lineSelectionBetweenRows(0, 0);
    expect(sel, isNotNull);
    expect(controller.snapshot.textForSelection(sel!).trimRight(), 'hello world');

    // Word selection still works.
    final word = controller.snapshot.wordSelectionAt(
      const GhosttyTerminalCellPosition(row: 0, col: 2),
    );
    expect(word, isNotNull);

    // Hyperlink resolution through the snapshot still works (the URL-detection
    // path used by the off-screen `_resolveHyperlinkUriAt` fallback).
    expect(
      controller.snapshot.hyperlinkAt(
        const GhosttyTerminalCellPosition(row: 1, col: 10),
      ),
      'https://example.com',
    );
  });

  testWidgets('terminal view renders custom painter', (tester) async {
    if (!_hasNativeTerminal) {
      return;
    }

    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);
    controller.appendDebugOutput('line one\nline two');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 500,
          height: 220,
          child: GhosttyTerminalView(controller: controller),
        ),
      ),
    );

    expect(find.byType(GhosttyTerminalView), findsOneWidget);
    expect(find.byKey(const ValueKey('terminalPainter')), findsOneWidget);
  });

  group('setFocused (DEC 1004 focus reporting)', () {
    test('latches desired blur and emits CSI O once mode 1004 is enabled', () {
      final controller = GhosttyTerminalController();
      final sent = <int>[];
      controller.attachExternalTransport(
        writeBytes: (b) {
          sent.addAll(b);
          return true;
        },
      );

      controller.setFocused(false); // mode off → nothing emitted yet
      expect(sent, isEmpty);

      controller.appendOutputBytes('\x1b[?1004h'.codeUnits); // enable → flush
      expect(String.fromCharCodes(sent), '\x1b[O');

      sent.clear();
      controller.appendOutputBytes('x'.codeUnits); // no state change → no resend
      expect(sent, isEmpty);
    });

    test('emits CSI I when focused after mode enabled', () {
      final controller = GhosttyTerminalController();
      final sent = <int>[];
      controller.attachExternalTransport(
        writeBytes: (b) {
          sent.addAll(b);
          return true;
        },
      );

      controller.appendOutputBytes('\x1b[?1004h'.codeUnits);
      controller.setFocused(true);
      expect(String.fromCharCodes(sent), '\x1b[I');
    });

    test('re-asserts desired state after mode 1004 toggles off then on', () {
      final controller = GhosttyTerminalController();
      final sent = <int>[];
      controller.attachExternalTransport(
        writeBytes: (b) {
          sent.addAll(b);
          return true;
        },
      );

      controller.setFocused(false);
      controller.appendOutputBytes('\x1b[?1004h'.codeUnits); // → CSI O
      sent.clear();
      controller.appendOutputBytes('\x1b[?1004l'.codeUnits); // disable
      controller.appendOutputBytes('\x1b[?1004h'.codeUnits); // re-enable → resend
      expect(String.fromCharCodes(sent), '\x1b[O');
    });

    test('emits nothing while mode 1004 is never enabled', () {
      final controller = GhosttyTerminalController();
      final sent = <int>[];
      controller.attachExternalTransport(
        writeBytes: (b) {
          sent.addAll(b);
          return true;
        },
      );

      controller.setFocused(true);
      controller.appendOutputBytes('hello world'.codeUnits);
      expect(sent, isEmpty);
    });

    test('does not latch when writeBytes fails, retries on next flush', () {
      final controller = GhosttyTerminalController();
      var accept = false;
      final sent = <int>[];
      controller.attachExternalTransport(
        writeBytes: (b) {
          if (!accept) return false;
          sent.addAll(b);
          return true;
        },
      );

      controller.appendOutputBytes('\x1b[?1004h'.codeUnits);
      controller.setFocused(true); // write rejected → not latched
      expect(sent, isEmpty);

      accept = true;
      controller.appendOutputBytes(''.codeUnits); // flush retries → CSI I
      expect(String.fromCharCodes(sent), '\x1b[I');
    });
  });
}

class _LaunchMetadataController extends GhosttyTerminalController {
  _LaunchMetadataController() : super();

  @override
  Future<void> start({
    String? shell,
    List<String> arguments = const <String>[],
    Map<String, String>? environment,
  }) async {}
}
