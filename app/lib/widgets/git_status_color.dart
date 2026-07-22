import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';

/// Maps a git status code (M/A/D/?) to its badge color. Single source of truth
/// shared by the file tree and the diff viewer so the two can't drift — renames
/// (`R`) are filtered out at the bridge, so there is intentionally no `R` case.
Color gitStatusColor(BuildContext context, String status) {
  return switch (status) {
    'M' => context.antgrid.warning,
    'A' => context.antgrid.success,
    'D' => context.antgrid.error,
    '?' => context.antgrid.success,
    _ => context.antgrid.textDisabled,
  };
}
