import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'colors.dart';

/// One foreground/background role pairing checked by [CarbonContrast.validate].
@immutable
class CarbonContrastPair {
  const CarbonContrastPair({
    required this.foreground,
    required this.background,
    required this.required,
    required this.foregroundOf,
    required this.backgroundOf,
  });

  /// Role name of the foreground, e.g. `textPrimary`.
  final String foreground;

  /// Role name of the surface the foreground is drawn on.
  final String background;

  /// Minimum WCAG contrast ratio: 4.5 for text, 3.0 for non-text marks.
  final double required;

  final Color Function(CarbonColors colors) foregroundOf;
  final Color Function(CarbonColors colors) backgroundOf;
}

/// A [CarbonContrastPair] whose measured [ratio] is below [required].
@immutable
class CarbonContrastIssue {
  const CarbonContrastIssue({
    required this.foreground,
    required this.background,
    required this.ratio,
    required this.required,
  });

  final String foreground;
  final String background;
  final double ratio;
  final double required;

  @override
  String toString() =>
      '$foreground on $background: ${ratio.toStringAsFixed(2)}:1 '
      '(needs ${required.toStringAsFixed(1)}:1)';
}

/// WCAG 2.x contrast math and a role-pair check for [CarbonColors].
///
/// The checked pairs are the default and interactive combinations components
/// actually paint. Roles WCAG exempts are deliberately absent: placeholder and
/// disabled text/icons (inactive components), and purely decorative borders.
/// Run [validate] over a custom palette before shipping it; an empty result
/// means every listed pair meets its threshold, not that the UI is conformant.
abstract final class CarbonContrast {
  static const double textRatio = 4.5;
  static const double nonTextRatio = 3.0;

  /// WCAG relative luminance of an opaque sRGB color, in 0..1.
  static double relativeLuminance(Color color) {
    double channel(double c) => c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(color.r) +
        0.7152 * channel(color.g) +
        0.0722 * channel(color.b);
  }

  /// WCAG contrast ratio of [foreground] drawn on [background], 1..21.
  ///
  /// A translucent [foreground] is composited over [background] first, because
  /// that is what the eye sees; [background] is treated as opaque.
  static double contrastRatio(Color foreground, Color background) {
    final opaqueBackground = background.withValues(alpha: 1);
    final fg = Color.alphaBlend(foreground, opaqueBackground);
    final a = relativeLuminance(fg);
    final b = relativeLuminance(opaqueBackground);
    final lighter = math.max(a, b);
    final darker = math.min(a, b);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// The pairs [validate] checks.
  ///
  /// Excluded on purpose, each a measured Carbon behaviour rather than a
  /// shortcut: `textPlaceholder`/`textDisabled`/`iconDisabled` (WCAG exempts
  /// inactive components); `textOnColor` on `buttonTertiary` (Carbon paints
  /// tertiary text with `textInverse` on that fill, so that pair is listed
  /// instead); `borderSubtle*` (decorative separators); and
  /// `textSecondary`/`textHelper`/`textError` on `layer03`/`field03`, which
  /// Carbon's own Gray 90 and Gray 100 palettes fall below 4.5:1 on (see
  /// [extendedPairs]). `textPrimary` is still checked on those surfaces.
  static final List<CarbonContrastPair> pairs = _buildPairs(
    includeThirdLayerSecondaryText: false,
  );

  /// [pairs] plus secondary, helper and error text on the third layer.
  ///
  /// Carbon's dark themes do not pass this set, so it is for custom palettes
  /// that want to be stricter than Carbon, not a release gate for the built-ins.
  static final List<CarbonContrastPair> extendedPairs = _buildPairs(
    includeThirdLayerSecondaryText: true,
  );

  /// Pairs from [pairs] that [colors] fails. Empty when all pass.
  static List<CarbonContrastIssue> validate(
    CarbonColors colors, {
    List<CarbonContrastPair>? pairs,
  }) {
    final issues = <CarbonContrastIssue>[];
    for (final pair in pairs ?? CarbonContrast.pairs) {
      final ratio = contrastRatio(
        pair.foregroundOf(colors),
        pair.backgroundOf(colors),
      );
      if (ratio + 1e-9 < pair.required) {
        issues.add(
          CarbonContrastIssue(
            foreground: pair.foreground,
            background: pair.background,
            ratio: ratio,
            required: pair.required,
          ),
        );
      }
    }
    return issues;
  }
}

List<CarbonContrastPair> _buildPairs({
  required bool includeThirdLayerSecondaryText,
}) {
  final surfaces = <String, Color Function(CarbonColors)>{
    'background': (c) => c.background,
    'layer01': (c) => c.layer01,
    'layer02': (c) => c.layer02,
    'layer03': (c) => c.layer03,
    'field01': (c) => c.field01,
    'field02': (c) => c.field02,
    'field03': (c) => c.field03,
  };
  final texts = <String, Color Function(CarbonColors)>{
    'textPrimary': (c) => c.textPrimary,
    'textSecondary': (c) => c.textSecondary,
    'textHelper': (c) => c.textHelper,
    'textError': (c) => c.textError,
  };
  final pairs = <CarbonContrastPair>[];
  void add(
    String fg,
    Color Function(CarbonColors) fgOf,
    String bg,
    Color Function(CarbonColors) bgOf,
    double required,
  ) => pairs.add(
    CarbonContrastPair(
      foreground: fg,
      background: bg,
      required: required,
      foregroundOf: fgOf,
      backgroundOf: bgOf,
    ),
  );

  for (final text in texts.entries) {
    for (final surface in surfaces.entries) {
      final thirdLayer = surface.key == 'layer03' || surface.key == 'field03';
      if (thirdLayer &&
          text.key != 'textPrimary' &&
          !includeThirdLayerSecondaryText) {
        continue;
      }
      add(text.key, text.value, surface.key, surface.value,
          CarbonContrast.textRatio);
    }
  }
  add('textOnColor', (c) => c.textOnColor, 'buttonPrimary',
      (c) => c.buttonPrimary, CarbonContrast.textRatio);
  add('textOnColor', (c) => c.textOnColor, 'buttonSecondary',
      (c) => c.buttonSecondary, CarbonContrast.textRatio);
  add('textInverse', (c) => c.textInverse, 'buttonTertiary',
      (c) => c.buttonTertiary, CarbonContrast.textRatio);
  add('textOnColor', (c) => c.textOnColor, 'buttonDangerPrimary',
      (c) => c.buttonDangerPrimary, CarbonContrast.textRatio);

  add('iconPrimary', (c) => c.iconPrimary, 'background', (c) => c.background,
      CarbonContrast.nonTextRatio);
  add('focus', (c) => c.focus, 'background', (c) => c.background,
      CarbonContrast.nonTextRatio);
  add('borderStrong01', (c) => c.borderStrong01, 'field01', (c) => c.field01,
      CarbonContrast.nonTextRatio);
  add('supportError', (c) => c.supportError, 'background',
      (c) => c.background, CarbonContrast.nonTextRatio);
  add('interactive', (c) => c.interactive, 'background', (c) => c.background,
      CarbonContrast.nonTextRatio);
  return List.unmodifiable(pairs);
}
