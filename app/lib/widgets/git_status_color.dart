import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';

/// Maps a git status letter (M/A/D/R/U/!) to its badge color.
///
/// One caller today — `diff_viewer.dart`'s header badge. The file tree shows a
/// +N/-N diff stat (or an `AbStatusDot`) instead of a letter, and the commit
/// dialog no longer lists files at all, so both stopped calling this. It stays
/// a shared function rather than folding into the viewer because the whole
/// letter vocabulary is answered here: a surface that renders a status letter
/// again must get its colour from this, not invent a second mapping.
Color gitStatusColor(BuildContext context, String status) {
  return switch (status) {
    'M' => context.antgrid.warning,
    'A' => context.antgrid.success,
    'D' => context.antgrid.error,
    'R' => context.antgrid.gitUntracked,
    'U' => context.antgrid.gitUntracked,
    '!' => context.antgrid.gitConflict,
    _ => context.antgrid.iconMuted,
  };
}
