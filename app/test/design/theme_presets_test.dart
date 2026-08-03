import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/theme_presets.dart';

void main() {
  group('derivePalette', () {
    test('dark bg → light text shades', () {
      final p = derivePalette(
        bg: const Color(0xFF000000),
        primary: const Color(0xFFFF0000),
        accent: const Color(0xFF00FF00),
      );
      // Light text on dark bg.
      expect(p.textPrimary.computeLuminance(), greaterThan(0.5));
    });

    test('light bg → dark text shades', () {
      final p = derivePalette(
        bg: const Color(0xFFFAFAFA),
        primary: const Color(0xFF6366F1),
        accent: const Color(0xFF818CF8),
      );
      // Dark text on light bg.
      expect(p.textPrimary.computeLuminance(), lessThan(0.5));
    });

    test('dark bg surface/elevated get progressively lighter', () {
      final p = derivePalette(
        bg: const Color(0xFF09090B),
        primary: const Color(0xFFC084FC),
        accent: const Color(0xFF818CF8),
      );
      final bgL = HSLColor.fromColor(p.bgDeepest).lightness;
      final surfL = HSLColor.fromColor(p.bgSurface).lightness;
      final elevL = HSLColor.fromColor(p.bgElevated).lightness;
      expect(surfL, greaterThan(bgL));
      expect(elevL, greaterThan(surfL));
    });

    test('light bg surface/elevated get progressively darker', () {
      final p = derivePalette(
        bg: const Color(0xFFFAFAFA),
        primary: const Color(0xFF6366F1),
        accent: const Color(0xFF818CF8),
      );
      final bgL = HSLColor.fromColor(p.bgDeepest).lightness;
      final surfL = HSLColor.fromColor(p.bgSurface).lightness;
      final elevL = HSLColor.fromColor(p.bgElevated).lightness;
      // On light backgrounds the "deeper" surfaces go darker so the
      // layering metaphor still reads correctly.
      expect(surfL, lessThan(bgL));
      expect(elevL, lessThan(surfL));
    });

    test('accent is preserved verbatim; primary lands on signalMut', () {
      const accent = Color(0xFF22D3EE);
      const primary = Color(0xFFEC4899);
      final p = derivePalette(
        bg: const Color(0xFF000000),
        primary: primary,
        accent: accent,
      );
      expect(p.accent, equals(accent));
      expect(p.signalMut, equals(primary));
    });

    test('all presets are registered in kPresets', () {
      for (final preset in AbThemePreset.values) {
        if (preset == AbThemePreset.custom) continue;
        expect(kPresets[preset], isNotNull, reason: '$preset missing');
      }
    });
  });

  group('Zinc preset', () {
    test('is the default palette', () {
      expect(kDefaultPalette.bgDeepest, const Color(0xFF1B1B1B));
      expect(kDefaultPalette.accent, const Color(0xFFC6C6C6));
    });

    test('exposes new role tokens', () {
      expect(kDefaultPalette.bgRaised, const Color(0xFF2B2B2B));
      expect(kDefaultPalette.bgHover, const Color(0xFF313131));
      expect(kDefaultPalette.bgPressed, const Color(0xFF3A3A3A));
      expect(kDefaultPalette.accentForeground, const Color(0xFF09090B));
      expect(kDefaultPalette.statusIdle, const Color(0xFF61656D));
      expect(kDefaultPalette.statusThinking, const Color(0xFFE2C792));
      expect(kDefaultPalette.statusRunning, const Color(0xFF8FCFAE));
      expect(kDefaultPalette.statusAttention, const Color(0xFFE5A055));
    });

    test('every preset defines all new fields', () {
      for (final preset in kPresets.values) {
        expect(preset.bgRaised, isNotNull);
        expect(preset.bgHover, isNotNull);
        expect(preset.bgPressed, isNotNull);
        expect(preset.accentForeground, isNotNull);
        expect(preset.statusIdle, isNotNull);
        expect(preset.statusThinking, isNotNull);
        expect(preset.statusRunning, isNotNull);
        expect(preset.statusAttention, isNotNull);
      }
    });

    test('kPresets contains an antgrid entry', () {
      expect(kPresets.containsKey(AbThemePreset.antgrid), isTrue);
    });
  });
}
