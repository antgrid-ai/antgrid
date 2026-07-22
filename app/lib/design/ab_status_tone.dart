import 'package:flutter/widgets.dart';

import 'ab_colors.dart';

/// Semantic status tone for dots, indicators, and any future status surface.
/// Resolves to a concrete color via [color]. Keep this layer thin —
/// domain enums map to tones in their own adapters, never directly to colors.
enum AbStatusTone { neutral, info, success, warning, danger, muted, disabled }

extension AbStatusToneColor on AbStatusTone {
  Color color(BuildContext context) {
    final palette = context.antgrid;
    return switch (this) {
      AbStatusTone.neutral => palette.textSecondary,
      AbStatusTone.info => palette.accent,
      AbStatusTone.success => palette.success,
      AbStatusTone.warning => palette.warning,
      AbStatusTone.danger => palette.error,
      AbStatusTone.muted => palette.textMuted,
      AbStatusTone.disabled => palette.textDisabled,
    };
  }
}
