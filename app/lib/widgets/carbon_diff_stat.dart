import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import 'carbon_code_style.dart';

enum CarbonDiffStatSize {
  /// Row badges: the app's code size.
  small,

  /// Headers and totals: two logical pixels above [small].
  medium,
}

/// A `+N −M` line-count pair in the green and red every git surface reads it
/// in. Only for use inside an `AbCarbonScope`.
///
/// A zero side is omitted, and both zero renders nothing, so a clean file has
/// no stat rather than a `+0 −0`. The pair speaks as one node, "N added, M
/// removed", because assistive tech reads the glyphs as punctuation or drops
/// them.
class CarbonDiffStat extends StatelessWidget {
  const CarbonDiffStat({
    super.key,
    required this.additions,
    required this.deletions,
    this.size = CarbonDiffStatSize.small,
  });

  final int additions;
  final int deletions;
  final CarbonDiffStatSize size;

  static const String minus = '−';

  /// Thousands separators: totals over a worktree run into five digits, and
  /// `+2728` reads as a different magnitude than `+2,728` at a glance.
  static String formatCount(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// The spoken form of the pair, also usable as a tooltip.
  static String describe(int additions, int deletions) => [
    if (additions > 0) '${formatCount(additions)} added',
    if (deletions > 0) '${formatCount(deletions)} removed',
  ].join(', ');

  @override
  Widget build(BuildContext context) {
    if (additions <= 0 && deletions <= 0) return const SizedBox.shrink();
    final t = CarbonTheme.of(context);
    final code = CarbonCodeStyle.baseTextFor(t);
    final base = switch (size) {
      CarbonDiffStatSize.small => code,
      CarbonDiffStatSize.medium => code.copyWith(
        fontSize: code.fontSize! + 2,
        height: (code.fontSize! * code.height! + 4) / (code.fontSize! + 2),
      ),
    };
    return Semantics(
      container: true,
      label: describe(additions, deletions),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: CarbonSpacing.spacing02,
          children: [
            if (additions > 0)
              Text(
                '+${formatCount(additions)}',
                style: base.copyWith(color: t.colors.supportSuccess),
              ),
            if (deletions > 0)
              Text(
                '$minus${formatCount(deletions)}',
                style: base.copyWith(color: t.colors.supportError),
              ),
          ],
        ),
      ),
    );
  }
}
