import 'package:flutter/widgets.dart';

import '../ab_colors.dart';
import '../ab_tokens.dart';

/// A `+N -M` line-count pair, in the green/red every git surface reads it in.
///
/// Shared by the per-file badge in the changed-file tree and the whole-worktree
/// totals on the Git tab and the changes header, so a file's stat and the sum
/// over files can never render as two different things.
class AbDiffStat extends StatelessWidget {
  const AbDiffStat({
    super.key,
    required this.additions,
    required this.deletions,
    this.fontSize = AbTokens.fontXxs,
  });

  final int additions;
  final int deletions;
  final double fontSize;

  /// Thousands separators: totals over a worktree run into five digits, and
  /// `+2728` is read as a different magnitude than `+2,728` at a glance.
  static String formatCount(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (additions > 0)
          Text(
            '+${formatCount(additions)}',
            style: AbTokens.monoStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: p.success,
            ),
          ),
        if (additions > 0 && deletions > 0)
          const SizedBox(width: AbTokens.space4),
        if (deletions > 0)
          Text(
            '-${formatCount(deletions)}',
            style: AbTokens.monoStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: p.error,
            ),
          ),
      ],
    );
  }

  /// The same pair as a string, for a semantics label or a tooltip — assistive
  /// tech announces the glyphs as punctuation, or drops them entirely.
  static String describe(int additions, int deletions) => [
    if (additions > 0) '${formatCount(additions)} added',
    if (deletions > 0) '${formatCount(deletions)} removed',
  ].join(', ');
}
