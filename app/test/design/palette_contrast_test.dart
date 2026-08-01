import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/theme_presets.dart';

/// WCAG 2.x relative luminance (sRGB channels linearized per the spec).
/// Implemented independently of [Color.computeLuminance] so the assertion
/// doesn't inherit a framework regression.
double _relativeLuminance(Color c) {
  double linearize(double ch) =>
      ch <= 0.03928 ? ch / 12.92 : math.pow((ch + 0.055) / 1.055, 2.4) as double;
  return 0.2126 * linearize(c.r) +
      0.7152 * linearize(c.g) +
      0.0722 * linearize(c.b);
}

double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a) + 0.05;
  final lb = _relativeLuminance(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void _expectAA(Color fg, Color bg, String label) {
  final ratio = _contrast(fg, bg);
  expect(
    ratio,
    greaterThanOrEqualTo(4.5),
    reason:
        '$label: ${_hex(fg)} on ${_hex(bg)} is ${ratio.toStringAsFixed(2)}:1, '
        'below WCAG AA 4.5:1',
  );
}

void main() {
  group('preset palettes meet WCAG AA for readable text', () {
    for (final entry in kPresets.entries) {
      final preset = entry.key;
      final p = entry.value;
      // textDisabled is intentionally excluded everywhere: disabled controls
      // are exempt from WCAG contrast requirements (SC 1.4.3).
      final textTokens = <String, Color>{
        'textPrimary': p.textPrimary,
        'textSecondary': p.textSecondary,
        'textMuted': p.textMuted,
      };
      final surfaces = <String, Color>{
        'bgDeepest': p.bgDeepest,
        'bgSurface': p.bgSurface,
      };
      test('$preset text tokens >= 4.5:1 on core surfaces', () {
        for (final t in textTokens.entries) {
          for (final s in surfaces.entries) {
            _expectAA(t.value, s.value, '$preset ${t.key} on ${s.key}');
          }
        }
      });
    }

    // AA is a floor; these presets also have a ceiling. Past roughly 15:1 on a
    // dark background, high-luminance glyphs bloom into the surround and long
    // reading sessions fatigue — a near-white-on-near-black ramp passes every
    // check above and is still uncomfortable to read. Onyx is deliberately
    // exempt: it is the maximum-contrast escape hatch. Light is exempt because
    // the halation effect is specific to light-on-dark.
    for (final preset in [AbThemePreset.antgrid, AbThemePreset.zinc]) {
      test('$preset body text stays under the halation ceiling', () {
        final p = kPresets[preset]!;
        for (final s in [
          ('bgDeepest', p.bgDeepest),
          ('bgSurface', p.bgSurface),
        ]) {
          final ratio = _contrast(p.textPrimary, s.$2);
          expect(
            ratio,
            lessThanOrEqualTo(15.0),
            reason:
                '$preset textPrimary on ${s.$1}: ${_hex(p.textPrimary)} on '
                '${_hex(s.$2)} is ${ratio.toStringAsFixed(2)}:1, above the '
                '15:1 comfort ceiling',
          );
        }
      });
    }

    test('light preset semantic colors >= 4.5:1 on its surface', () {
      final p = kPresets[AbThemePreset.light]!;
      for (final (name, color) in [
        ('warning', p.warning),
        ('success', p.success),
        ('error', p.error),
        ('accent', p.accent),
      ]) {
        _expectAA(color, p.bgSurface, 'light $name on bgSurface');
      }
    });
  });

  group('derivePalette keeps muted text readable', () {
    void check(Color bg, String label) {
      final derived = derivePalette(
        bg: bg,
        primary: const Color(0xFFC084FC),
        accent: const Color(0xFF818CF8),
      );
      for (final (name, color) in [
        ('textPrimary', derived.textPrimary),
        ('textSecondary', derived.textSecondary),
        ('textMuted', derived.textMuted),
      ]) {
        _expectAA(color, derived.bgSurface, '$label $name on derived surface');
      }
    }

    test('dark custom background', () => check(const Color(0xFF141414), 'dark'));
    test('light custom background', () => check(const Color(0xFFFFFFFF), 'light'));
  });
}
