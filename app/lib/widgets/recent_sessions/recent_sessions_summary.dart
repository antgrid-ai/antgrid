import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../providers/value_controller.dart';
import '../../services/control_plane_client.dart';
import '../agent_work_status_dot.dart';

/// Status ordering used everywhere the Recent list speaks about states: the two
/// call-to-action states first (a blocked or errored agent is what the user
/// opened Recent to find), then working, then the answers waiting to be read,
/// then done. Mirrors the bridge's rollup rank (`RANK` in work-status.ts) — the
/// buckets and the project dot must not disagree about which state is louder.
const kWorkStatusOrder = [
  AgentWorkStatus.attention,
  AgentWorkStatus.error,
  AgentWorkStatus.working,
  AgentWorkStatus.unread,
  AgentWorkStatus.done,
];

String workStatusLabel(AgentWorkStatus s) => switch (s) {
  // "Needs you", not "Needs attention": it reads as the summary badge
  // ("1 needs you") and matches the Handler pill's wording for the same idea.
  AgentWorkStatus.attention => 'Needs you',
  AgentWorkStatus.error => 'Error',
  AgentWorkStatus.working => 'Working',
  AgentWorkStatus.unread => 'Unread',
  AgentWorkStatus.done => 'Done',
};

/// `Sessions · N total` and the per-state summary badges on one line.
///
/// Phone-width only ([_TopBar] in `new_session_content.dart` picks this over
/// the tablet/desktop title+chips+badges arrangement below
/// `kCompactBreakpoint`) — there's no room on a phone for the group-by chips
/// too, so this keeps the old two-piece layout instead of squeezing a third
/// element into the row.
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

/// `Sessions · N total` on its own — every mount point that places the chips
/// and badges around it itself (the canvas's fixed top bar on tablet/narrow
/// desktop, `_SessionsHeader` on a wide mouse desktop), since the arrangement
/// differs (chips between title and badges, plus a drawer button and search
/// icon at the outer edges on tablet/narrow).
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
        // A Wrap wraps BETWEEN badges but still bounds each one to its own
        // maxWidth, so a badge narrower than its label has to shrink itself —
        // and it can get that narrow wherever an inflexible neighbour splits
        // the row first (`_SessionsHeader`'s group-by chips between two
        // Expandeds). Degrades the way [RecentSessionsTitle] already does.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: statusTone.color(context),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

/// Which axis groups the Recent list. Shared state, not a ctor param: the
/// chips ([RecentGroupByChips]) and the list that reads them
/// ([RecentSessionsTab]) mount in different subtrees of the canvas (the
/// former in the fixed top bar on touch/narrow, the latter in the scroll
/// view below it), so there is no shared ancestor State to prop-drill
/// through.
enum RecentGroupBy { machine, project, status }

final recentGroupByProvider =
    NotifierProvider<ValueController<RecentGroupBy>, RecentGroupBy>(
      () => ValueController(RecentGroupBy.machine),
    );

/// The Machine / Project / Status toggle chips. Hides itself while there are
/// no recent sessions to group — [RecentSessionsTab] never builds its group
/// headers in that state either, so a live chip row would toggle a grouping
/// nothing on screen obeys.
class RecentGroupByChips extends ConsumerWidget {
  const RecentGroupByChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(recentSessionsProvider).isEmpty) {
      return const SizedBox.shrink();
    }
    final groupBy = ref.watch(recentGroupByProvider);
    void select(RecentGroupBy g) =>
        ref.read(recentGroupByProvider.notifier).set(g);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GroupChip(
          label: 'Machine',
          selected: groupBy == RecentGroupBy.machine,
          onTap: () => select(RecentGroupBy.machine),
        ),
        const SizedBox(width: AbTokens.space6),
        _GroupChip(
          label: 'Project',
          selected: groupBy == RecentGroupBy.project,
          onTap: () => select(RecentGroupBy.project),
        ),
        const SizedBox(width: AbTokens.space6),
        _GroupChip(
          label: 'Status',
          selected: groupBy == RecentGroupBy.status,
          onTap: () => select(RecentGroupBy.status),
        ),
      ],
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AbChip.toggle(
      label: label,
      selected: selected,
      onTap: onTap,
      color: selected ? context.antgrid.accent : null,
    );
  }
}
