import 'dart:convert';

import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/widgets/terminal_presentation_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

TerminalFrameMessage _frame(
  int sequence,
  String text, {
  String run = 'run',
  int cols = 80,
}) => TerminalFrameMessage(
  id: '$sequence',
  timestamp: 0,
  terminalId: 'terminal',
  runId: run,
  attachmentId: 'attachment',
  sequence: sequence,
  version: 2,
  revision: sequence,
  cols: cols,
  rows: 24,
  ansi: '\x1b[2J\x1b[H$text',
  syncTimedOut: false,
  history: const TerminalHistoryBoundary(
    epoch: 1,
    firstRowId: 0,
    nextRowId: 0,
    status: 'recording',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool nativeAvailable() {
    try {
      GhosttyVt.newTerminal(cols: 8, rows: 2).close();
      return true;
    } catch (_) {
      markTestSkipped('native VT unavailable');
      return false;
    }
  }

  test(
    'surfaces freeze independently and return to the latest Unicode frame',
    () {
      if (!nativeAvailable()) return;
      final tab = TerminalTab(terminalId: 'terminal', name: 'terminal');
      tab.latestFrame.value = _frame(1, 'wide: 界 combining: e\u0301');
      final first = TerminalPresentationController(tab);
      final second = TerminalPresentationController(tab);
      addTearDown(() {
        first.dispose();
        second.dispose();
        tab.ghostty.dispose();
      });
      first.freeze();
      tab.latestFrame.value = _frame(2, 'latest: λ界 e\u0301', cols: 100);
      expect(first.engine.plainText, contains('wide: 界'));
      expect(first.cols, 80);
      expect(second.engine.plainText, contains('latest: λ界'));
      expect(second.cols, 100);
      first.returnToLive();
      expect(first.engine.plainText, second.engine.plainText);
      first.freeze();
      tab.latestFrame.value = _frame(3, 'new run', run: 'replacement');
      expect(first.selecting, isFalse);
      expect(first.engine.plainText, contains('new run'));
    },
  );

  test('record native frame ingestion cost with live and frozen surfaces', () {
    if (!nativeAvailable()) return;
    final frames = List.generate(
      100,
      (i) => _frame(i, List.filled(24, 'frame $i ${'x' * 60}').join('\r\n')),
    );
    final tab = TerminalTab(terminalId: 'terminal', name: 'terminal');
    int measure({TerminalPresentationController? surface}) {
      final timer = Stopwatch()..start();
      for (final frame in frames) {
        tab.ghostty.resize(cols: frame.cols, rows: frame.rows);
        tab.ghostty.appendOutputBytes(utf8.encode(frame.ansi));
        if (surface != null) tab.latestFrame.value = frame;
      }
      return timer.elapsedMicroseconds;
    }

    measure();
    final baseline = measure();
    final surface = TerminalPresentationController(tab);
    addTearDown(() {
      surface.dispose();
      tab.ghostty.dispose();
    });
    final live = measure(surface: surface);
    surface.freeze();
    final frozen = measure(surface: surface);
    debugPrint(
      '100 native frames (microseconds): authoritative=$baseline live-surface=$live frozen-surface=$frozen',
    );
    expect(surface.selecting, isTrue);
  });
}
