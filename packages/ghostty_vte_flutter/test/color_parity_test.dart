// Cross-emulator color-parity harness (Task 6b).
//
// Proves OUR Flutter terminal resolves per-cell colors identically to the
// ghostty-web reference engine on the shared corpus
// (tool/color_parity/color_torture.bin), both driven with the Windows-Terminal
// "Campbell" palette.
//
// The expected fixture (tool/color_parity/expected_cells.json) is produced by
// tool/color_parity/dump_ghostty_web.ts running ghostty-web@0.4.0 headless. See
// that script's header for how to regenerate it. The fixture is committed so
// this test runs without the (gitignored) reference engine present.
//
// Cross-engine modeling notes (NOT bugs — deliberate layering differences that
// are excluded from strict RGB parity, each narrowly and explicitly):
//
//  1. INVERSE / FAINT: ghostty-web's getLine() reports the *logical* style
//     colors and signals these via cell.flags only — it defers the fg/bg swap
//     and the dim blend to its renderer. OUR GhosttyTerminalResolvedStyle bakes
//     those effects into the resolved RGB (inverse swaps fg<->bg; faint blends
//     fg toward black, matching Windows Terminal). For inverse/faint cells we
//     assert the *attribute* matches (proving identical SGR parsing) rather than
//     the post-processed RGB, which legitimately differs by layer.
//
//  2. DEFAULT BACKGROUND: ghostty-web bakes the configured bgColor (#09090B)
//     into every default-bg cell's bg_r/g/b. OUR engine leaves default-bg cells
//     transparent (hasExplicitBackground == false) and paints the terminal
//     background once behind the whole grid, so the *rendered* pixel is
//     identical while the per-cell RGB is (0,0,0)/transparent. We therefore
//     compare BG only for cells with an explicit background (the BG4x lines).
//     Explicit backgrounds must — and do — match exactly.
//
// With those two carve-outs, all deterministic lines (16-color, bright,
// explicit backgrounds, 256, truecolor) match foreground (and explicit
// background) RGB exactly.
//
// XTPUSHSGR/XTPOPSGR (CSI # { / CSI # }): NOT implemented by either engine
// (the shared ghostty VT engine logs them as "unimplemented CSI action").
// The probe line agrees across both engines only because each ignores the
// push/pop and leaves the last-set SGR active — it validates the resulting
// color value, NOT correct push/pop semantics. See xtpushsgr_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'support/native_terminal.dart';

final bool _hasNativeTerminal = hasNativeTerminal;

// ghostty-web CellFlags bits (lib types): BOLD=1 ... INVERSE=16 ... FAINT=128.
const int _kFlagInverse = 16;
const int _kFlagFaint = 128;

// The complex-scripts corpus row (Devanagari / Arabic / emoji ZWJ). Grapheme and
// wide-cell coordinate models legitimately diverge between the two emulators;
// this is the single pre-approved exclusion from strict parity. See plan 6b.
const int _kGraphemeRow = 37;

/// Walks [row] accumulating each cell's display width to find the cell covering
/// terminal column [x]. Wide-spacer tails are already filtered from cells.
GhosttyTerminalRenderCell? _cellAtColumn(GhosttyTerminalRenderRow row, int x) {
  var col = 0;
  for (final cell in row.cells) {
    final width = cell.width <= 0 ? 1 : cell.width;
    if (x >= col && x < col + width) return cell;
    col += width;
  }
  return null;
}

(int, int, int) _rgbOf(Color c) =>
    ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());

int? _firstCodePoint(String s) => s.isEmpty ? null : s.runes.first;

void main() {
  test('per-cell colors match the ghostty-web reference engine', () {
    if (!_hasNativeTerminal) {
      return; // native VT unavailable on this platform — no-op.
    }

    // Test cwd is the package root; the corpus + fixture live at repo-root/tool.
    final corpus = File(
      '../../tool/color_parity/color_torture.bin',
    ).readAsBytesSync();
    final expected =
        jsonDecode(
              File(
                '../../tool/color_parity/expected_cells.json',
              ).readAsStringSync(),
            )
            as List<dynamic>;

    final controller = GhosttyTerminalController(
      initialCols: 120,
      initialRows: 40,
    );
    addTearDown(controller.dispose);

    controller.applyEngineColors(
      ansiPalette: campbellAnsi,
      foreground: campbellForeground,
      background: const Color(0xFF09090B),
      cursor: campbellForeground,
    );
    controller.appendOutputBytes(corpus);

    final snap = controller.renderSnapshot!;

    final mismatches = <String>[];
    final graphemeNotes = <String>[];
    var comparedRgb = 0;
    var comparedAttr = 0;

    for (final entry in expected.cast<Map<String, dynamic>>()) {
      final y = entry['y'] as int;
      final x = entry['x'] as int;
      final ch = entry['ch'] as String;
      final flags = entry['flags'] as int;
      final fg = (entry['fg'] as List).cast<int>();
      final bg = (entry['bg'] as List).cast<int>();

      if (y < 0 || y >= snap.rowsData.length) continue;
      final cell = _cellAtColumn(snap.rowsData[y], x);
      if (cell == null) continue;

      // Char-codepoint gate: only compare when the glyphs line up. This auto-
      // skips wide/grapheme coordinate drift between the two coordinate models.
      final expectedCp = _firstCodePoint(ch);
      final ourCp = _firstCodePoint(cell.text);
      if (expectedCp == null || ourCp == null || expectedCp != ourCp) {
        continue;
      }

      // Inverse / faint: engines apply these at different layers. Assert the
      // attribute is parsed identically instead of comparing post-processed RGB.
      final wantInverse = (flags & _kFlagInverse) != 0;
      final wantFaint = (flags & _kFlagFaint) != 0;
      if (wantInverse || wantFaint) {
        comparedAttr++;
        if (wantInverse && !cell.style.inverse) {
          mismatches.add(
            'y=$y x=$x "$ch": expected INVERSE attribute, ours inverse=${cell.style.inverse}',
          );
        }
        if (wantFaint && !cell.style.faint) {
          mismatches.add(
            'y=$y x=$x "$ch": expected FAINT attribute, ours faint=${cell.style.faint}',
          );
        }
        continue;
      }

      final ourFg = _rgbOf(cell.style.foreground);
      final wantFg = (fg[0], fg[1], fg[2]);

      final msg = StringBuffer();
      if (ourFg != wantFg) {
        msg.write('FG ours=$ourFg expected=$wantFg ');
      }
      // BG only for explicit backgrounds — see note (2): default-bg cells are
      // transparent in our model and painted behind the grid.
      if (cell.style.hasExplicitBackground) {
        final ourBg = _rgbOf(cell.style.background);
        final wantBg = (bg[0], bg[1], bg[2]);
        if (ourBg != wantBg) {
          msg.write('BG ours=$ourBg expected=$wantBg ');
        }
      }
      if (msg.isNotEmpty) {
        final line = 'y=$y x=$x "$ch": $msg'.trimRight();
        if (y == _kGraphemeRow) {
          // grapheme width divergence — see plan. Logged, not asserted.
          graphemeNotes.add(line);
        } else {
          mismatches.add(line);
        }
      } else {
        comparedRgb++;
      }
    }

    // We must have actually exercised the deterministic lines.
    expect(
      comparedRgb,
      greaterThan(80),
      reason: 'too few RGB cells compared ($comparedRgb) — fixture/snapshot drift',
    );
    expect(
      comparedAttr,
      greaterThan(0),
      reason: 'inverse/faint attribute cells were never reached',
    );

    if (graphemeNotes.isNotEmpty) {
      // ignore: avoid_print
      print(
        'color_parity: ${graphemeNotes.length} known grapheme-width '
        'divergence(s) on row $_kGraphemeRow (excluded from strict parity):\n'
        '${graphemeNotes.join('\n')}',
      );
    }

    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });
}
