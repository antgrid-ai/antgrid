import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'support/native_terminal.dart';

final bool _hasNativeTerminal = hasNativeTerminal;

// ---------------------------------------------------------------------------
// Helper: find the foreground color of the first cell whose text equals [ch].
// ---------------------------------------------------------------------------

Color? _fgOfChar(GhosttyTerminalRenderSnapshot snap, String ch) {
  for (final row in snap.rowsData) {
    for (final cell in row.cells) {
      if (cell.text == ch) return cell.style.foreground;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test(
    'XTPUSHSGR/XTPOPSGR is NOT implemented — pop does not restore SGR (regression guard)',
    () {
      if (!_hasNativeTerminal) return;

      final c = GhosttyTerminalController(initialCols: 40, initialRows: 4);
      addTearDown(c.dispose);

      // Sequence: set red, write A, PUSH sgr (CSI # {), set green, write B,
      // POP sgr (CSI # }), write C.
      // If XTPUSHSGR/XTPOPSGR were implemented: C would restore red (== A).
      // As of the current ghostty VT engine they are NOT implemented:
      //   - the PUSH is silently ignored
      //   - the POP  is silently ignored
      // Therefore C keeps green (== B), not red.
      c.appendOutputBytes('\x1b[31mA\x1b[#{\x1b[32mB\x1b[#}C'.codeUnits);

      final snap = c.renderSnapshot;
      expect(snap, isNotNull);

      final fgA = _fgOfChar(snap!, 'A');
      final fgB = _fgOfChar(snap, 'B');
      final fgC = _fgOfChar(snap, 'C');

      expect(fgA, isNotNull, reason: 'cell A must be found in the snapshot');
      expect(fgB, isNotNull, reason: 'cell B must be found in the snapshot');
      expect(fgC, isNotNull, reason: 'cell C must be found in the snapshot');

      // Sanity: red A and green B must be visually distinct.
      expect(
        fgA,
        isNot(equals(fgB)),
        reason: 'A (red \x1b[31m) should differ from B (green \x1b[32m)',
      );

      // Core assertion: XTPOPSGR is unimplemented — the pop is ignored so C
      // keeps B's green rather than restoring A's red.
      // If this ever flips (fgC == fgA), the engine has gained push/pop
      // support and this guard should be updated to reflect that.
      expect(
        fgC,
        equals(fgB),
        reason:
            'XTPOPSGR unimplemented: C should keep B green (pop was ignored)',
      );
      expect(
        fgC,
        isNot(equals(fgA)),
        reason:
            'XTPOPSGR unimplemented: C should NOT restore A red (pop was ignored)',
      );
    },
  );
}
