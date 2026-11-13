import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../providers/value_controller.dart';
import '../../services/control_plane_client.dart';
import '../agent_work_status_indicator.dart';

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

/// `Sessions` and the per-state summary badges on one line.
///
/// Phone-width only ([_TopBar] in `new_session_content.dart` picks this over
/// the tablet/desktop arrangement below `kCompactBreakpoint`).
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
          const SizedBox(width: CarbonSpacing.spacing04),
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

/// The canvas title on its own, for the mount points that place the badges and
/// a drawer or search button around it themselves. The count lives in the
/// list's header, which scrolls with the rows it counts.
class RecentSessionsTitle extends StatelessWidget {
  const RecentSessionsTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Text(
      'Sessions',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: t.typography.heading.copyWith(color: t.colors.textPrimary),
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
      spacing: CarbonSpacing.spacing04,
      runSpacing: CarbonSpacing.spacing02,
      children: [
        for (final s in kWorkStatusOrder)
          if ((counts[s] ?? 0) > 0)
            // A Wrap bounds each child to its own maxWidth, so a badge
            // narrower than its label has to shrink itself; the indicator
            // ellipsizes its label rather than overflowing.
            CarbonIconIndicator(
              kind: agentWorkStatusIndicatorKind(s),
              label: '${counts[s]} ${workStatusLabel(s).toLowerCase()}',
            ),
      ],
    );
  }
}

/// Which axis groups the Recent list. Shared state, not a ctor param: the
/// switcher ([RecentGroupByChips]) and the list that reads them
/// ([RecentSessionsTab]) mount in different subtrees of the canvas (the
/// former in the fixed top bar on touch/narrow, the latter in the scroll
/// view below it), so there is no shared ancestor State to prop-drill
/// through.
enum RecentGroupBy { machine, project, status }

final recentGroupByProvider =
    NotifierProvider<ValueController<RecentGroupBy>, RecentGroupBy>(
      () => ValueController(RecentGroupBy.project),
    );

String _groupByWord(RecentGroupBy g) => switch (g) {
  RecentGroupBy.machine => 'Machine',
  RecentGroupBy.project => 'Project',
  RecentGroupBy.status => 'Status',
};

/// The Machine / Project / Status switcher, for a list wide enough to show all
/// three segments. Hides itself while there are no recent sessions to group:
/// [RecentSessionsTab] never builds its group headings in that state either, so
/// a live switcher would toggle a grouping nothing on screen obeys.
///
/// Needs an `AbCarbonScope` above it: the switcher is 32 tall on a compact
/// density and 44 on touch.
class RecentGroupByChips extends ConsumerWidget {
  const RecentGroupByChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(recentSessionsProvider).isEmpty) {
      return const SizedBox.shrink();
    }
    final groupBy = ref.watch(recentGroupByProvider);
    return CarbonContentSwitcher<RecentGroupBy>(
      semanticLabel: 'Group by',
      size: CarbonContentSwitcherSize.small,
      value: groupBy,
      onChanged: (g) => ref.read(recentGroupByProvider.notifier).set(g),
      options: [
        for (final g in RecentGroupBy.values)
          CarbonOption(value: g, label: _groupByWord(g)),
      ],
    );
  }
}

/// The same choice as one ghost button for a list too narrow for three
/// segments: the button names the current grouping and the menu changes it.
class RecentGroupByMenu extends ConsumerWidget {
  const RecentGroupByMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(recentSessionsProvider).isEmpty) {
      return const SizedBox.shrink();
    }
    final groupBy = ref.watch(recentGroupByProvider);
    return CarbonMenuButton(
      label: 'By ${_groupByWord(groupBy).toLowerCase()}',
      semanticLabel: 'Group by',
      triggerSemanticLabel: 'Group by: ${_groupByWord(groupBy)}',
      kind: CarbonButtonKind.ghost,
      neutral: true,
      size: CarbonButtonSize.small,
      maxLines: 1,
      alignment: CarbonPopupAlignment.end,
      entries: [
        CarbonMenuRadioGroup<RecentGroupBy>(
          value: groupBy,
          onChanged: (g) => ref.read(recentGroupByProvider.notifier).set(g),
          options: [
            for (final g in RecentGroupBy.values)
              CarbonOption(value: g, label: _groupByWord(g)),
          ],
        ),
      ],
    );
  }
}

/// First sliver of the Recent list: the title with its session count, then the
/// grouping control, and, where the canvas has no top bar to carry them, the
/// status badges between the two.
///
/// [inset] is the list's own horizontal inset, decided by the tab from its
/// width; [wide] picks the switcher over the menu button for the same reason.
class RecentListHeader extends ConsumerWidget {
  const RecentListHeader({
    super.key,
    required this.wide,
    required this.inset,
    this.showSummary = true,
  });

  final bool wide;
  final double inset;
  final bool showSummary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = ref.watch(recentSessionsProvider).length;
    final t = CarbonTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        inset,
        CarbonSpacing.spacing05,
        inset,
        CarbonSpacing.spacing04,
      ),
      // Title and grouping control are both loose flex children, so at a
      // large text size each gives way with an ellipsis instead of pushing
      // the other off the row; the badges, when present, take the slack.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'Recent',
                  maxLines: 1,
                  style: t.typography.heading.copyWith(
                    color: t.colors.textPrimary,
                  ),
                ),
                const SizedBox(width: CarbonSpacing.spacing04),
                Flexible(
                  child: Text(
                    total == 1 ? '1 session' : '$total sessions',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.label.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showSummary)
            const Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing04,
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: RecentSessionsSummaryBadges(),
                ),
              ),
            )
          else
            const SizedBox(width: CarbonSpacing.spacing04),
          if (wide)
            const RecentGroupByChips()
          else
            const Flexible(child: RecentGroupByMenu()),
        ],
      ),
    );
  }
}
