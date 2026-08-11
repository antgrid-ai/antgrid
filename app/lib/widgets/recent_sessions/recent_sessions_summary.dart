import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../services/control_plane_client.dart';
import '../agent_work_status_dot.dart';

/// Status ordering used everywhere the Recent list speaks about states: the two
/// call-to-action states first (a blocked or errored agent is what the user
/// opened Recent to find), then working, then done.
const kWorkStatusOrder = [
  AgentWorkStatus.attention,
  AgentWorkStatus.error,
  AgentWorkStatus.working,
  AgentWorkStatus.done,
];

String workStatusLabel(AgentWorkStatus s) => switch (s) {
  // "Needs you", not "Needs attention": it reads as the summary badge
  // ("1 needs you") and matches the Handler pill's wording for the same idea.
  AgentWorkStatus.attention => 'Needs you',
  AgentWorkStatus.error => 'Error',
  AgentWorkStatus.working => 'Working',
  AgentWorkStatus.done => 'Done',
};

/// `Sessions · N total` and the per-state summary badges on one line.
///
/// Lives apart from the list so mobile can hoist it onto the canvas's top bar
/// (beside the drawer button) rather than spend a row on it inside the scroll
/// view, where it scrolls out of reach. Reads its own numbers, so the two mount
/// points can never disagree about the count.
class RecentSessionsSummaryLine extends StatelessWidget {
  const RecentSessionsSummaryLine({super.key});

  /// Share of the line the badges may claim before they start wrapping. The
  /// remainder is the title's floor, which is why this is a cap and not a flex:
  /// two flexible children would split the line evenly and ellipsize the title
  /// even when a single badge is all there is to show.
  static const double _badgeShare = 0.6;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          const Expanded(child: RecentSessionsTitle()),
          const SizedBox(width: AbTokens.space10),
          // The badges are a Wrap, and a Wrap sitting directly in a Row is
          // handed UNBOUNDED main-axis constraints — so it never wraps, and at
          // four states on a phone it overruns the edge and starves the title.
          // Bound it here; inside the cap it wraps as intended.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth * _badgeShare,
            ),
            child: const RecentSessionsSummaryBadges(),
          ),
        ],
      ),
    );
  }
}

/// `Sessions · N total` on its own, for surfaces that place the badges
/// themselves (the desktop header puts the filter chips between the two).
class RecentSessionsTitle extends ConsumerWidget {
  const RecentSessionsTitle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(recentSessionsProvider).length;
    return Text(
      'Sessions · $total total',
      overflow: TextOverflow.ellipsis,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontMd,
        color: context.antgrid.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// The `2 needs you · 11 done` run of counts, one badge per non-empty state.
class RecentSessionsSummaryBadges extends ConsumerWidget {
  const RecentSessionsSummaryBadges({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(recentSessionStatusCountsProvider);
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: AbTokens.space8,
      runSpacing: AbTokens.space6,
      children: [
        for (final s in kWorkStatusOrder)
          if ((counts[s] ?? 0) > 0)
            _SummaryBadge(
              label: '${counts[s]} ${workStatusLabel(s).toLowerCase()}',
              // Pulse the live states (working + attention) so activity
              // registers without reading the numbers.
              live:
                  s == AgentWorkStatus.working ||
                  s == AgentWorkStatus.attention,
              tone: s,
            ),
      ],
    );
  }
}

class _SummaryBadge extends StatelessWidget {
  const _SummaryBadge({
    required this.label,
    required this.tone,
    this.live = false,
  });

  final String label;

  /// The state this badge summarizes — the sole colour source, so the badge
  /// text and its dot can never disagree about what the status looks like.
  final AgentWorkStatus tone;

  /// Prefix a pulsing activity dot — used for the live states (working /
  /// attention) so activity registers at a glance without reading the numbers.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final statusTone = agentWorkStatusDotSpec(tone).tone;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live) ...[
          AbStatusDot(
            tone: statusTone,
            size: AbDotSize.sm,
            style: AbDotStyle.filled,
            pulse: true,
          ),
          const SizedBox(width: AbTokens.space6),
        ],
        Text(
          label,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: statusTone.color(context),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
