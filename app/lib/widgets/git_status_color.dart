import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

// supportWarning is a fill colour: as text on a light layer it is about 1.6:1.
// Yellow 60 clears AA there.
const Color _modifiedOnLight = Color(0xFF8E6A00);

bool _isLight(CarbonColors colors) => colors.background.computeLuminance() > 0.5;

/// Maps a git status letter (M/A/D/R/U/!) to its Carbon role colour.
///
/// Shared by the Git panel's file rows and the diff viewer's header badge so
/// the whole letter vocabulary is answered in one place: a surface that
/// renders a status letter must take its colour from here, not invent a
/// second mapping.
Color gitStatusColor(CarbonColors colors, String status) {
  return switch (status) {
    'M' => _isLight(colors) ? _modifiedOnLight : colors.supportWarning,
    'A' => colors.supportSuccess,
    'D' => colors.supportError,
    'R' => colors.supportInfo,
    'U' => colors.supportInfo,
    '!' => colors.supportCautionMajor,
    _ => colors.iconSecondary,
  };
}
