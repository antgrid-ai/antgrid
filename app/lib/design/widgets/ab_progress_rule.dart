import 'dart:ui' show SemanticsRole;

import 'package:flutter/widgets.dart';

import '../ab_colors.dart';

/// Completion as a rule rather than only as a sentence — "3 of 7" has to be
/// read, and the surfaces this sits on are scanned past far more often than
/// they are read.
///
/// The track is [AbColors.bgElevated] rather than a border tint, because at 0%
/// the track is the whole widget, and a hairline in a border colour is
/// indistinguishable from the row dividers around it.
class AbProgressRule extends StatelessWidget {
  const AbProgressRule({super.key, required this.fraction, this.semanticLabel});

  /// What is progressing, for assistive tech. The rule is exposed as a
  /// progress bar (APG `progressbar`/meter: value within a min..max range).
  final String? semanticLabel;

  /// 0..1, or null for indeterminate — a step whose size is unknown (a request
  /// round trip). Indeterminate fills the whole rule in the muted accent, one
  /// tone below the determinate fill, so it reads as "in progress" without
  /// claiming the completion that a full-strength full-width bar would.
  /// Deliberately static: this rides beside live terminal output, and a looping
  /// animation there competes with the thing the user is actually watching.
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final f = fraction;
    // Indeterminate has no value to report, so it is a busy indicator rather
    // than a progress bar with a made-up number.
    return Semantics(
      role: f == null
          ? SemanticsRole.loadingSpinner
          : SemanticsRole.progressBar,
      label: semanticLabel,
      value: f == null ? null : '${(f.clamp(0.0, 1.0) * 100).round()}',
      minValue: f == null ? null : '0',
      maxValue: f == null ? null : '100',
      container: true,
      child: _rule(p, f),
    );
  }

  Widget _rule(AbColors p, double? f) {
    return SizedBox(
      height: 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: p.bgElevated),
          if (f == null)
            ColoredBox(color: p.accentMuted)
          else
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: f.clamp(0.0, 1.0),
              child: ColoredBox(color: p.accent),
            ),
        ],
      ),
    );
  }
}
