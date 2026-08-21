import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ansi_palette.dart';
import 'package:antgrid/design/theme_presets.dart';

/// WCAG 2.x relative luminance, implemented independently of
/// [Color.computeLuminance] so the assertion doesn't inherit a framework
/// regression — same reasoning as palette_contrast_test.dart.
double _relativeLuminance(Color c) {
  double linearize(double ch) => ch <= 0.03928
      ? ch / 12.92
      : math.pow((ch + 0.055) / 1.055, 2.4) as double;
  return 0.2126 * linearize(c.r) +
      0.7152 * linearize(c.g) +
      0.0722 * linearize(c.b);
}

double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a) + 0.05;
  final lb = _relativeLuminance(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

/// CIELAB (D65). Only used as the input to [_deltaE].
List<double> _lab(Color c) {
  double linearize(double ch) => ch <= 0.03928
      ? ch / 12.92
      : math.pow((ch + 0.055) / 1.055, 2.4) as double;
  final r = linearize(c.r), g = linearize(c.g), b = linearize(c.b);
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3) as double : 7.787 * t + 16 / 116;
  final fx = f(x), fy = f(y), fz = f(z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

/// CIE76 color difference. ~2.3 is the just-noticeable difference.
double _deltaE(Color a, Color b) {
  final la = _lab(a), lb = _lab(b);
  return math.sqrt(
    math.pow(la[0] - lb[0], 2) +
        math.pow(la[1] - lb[1], 2) +
        math.pow(la[2] - lb[2], 2),
  );
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

const _names = [
  'black',
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
];
String _name(int i) => '${i > 7 ? 'bright ' : ''}${_names[i % 8]}';

void main() {
  // Every preset except light. The terminal background is the preset's
  // bgDeepest (see terminal_view_wrapper.dart), so these are the backgrounds
  // kAnsiDark has to serve.
  final darkBackgrounds = {
    for (final e in kPresets.entries)
      if (e.key != AbThemePreset.light) e.key: e.value.bgDeepest,
  };

  group('kAnsiDark', () {
    // Index 0 is exempt: it is the canonical background color, and the
    // renderer's per-cell floor covers it when a TUI paints it as text.
    test('every color but ANSI 0 clears 4.5:1 on every dark preset', () {
      for (final entry in darkBackgrounds.entries) {
        for (var i = 1; i < kAnsiDark.length; i++) {
          final ratio = _contrast(kAnsiDark[i], entry.value);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${entry.key} ${_name(i)}: ${_hex(kAnsiDark[i])} on '
                '${_hex(entry.value)} is ${ratio.toStringAsFixed(2)}:1, below '
                'WCAG AA — the renderer floor would have to lift it, and '
                'lifting is what collapses normal/bright pairs',
          );
        }
      }
    });

    // Same halation ceiling the chrome palette is held to. Onyx is the
    // deliberate maximum-contrast escape hatch and is exempt there too.
    test('no color exceeds 15:1 on any dark preset but onyx', () {
      for (final entry in darkBackgrounds.entries) {
        if (entry.key == AbThemePreset.onyx) continue;
        for (var i = 0; i < kAnsiDark.length; i++) {
          final ratio = _contrast(kAnsiDark[i], entry.value);
          expect(
            ratio,
            lessThanOrEqualTo(15.0),
            reason:
                '${entry.key} ${_name(i)}: ${_hex(kAnsiDark[i])} on '
                '${_hex(entry.value)} is ${ratio.toStringAsFixed(2)}:1, above '
                'the 15:1 comfort ceiling',
          );
        }
      }
    });

    test('normal and bright stay distinguishable', () {
      for (var i = 0; i < 8; i++) {
        // White is squeezed: the ceiling caps bright-white, and white cannot
        // follow it down without diverging from the default foreground, which
        // Campbell defines as the same color. See ansi_palette.dart.
        final floor = i == 7 ? 8.0 : 12.0;
        final d = _deltaE(kAnsiDark[i], kAnsiDark[i + 8]);
        expect(
          d,
          greaterThanOrEqualTo(floor),
          reason:
              '${_names[i]} vs bright ${_names[i]}: ${_hex(kAnsiDark[i])} vs '
              '${_hex(kAnsiDark[i + 8])} is only ${d.toStringAsFixed(1)} dE '
              'apart (2.3 is the just-noticeable threshold)',
        );
      }
    });

    test('default foreground is ANSI 7', () {
      // Unstyled text and SGR 37 rendering at different brightnesses reads as
      // a bug; Campbell defines them as one color.
      expect(kAnsiForegroundDark, kAnsiDark[7]);
    });
  });

  group('kAnsiLight', () {
    final lightBg = kPresets[AbThemePreset.light]!.bgDeepest;

    // Roles invert on a light background: 7 and 15 are the background colors
    // there, exempt the way ANSI 0 is on dark.
    test('every color but ANSI 7 and 15 clears 4.5:1 on the light preset', () {
      for (var i = 0; i < kAnsiLight.length; i++) {
        if (i == 7 || i == 15) continue;
        final ratio = _contrast(kAnsiLight[i], lightBg);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '${_name(i)}: ${_hex(kAnsiLight[i])} on ${_hex(lightBg)} is '
              '${ratio.toStringAsFixed(2)}:1, below WCAG AA',
        );
      }
    });

    test('normal and bright stay distinguishable', () {
      for (var i = 0; i < 8; i++) {
        final d = _deltaE(kAnsiLight[i], kAnsiLight[i + 8]);
        expect(
          d,
          greaterThanOrEqualTo(12.0),
          reason:
              '${_names[i]} vs bright ${_names[i]}: ${_hex(kAnsiLight[i])} vs '
              '${_hex(kAnsiLight[i + 8])} is only ${d.toStringAsFixed(1)} dE '
              'apart',
        );
      }
    });

    test('default foreground is readable and is not ANSI 7', () {
      expect(_contrast(kAnsiForegroundLight, lightBg), greaterThanOrEqualTo(7));
    });
  });

  group('ansiPaletteFor', () {
    test('picks the palette matching each preset background', () {
      for (final entry in kPresets.entries) {
        final bg = entry.value.bgDeepest;
        final expected = entry.key == AbThemePreset.light
            ? kAnsiPaletteLight
            : kAnsiPaletteDark;
        expect(
          ansiPaletteFor(bg),
          same(expected),
          reason: '${entry.key} (${_hex(bg)}) resolved to the wrong palette',
        );
      }
    });

    test('foreground tracks the palette it is paired with', () {
      for (final entry in kPresets.entries) {
        final bg = entry.value.bgDeepest;
        final fg = ansiForegroundFor(bg);
        expect(
          identical(ansiPaletteFor(bg), kAnsiPaletteLight)
              ? fg == kAnsiForegroundLight
              : fg == kAnsiForegroundDark,
          isTrue,
          reason: '${entry.key} paired a foreground from the other palette',
        );
      }
    });
  });
}
