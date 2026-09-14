import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import '../models/ab_message.dart';

/// Copies cells rather than replaying screen-control sequences into history.
List<TerminalHistoryRow> captureTerminalHistoryScreen(
  GhosttyTerminalController controller,
  int boundary,
) {
  final terminal = controller.terminal;
  if (terminal.isAlternateScreen) return const [];
  return List.unmodifiable(
    List.generate(controller.rows, (y) {
      final spans = <TerminalHistorySpan>[];
      var wrapped = false;
      for (var x = 0; x < controller.cols; x++) {
        final cell = terminal.gridRef(VtPoint.active(x, y));
        wrapped = cell.row.wrapContinuation;
        if (cell.cell.isWideTail) continue;
        // Ghostty's SPACER_HEAD (3) fills the last column when a wide glyph
        // wraps. It is layout padding, not a space in the logical line.
        if (cell.cell.wide.value == 3) continue;
        final s = cell.style;
        final codes = <String>[
          '0',
          if (s.bold) '1',
          if (s.faint) '2',
          if (s.italic) '3',
          if (s.blink) '5',
          if (s.inverse) '7',
          if (s.invisible) '8',
          if (s.strikethrough) '9',
          if (s.overline) '53',
          if (s.underline.value != 0) '4:${s.underline.value}',
        ];
        void color(int code, VtStyleColor value) {
          final rgb = value.rgb;
          if (rgb != null) {
            codes.add('$code;2;${rgb.r};${rgb.g};${rgb.b}');
          } else if (value.paletteIndex != null) {
            codes.add('$code;5;${value.paletteIndex}');
          }
        }

        color(38, s.foreground);
        color(48, s.background);
        color(58, s.underlineColor);
        if (cell.cell.colorRgb case final rgb?) {
          codes.add('48;2;${rgb.r};${rgb.g};${rgb.b}');
        } else if (cell.cell.colorPaletteIndex case final index?) {
          codes.add('48;5;$index');
        }
        spans.add(
          TerminalHistorySpan(
            text: cell.graphemes.isEmpty ? ' ' : cell.graphemes,
            cells: cell.cell.isWideLead ? 2 : 1,
            sgr: '\x1b[${codes.join(';')}m',
            uri: cell.hyperlinkUri,
          ),
        );
      }
      return TerminalHistoryRow(
        rowId: boundary + y,
        cols: controller.cols,
        wrapped: wrapped,
        spans: List.unmodifiable(spans),
      );
    }, growable: false),
  );
}
