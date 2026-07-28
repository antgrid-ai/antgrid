import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSLColor;

/// WCAG 2.x contrast ratio between two colors, in `[1, 21]`.
///
/// Uses [Color.computeLuminance], which implements the WCAG relative-luminance
/// formula (sRGB linearization). Alpha is ignored — callers are expected to
/// pass the effective (composited) colors.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Returns [fg] unchanged (the identical object) when it already meets
/// [ratio] against [bg]; otherwise returns the closest color that does.
///
/// Hue and saturation are held fixed (HSL); only lightness moves, toward
/// whichever pole (white or black) contrasts more with [bg]. Picking by
/// achievable contrast rather than a fixed background-luminance threshold
/// matters for mid-luminance backgrounds: on an ANSI-yellow cell background
/// (luminance ~0.35) the white pole tops out near 2.6:1 while black reaches
/// 8:1, so a "dark background → lighten" rule would leave the text failing.
/// A binary search (≤10 iterations) finds the smallest lightness change that
/// meets [ratio]; if the ratio is unreachable even at the better pole (e.g.
/// 21 against a mid-gray), that pole is returned.
Color ensureMinimumContrast(Color fg, Color bg, double ratio) {
  if (contrastRatio(fg, bg) >= ratio) {
    return fg;
  }

  final hsl = HSLColor.fromColor(fg);
  final whitePole = hsl.withLightness(1.0).toColor();
  final blackPole = hsl.withLightness(0.0).toColor();
  // The higher-contrast pole reaches [ratio] whenever either pole can, so
  // this single comparison never picks a direction that dead-ends short of a
  // reachable target.
  final towardWhite =
      contrastRatio(whitePole, bg) >= contrastRatio(blackPole, bg);
  final extreme = towardWhite ? 1.0 : 0.0;
  final extremeColor = towardWhite ? whitePole : blackPole;
  if (contrastRatio(extremeColor, bg) < ratio) {
    // The target is unreachable even at the pole — return the pole rather
    // than searching an interval that contains no passing point.
    return extremeColor;
  }

  // Contrast is monotonic in lightness toward the pole, so 10 halvings pin
  // the pass/fail boundary to <0.001 lightness — finer than 8-bit color can
  // represent. `best` always holds a verified-passing candidate.
  var failing = hsl.lightness;
  var passing = extreme;
  var best = extremeColor;
  for (var i = 0; i < 10; i++) {
    final mid = (failing + passing) / 2;
    final candidate = hsl.withLightness(mid).toColor();
    if (contrastRatio(candidate, bg) >= ratio) {
      passing = mid;
      best = candidate;
    } else {
      failing = mid;
    }
  }
  return best;
}
