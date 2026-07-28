import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  group('contrastRatio', () {
    test('black on white is 21:1, identical colors are 1:1', () {
      const black = Color(0xFF000000);
      const white = Color(0xFFFFFFFF);
      expect(contrastRatio(black, white), closeTo(21, 0.01));
      expect(contrastRatio(white, black), closeTo(21, 0.01));
      expect(contrastRatio(black, black), closeTo(1, 0.0001));
    });

    test('Campbell blue on the app terminal background is below AA', () {
      // The motivating case: campbellAnsi[4] (#0037DA) on bgDeepest-ish
      // #141414 measures ~2.2:1 — this pins the "problem exists" premise.
      expect(
        contrastRatio(campbellAnsi[4], const Color(0xFF141414)),
        lessThan(3),
      );
    });
  });

  group('ensureMinimumContrast', () {
    const darkBg = Color(0xFF141414);

    test('lifts Campbell blue to >= 4.5 on a dark bg, holding hue', () {
      final raw = campbellAnsi[4]; // #0037DA
      final floored = ensureMinimumContrast(raw, darkBg, 4.5);

      expect(floored, isNot(equals(raw)));
      expect(contrastRatio(floored, darkBg), greaterThanOrEqualTo(4.5));

      // Hue and saturation are held; only lightness moves (up, dark bg).
      final rawHsl = HSLColor.fromColor(raw);
      final flooredHsl = HSLColor.fromColor(floored);
      expect(flooredHsl.hue, closeTo(rawHsl.hue, 8));
      expect(flooredHsl.lightness, greaterThan(rawHsl.lightness));
    });

    test('returns the identical object when already compliant', () {
      const compliant = Color(0xFFCCCCCC); // Campbell foreground, ~12:1
      final result = ensureMinimumContrast(compliant, darkBg, 4.5);
      expect(identical(result, compliant), isTrue);
    });

    test('unreachable ratio 21 on mid-gray converges to an extreme', () {
      // No color reaches 21:1 against mid-gray; must return the pole (not
      // loop or overshoot past it) — and specifically the BETTER pole: black
      // reaches 5.3:1 against #808080 where white tops out at 4.0:1.
      const midGray = Color(0xFF808080);
      const fg = Color(0xFF808080);
      final result = ensureMinimumContrast(fg, midGray, 21);
      expect(result, const Color(0xFF000000));
    });

    test('darkens on a mid-luminance background where white cannot reach', () {
      // `\e[43;97m` — bright white on ANSI yellow. The background's luminance
      // (~0.35) is under 0.5, but lightening cannot clear AA there; only
      // darkening can. Guards against a fixed-threshold direction choice.
      final yellowBg = campbellAnsi[3]; // #C19C00
      final white = campbellAnsi[15];
      expect(contrastRatio(white, yellowBg), lessThan(4.5));

      final floored = ensureMinimumContrast(white, yellowBg, 4.5);
      expect(contrastRatio(floored, yellowBg), greaterThanOrEqualTo(4.5));
      expect(
        HSLColor.fromColor(floored).lightness,
        lessThan(HSLColor.fromColor(white).lightness),
      );
    });

    test('darkens instead of lightening on a light background', () {
      const lightBg = Color(0xFFF2F2F2);
      const brightYellow = Color(0xFFF9F1A5); // campbellAnsi[11], ~1.1:1
      final floored = ensureMinimumContrast(brightYellow, lightBg, 4.5);
      expect(contrastRatio(floored, lightBg), greaterThanOrEqualTo(4.5));
      expect(
        HSLColor.fromColor(floored).lightness,
        lessThan(HSLColor.fromColor(brightYellow).lightness),
      );
    });

    test('near-black on the dark bg is lifted to readability', () {
      final black = campbellAnsi[0]; // #0C0C0C, ~1.06:1 on #141414
      final floored = ensureMinimumContrast(black, darkBg, 4.5);
      expect(contrastRatio(floored, darkBg), greaterThanOrEqualTo(4.5));
    });
  });
}
