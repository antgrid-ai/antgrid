// Regression guard for the ghostty_vte FFI color bug: VtRgbColor.fromNative
// previously read colors through ghostty_color_rgb_get, which takes the
// GhosttyColorRgb struct BY VALUE — Dart FFI mismarshals that 3xuint8 struct on
// macOS/iOS arm64, so every terminal color resolved to black and colored text
// was invisible (only default-foreground text showed). The vendored ghostty_vte
// fork reads the struct fields directly. This test feeds 16-color, 256-color and
// truecolor SGR into the real native engine and asserts non-black RGB.
//
// Gated on native availability (like color_parity_test): a host without the
// prebuilt libghostty-vt no-ops rather than failing.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

(int, int, int) _rgb(Color c) =>
    ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());

void main() {
  test('native engine resolves explicit SGR colors (not all-black)', () {
    if (!_hasNative()) return; // native VT unavailable — no-op.

    final c = GhosttyTerminalController(initialCols: 40, initialRows: 4);
    addTearDown(c.dispose);
    c.applyEngineColors(
      ansiPalette: campbellAnsi,
      foreground: campbellForeground,
      background: const Color(0xFF09090B),
      cursor: campbellForeground,
    );
    // 16-color red, 256-color red (196), truecolor red.
    c.appendOutputBytes(
      '\x1b[31mB\x1b[38;5;196mC\x1b[38;2;255;0;0mD\x1b[0m'.codeUnits,
    );
    final row = c.renderSnapshot!.rowsData[0];

    final r16 = _rgb(row.cells[0].style.foreground);
    final r256 = _rgb(row.cells[1].style.foreground);
    final rTrue = _rgb(row.cells[2].style.foreground);

    // The exact mismarshal symptom: every channel zero.
    expect(r16, isNot((0, 0, 0)), reason: '16-color red resolved to black');
    expect(r256, isNot((0, 0, 0)), reason: '256-color red resolved to black');
    expect(rTrue, isNot((0, 0, 0)), reason: 'truecolor red resolved to black');

    // Truecolor is exact regardless of palette.
    expect(rTrue, (255, 0, 0));
  });
}
