import 'dart:math' as math;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connection/supervisor_state.dart';
import '../../constants/breakpoints.dart';
import '../../demo/demo_identity.dart';
import '../../models/recent_session_row.dart';
import '../../providers/demo_mode.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../providers/supervisor_status.dart';
import '../../services/control_plane_client.dart';
import '../../util/detached.dart';
import '../ab_status_helpers.dart';
import '../agent_work_status_indicator.dart';
import '../first_run_checklist.dart';
import 'carbon_recent_session_row.dart';
import 'recent_sessions_summary.dart';
import 'starting_session_row.dart';

class _SessionGroup {
  const _SessionGroup({
    required this.id,
    required this.label,
    required this.rows,
    this.machineUuid,
    this.status,
  });

  /// The bucket key: stable, unlike [label], which two groups can share.
  final String id;
  final String label;
  final List<RecentSessionRow> rows;

  /// Set only when grouped by machine and the group is a remote machine -
  /// [_GroupHeading] uses it to show a "Connecting..." indicator while that
  /// machine's socket (opened by pull-to-refresh, or a row's own delete/open)
  /// is still mid-handshake. Never triggers a connection itself.
  final String? machineUuid;

  /// Set only when grouped by status, where the heading is the status
  /// indicator rather than plain text.
  final AgentWorkStatus? status;
}

/// Scrollable list of recent sessions grouped by machine, project, or status.
///
/// Each row carries its own delete affordance ([CarbonRecentSessionRow] — a
/// trash button revealed on hover or focus on desktop, always visible on
/// touch).
///
/// Must sit under an `AbCarbonScope`, which supplies theme and density.
///
/// Landing here never dials the relay: it renders straight from the cache
/// (instant, offline-friendly). Connecting to sync fresh session lists is an
/// explicit pull-to-refresh gesture — the ancestor [RefreshIndicator] in
/// new_session_content.dart calls [pullToRefreshRecentSessions]; see module
/// docs on that function for why eagerly auto-connecting every ever-paired
/// machine was removed.
class RecentSessionsTab extends ConsumerStatefulWidget {
  const RecentSessionsTab({super.key, this.showSummary = true});

  /// Whether the status summary badges sit in the list header. The header
  /// itself always mounts above the rows. Passed DOWN from the screen that
  /// decides whether the canvas mounts a fixed top bar carrying the same
  /// badges (`_TopBar` in `new_session_content.dart`) rather than re-derived
  /// from platform+width here: only the screen knows which one is mounted.
  final bool showSummary;

  @override
  ConsumerState<RecentSessionsTab> createState() => _RecentSessionsTabState();
}

class _RecentSessionsTabState extends ConsumerState<RecentSessionsTab> {
  /// Owned here, and handed to whichever of the two branches builds, so a
  /// start can bring the list back to the top.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// [StartingSessionRow] is the first sliver in both branches, so for a
  /// scrolled-down user it grows and collapses ABOVE the viewport: the
  /// viewport keeps its offset, so every visible row is shoved down by the
  /// row's height when a start begins and back up when it ends — while the
  /// row itself, the entire point of it, is never on screen.
  ///
  /// Riding the user's own Send back to the top resolves both halves: the
  /// shift becomes a motion they caused, and it lands them where the session
  /// being started — and the real row it turns into — actually appear.
  void _revealStartingRow() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    final duration = CarbonMotion.resolve(context, CarbonMotion.moderate01);
    if (duration == Duration.zero) {
      _scroll.jumpTo(0);
      return;
    }
    detached('recents', 'scroll to starting row', () async {
      await _scroll.animateTo(
        0,
        duration: duration,
        curve: CarbonMotion.standard,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(newSessionStartInFlightProvider, (previous, next) {
      if (next && previous != true) _revealStartingRow();
    });
    final rows = ref.watch(recentSessionsProvider);

    if (rows.isEmpty) {
      // A fresh phone install has no Local source and no machines on the
      // account, so every path into a session is dead (project chip, drawer,
      // Send). This is the one surface with room to say what unblocks it, so
      // the first-run checklist replaces the generic empty state until it is
      // completed or dismissed — it stays through the later steps (Remote,
      // open a project) even once a machine exists in the inventory.
      // Its own predicate (desktop short-circuits before touching the first-run
      // chain, and the demo before reaching the account) — never re-derived
      // here, or the checklist and the chrome around it disagree.
      final showChecklist = mobileFirstRunChecklistVisible(ref);
      // "Describe a task below" is a lie while nothing is picked — Send stays
      // disabled without a valid target — so name the actual next step.
      final hasTarget = ref.watch(newSessionHasValidTargetProvider);
      // This list goes momentarily empty inside the demo too (before the
      // fixture session:list lands, and after a mobile background evicts the
      // warm demo), and offering the way in from inside is worse than offering
      // nothing.
      final offerDemo = !hasTarget && !ref.watch(demoModeProvider);
      // A scrollable empty state so the ancestor RefreshIndicator (in
      // new_session_content.dart) always has a gesture target: the empty
      // state is a bare Center with no Scrollable of its own, so pull-to-refresh
      // would be inert here without this wrapper. It must stay the only
      // Scrollable under the tab: a second one could win the vertical drag
      // from the refresh viewport.
      // The width is read once out here: a SliverLayoutBuilder inside the
      // viewport would rerun, and rebuild its rows, on every scroll frame.
      return LayoutBuilder(
        builder: (context, box) {
          final padding = _listPadding(box.maxWidth);
          return CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Mounted in this branch too: the first session a user ever
              // starts is started from an empty list, which is exactly when an
              // unaccounted-for 30s wait is least explicable.
              SliverPadding(
                padding: padding,
                sliver: const SliverToBoxAdapter(child: StartingSessionRow()),
              ),
              // Not SliverFillRemaining: that sizes its child from the
              // child's intrinsic height, which a max-width box under-reports
              // (it measures text at the full width, not the capped one), so
              // a tall checklist overflowed instead of scrolling. A minimum
              // height centres it the same way and lets it grow past the
              // viewport.
              SliverLayoutBuilder(
                builder: (context, constraints) => SliverPadding(
                  padding: padding,
                  sliver: SliverToBoxAdapter(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: math.max(
                          0,
                          constraints.viewportMainAxisExtent -
                              constraints.precedingScrollExtent,
                        ),
                      ),
                      child: Center(
                        child: showChecklist
                            ? const MobileFirstRunChecklist()
                            : _RecentsEmptyState(
                                title: 'No recent sessions',
                                subtitle: hasTarget
                                    ? 'Describe a task below to start your '
                                          'first session.'
                                    : 'Pick a project, then describe a task '
                                          'below.',
                                // Nothing picked means every path into a
                                // session is still dead - offer the one that
                                // needs no machine at all.
                                onEnterDemo: offerDemo
                                    ? () => enterDemoMode(ref.container)
                                    : null,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    // Effective per-row status, computed once for the whole list (see
    // [recentSessionStatusesProvider]) and shared with the summary line, so
    // "1 needs you" counts the ONE blocked session, not every session sharing
    // its project.
    final statusByKey = ref.watch(recentSessionStatusesProvider);
    final statusFor = <RecentSessionRow, AgentWorkStatus>{
      for (final r in rows)
        r:
            statusByKey[recentStatusKey(
              r.origin.registrationId,
              r.session.id,
            )] ??
            AgentWorkStatus.done,
    };

    final groupBy = ref.watch(recentGroupByProvider);
    final groups = _groupSessions(rows, groupBy, statusFor);

    // While a start is in flight its row sits between the header and the first
    // heading, so that heading needs its own gap above it.
    final starting = ref.watch(newSessionStartInFlightProvider);

    // Wide or narrow is the list's own width, not the screen's: the canvas caps
    // this column, so a wide window can still hand it a phone-sized one. Read
    // once out here, since inside the viewport it would be re-resolved on every
    // scroll frame.
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= kCompactBreakpoint;
        final padding = _listPadding(box.maxWidth);
        final inset = wide ? CarbonSpacing.spacing06 : CarbonSpacing.spacing05;
        return CustomScrollView(
          controller: _scroll,
          // Stated, not inherited: `ScrollView` only defaults to
          // AlwaysScrollableScrollPhysics while it has NO controller, so
          // handing it one would otherwise leave a list shorter than the
          // viewport refusing the drag - and the ancestor RefreshIndicator
          // (new_session_content.dart) inert for exactly the users with the
          // fewest recent sessions.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: RecentListHeader(
                wide: wide,
                inset: inset,
                showSummary: widget.showSummary,
              ),
            ),
            // Above the groups, not inside one: the session does not exist
            // yet, so it belongs to no machine, project or status bucket.
            SliverPadding(
              padding: padding,
              sliver: const SliverToBoxAdapter(child: StartingSessionRow()),
            ),
            for (var i = 0; i < groups.length; i++) ...[
              SliverToBoxAdapter(
                child: _GroupHeading(
                  group: groups[i],
                  inset: inset,
                  first: i == 0 && !starting,
                ),
              ),
              SliverPadding(
                padding: padding,
                sliver: CarbonContainedListSliver(
                  key: ValueKey('recent-group-${groups[i].id}'),
                  label: null,
                  itemCount: groups[i].rows.length,
                  itemBuilder: (context, rowIndex) {
                    final row = groups[i].rows[rowIndex];
                    return CarbonRecentSessionRow(
                      key: ValueKey(
                        '${row.origin.registrationId}:${row.session.id}',
                      ),
                      row: row,
                      groupedBy: groupBy,
                    );
                  },
                ),
              ),
            ],
            const SliverToBoxAdapter(
              child: SizedBox(height: CarbonSpacing.spacing05),
            ),
          ],
        );
      },
    );
  }
}

/// Rows and the composer share this inset on a wide list so their edges line
/// up; a narrow list runs its rows edge to edge.
EdgeInsets _listPadding(double width) => EdgeInsets.symmetric(
  horizontal: width >= kCompactBreakpoint ? CarbonSpacing.spacing06 : 0,
);

List<_SessionGroup> _groupSessions(
  List<RecentSessionRow> rows,
  RecentGroupBy groupBy,
  Map<RecentSessionRow, AgentWorkStatus> statusFor,
) {
  // Machine and status buckets key on a STABLE identity (machineUuid / status
  // name), never a display string — two machines can share a name. Project
  // grouping is the deliberate exception: a project's id is a hash of its
  // folder path, so the same repo on two machines never shares an id and only
  // its name can unite them. The cost is that two unrelated projects with the
  // same name merge into one group; rows still name their machine.
  final buckets = <String, List<RecentSessionRow>>{};
  final labels = <String, String>{};
  for (final row in rows) {
    final String key;
    final String label;
    switch (groupBy) {
      case RecentGroupBy.machine:
        key = row.origin.machineUuid ?? 'local';
        label = row.origin.deviceName;
      case RecentGroupBy.project:
        key = row.origin.projectName.toLowerCase();
        label = row.origin.projectName;
      case RecentGroupBy.status:
        final s = statusFor[row] ?? AgentWorkStatus.done;
        key = s.name;
        label = workStatusLabel(s);
    }
    buckets.putIfAbsent(key, () => []).add(row);
    labels[key] = label;
  }

  // Every grouping leads with the group worked in most recently; the label
  // only breaks ties. One exception: by status, "needs you" always leads —
  // a blocked agent is waiting on the user however old its last activity.
  final latest = {
    for (final e in buckets.entries)
      e.key: e.value.map((r) => r.session.lastUsedAt).reduce(math.max),
  };
  final pinned = groupBy == RecentGroupBy.status
      ? AgentWorkStatus.attention.name
      : null;
  final keys = buckets.keys.toList()
    ..sort((a, b) {
      if (a == pinned) return -1;
      if (b == pinned) return 1;
      final byRecency = latest[b]!.compareTo(latest[a]!);
      if (byRecency != 0) return byRecency;
      return labels[a]!.toLowerCase().compareTo(labels[b]!.toLowerCase());
    });

  return [
    for (final key in keys)
      _SessionGroup(
        id: key,
        label: labels[key]!,
        rows: buckets[key]!,
        // Machine-grouped bucket keys ARE the machineUuid (or 'local'); a
        // remote group's rows all share one machineUuid, so the first row's
        // origin gives it directly.
        machineUuid: groupBy == RecentGroupBy.machine
            ? buckets[key]!.first.origin.machineUuid
            : null,
        status: groupBy == RecentGroupBy.status
            ? AgentWorkStatus.values.byName(key)
            : null,
      ),
  ];
}

/// Not a scrolling empty state: the tab's [CustomScrollView] is the one
/// Scrollable, and nesting another would split the drag.
class _RecentsEmptyState extends StatelessWidget {
  const _RecentsEmptyState({
    required this.title,
    required this.subtitle,
    this.onEnterDemo,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onEnterDemo;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CarbonSpacing.spacing06),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: CarbonSpacing.spacing09 * 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: t.typography.heading.copyWith(
                  color: t.colors.textPrimary,
                ),
              ),
              const SizedBox(height: CarbonSpacing.spacing03),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: t.typography.body.copyWith(
                  color: t.colors.textSecondary,
                ),
              ),
              if (onEnterDemo != null) ...[
                const SizedBox(height: CarbonSpacing.spacing05),
                CarbonButton(
                  label: kDemoEntryLabel,
                  kind: CarbonButtonKind.tertiary,
                  onPressed: onEnterDemo,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A group's heading on the page background, not a filled band: the label (the
/// status indicator when grouped by status) then the session count as plain
/// text, then a "Connecting..." indicator for a remote machine group whose
/// socket is mid-handshake.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.group,
    required this.inset,
    required this.first,
  });

  final _SessionGroup group;
  final double inset;

  /// The list header already gives space above the first heading, unless a
  /// starting row sits between them.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final count = group.rows.length;
    final countText = count == 1 ? '1 session' : '$count sessions';
    final status = group.status;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        inset,
        first ? 0 : CarbonSpacing.spacing05,
        inset,
        CarbonSpacing.spacing03,
      ),
      child: Row(
        children: [
          Flexible(
            child: Semantics(
              header: true,
              container: true,
              label: '${group.label}, $countText',
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: status != null
                        ? CarbonIconIndicator(
                            kind: agentWorkStatusIndicatorKind(status),
                            label: group.label,
                          )
                        : Text(
                            group.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.typography.label.copyWith(
                              color: t.colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  const SizedBox(width: CarbonSpacing.spacing03),
                  Text(
                    '$count',
                    maxLines: 1,
                    style: t.typography.label.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (group.machineUuid != null) ...[
            const SizedBox(width: CarbonSpacing.spacing03),
            _ConnectingIndicator(machineUuid: group.machineUuid!),
          ],
        ],
      ),
    );
  }
}

/// Status shown next to a machine's group header while its control-plane
/// socket is climbing, or once it has stopped on a reason. Reads
/// [supervisorStatusProvider] (peek-only, never dials) — invisible once
/// `Connected` (the fresh row list already communicates "connected", and this
/// is a real peer-presence signal now, not just socket auth), once `Released`
/// (torn down on purpose, not "connecting"), or when nothing has been dialed
/// yet.
class _ConnectingIndicator extends ConsumerWidget {
  const _ConnectingIndicator({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(supervisorStatusProvider(machineUuid)).value;
    if (status == null || status is Connected || status is Released) {
      return const SizedBox.shrink();
    }

    final label = connectionDisplayInfo(status).$2;
    // A block is sticky until the user or an out-of-band event clears it, so it
    // gets the failed glyph rather than the activity spinner.
    if (status is Climbing) {
      return CarbonInlineLoading(
        status: CarbonInlineLoadingStatus.active,
        description: '$label…',
      );
    }
    return CarbonIconIndicator(
      kind: CarbonIconIndicatorKind.failed,
      label: label,
    );
  }
}
