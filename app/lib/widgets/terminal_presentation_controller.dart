import 'dart:convert';

import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import '../models/ab_message.dart';
import '../models/terminal_models.dart';

/// Owns a surface's cells independently of the service's live terminal.
class TerminalPresentationController {
  TerminalPresentationController(
    this.tab, {
    this.onInput,
    this.onGuestPointer,
    this.transformInput,
  }) : engine = GhosttyTerminalController(
         initialCols: tab.cols,
         initialRows: tab.rows,
         maxScrollbackLines: 0,
         mouseMotionReportInterval: const Duration(milliseconds: 50),
       ) {
    engine.attachExternalTransport(
      writeBytes: (bytes) {
        final input = utf8.decode(bytes, allowMalformed: true);
        final text = transformInput?.call(input) ?? input;
        if (text.isEmpty) return true;
        final sgr = RegExp(r'^\x1b\[<(\d+);').firstMatch(text);
        final button = sgr != null
            ? int.tryParse(sgr[1]!)
            : text.startsWith('\x1b[M') && text.length >= 6
            ? text.codeUnitAt(3) - 32
            : null;
        if (button != null &&
            button < 32 &&
            (button & 3) != 3 &&
            (sgr == null || text.endsWith('M'))) {
          onGuestPointer?.call();
        }
        if (text != '\x1b[I' &&
            text != '\x1b[O' &&
            !text.startsWith('\x1b[<') &&
            !text.startsWith('\x1b[M')) {
          onInput?.call();
        }
        tab.ghostty.writeBytes(utf8.encode(text));
        return true;
      },
      forwardGuestQueryReplies: false,
    );
    tab.latestFrame.addListener(_accept);
    _accept();
  }

  final TerminalTab tab;
  final void Function()? onInput;
  final String Function(String)? transformInput;
  final void Function()? onGuestPointer;
  final GhosttyTerminalController engine;
  TerminalFrameMessage? _latest;
  bool selecting = false;
  int generation = 0;
  int get cols => selecting ? engine.cols : (_latest?.cols ?? tab.cols);
  int get rows => selecting ? engine.rows : (_latest?.rows ?? tab.rows);

  void _accept() {
    final frame = tab.latestFrame.value;
    if (frame?.runId != _latest?.runId) {
      selecting = false;
      generation++;
    }
    _latest = frame;
    if (!selecting) _paint();
  }

  void _paint() {
    final frame = _latest;
    if (frame == null) return;
    engine.resize(cols: frame.cols, rows: frame.rows);
    engine.appendOutputBytes(utf8.encode(frame.ansi));
  }

  void freeze() {
    if (selecting) return;
    selecting = true;
    generation++;
    engine.cancelPendingMouseMotion();
  }

  void returnToLive() {
    selecting = false;
    generation++;
    _paint();
  }

  void dispose() {
    tab.latestFrame.removeListener(_accept);
    engine.dispose();
  }
}
