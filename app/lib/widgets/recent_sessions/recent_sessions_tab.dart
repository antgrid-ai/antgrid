import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connection/supervisor_state.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/recent_session_row.dart';
import '../../providers/first_run.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../providers/supervisor_status.dart';
import '../../services/control_plane_client.dart';
import '../../util/detached.dart';
import '../../utils/platform_utils.dart';
import '../ab_status_helpers.dart';
import '../first_run_checklist.dart';
import 'recent_session_row_widget.dart';
import 'recent_sessions_summary.dart';
import 'starting_session_row.dart';

class _SessionGroup {
  const _SessionGroup({
    required this.label,
    required this.rows,
    this.machineUuid,
  });

  final String label;
  final List<RecentSessionRow> rows;

  /// Set only when grouped by machine and the group is a remote machine —
  /// [_GroupHeader] uses it to show a "Connecting…" indicator while that
  /// machine's socket (opened by pull-to-refresh, or a row's own delete/open)
  /// is still mid-handshake. Never triggers a connection itself.
  final String? machineUuid;
}

/// Scrollable list of recent sessions grouped by machine, project, or status.
///
/// Each row carries its own delete affordance ([RecentSessionRowWidget] — a
/// hover trash button on desktop, an always-visible one on mobile).
///
/// Landing here never dials the relay: it renders straight from the cache
/// (instant, offline-friendly). Connecting to sync fresh session lists is an
/// explicit pull-to-refresh gesture — the ancestor [RefreshIndicator] in
/// new_session_content.dart calls [pullToRefreshRecentSessions]; see module
/// docs on that function for why eagerly auto-connecting every ever-paired
/// machine was removed.
class RecentSessionsTab extends ConsumerStatefulWidget {
  const RecentSessionsTab({super.key, this.showHeader = true});

  /// Whether to render [_SessionsHeader] (title + group-by chips + badges) as
  /// the list's first sliver. Passed DOWN from the screen that decides whether
  /// the canvas mounts its own fixed top bar carrying that same arrangement
  /// (`_TopBar` in `new_session_content.dart`) rather than re-derived from
  /// platform+width here — exactly one of the two may mount, and only the
  /// screen knows which.
  ///
  /// On by default, opt out to suppress — same shape as
  /// `WorkspacePanel.showTabBar`: the header belongs to this list, and a host
  /// that has hoisted it into its own chrome is the one that has to say so.
  final bool showHeader;

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
    detached('recents', 'scroll to starting row', () async {
      await _scroll.animateTo(
        0,
        duration: AbTokens.motionDefault,
        curve: Curves.easeOutCubic,
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
      // `isMobilePlatform` first is load-bearing: desktop short-circuits
      // before touching the first-run chain (its checklist lives on the New
      // Session canvas instead).
      final showChecklist =
          isMobilePlatform && ref.watch(firstRunChecklistVisibleProvider);
      // "Describe a task below" is a lie while nothing is picked — Send stays
      // disabled without a valid target — so name the actual next step.
      final hasTarget = ref.watch(newSessionHasValidTargetProvider);
      // A scrollable empty state so the ancestor RefreshIndicator (in
      // new_session_content.dart) always has a gesture target: AbEmptyState
      // is a bare Center with no Scrollable of its own, so pull-to-refresh
      // would be inert here without this wrapper.
      return CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // Mounted in this branch too: the first session a user ever starts
          // is started from an empty list, which is exactly when an
          // unaccounted-for 30s wait is least explicable.
          const SliverToBoxAdapter(child: StartingSessionRow()),
          SliverFillRemaining(
            hasScrollBody: false,
            child: showChecklist
                ? const MobileFirstRunChecklist()
                : AbEmptyState(
                    title: 'No recent sessions',
                    subtitle: hasTarget
                        ? 'Describe a task below to start your first session.'
                        : 'Pick a project, then describe a task below.',
                  ),
          ),
        ],
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

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (widget.showHeader)
          const SliverToBoxAdapter(child: _SessionsHeader()),
        // Above the groups, not inside one: the session does not exist yet, so
        // it belongs to no machine, project or status bucket.
        const SliverToBoxAdapter(child: StartingSessionRow()),
        for (var i = 0; i < groups.length; i++) ...[
          SliverToBoxAdapter(
            child: _GroupHeader(
              label: groups[i].label,
              count: groups[i].rows.length,
              machineUuid: groups[i].machineUuid,
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, rowIndex) {
              final row = groups[i].rows[rowIndex];
              return RecentSessionRowWidget(
                key: ValueKey('${row.origin.registrationId}:${row.session.id}'),
                row: row,
              );
            }, childCount: groups[i].rows.length),
          ),
          if (i < groups.length - 1)
            const SliverToBoxAdapter(child: SizedBox(height: AbTokens.space8)),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: AbTokens.space16)),
      ],
    );
  }
}

List<_SessionGroup> _groupSessions(
  List<RecentSessionRow> rows,
  RecentGroupBy groupBy,
  Map<RecentSessionRow, AgentWorkStatus> statusFor,
) {
  // Bucket by a STABLE identity (machineUuid / registrationId), never by a
  // user-facing display string — two different machines or projects can
  // share the same display name, and keying on the name would silently merge
  // their sessions into one group.
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
        key = row.origin.registrationId;
        label = row.origin.projectName;
      case RecentGroupBy.status:
        final s = statusFor[row] ?? AgentWorkStatus.done;
        key = s.name;
        label = workStatusLabel(s);
    }
    buckets.putIfAbsent(key, () => []).add(row);
    labels[key] = label;
  }

  final keys = groupBy == RecentGroupBy.status
      ? [
          for (final s in kWorkStatusOrder) s.name,
        ].where(buckets.containsKey).toList()
      : (buckets.keys.toList()..sort(
          (a, b) =>
              labels[a]!.toLowerCase().compareTo(labels[b]!.toLowerCase()),
        ));

  return [
    for (final key in keys)
      _SessionGroup(
        label: labels[key]!,
        rows: buckets[key]!,
        // Machine-grouped bucket keys ARE the machineUuid (or 'local'); a
        // remote group's rows all share one machineUuid, so the first row's
        // origin gives it directly.
        machineUuid: groupBy == RecentGroupBy.machine
            ? buckets[key]!.first.origin.machineUuid
            : null,
      ),
  ];
}

/// The title, group-by chips, and summary badges, scrolling with the list.
///
/// Mounted only where the canvas has no fixed top bar of its own carrying the
/// same arrangement — which is a real wide mouse desktop, and is decided by
/// [RecentSessionsTab.showHeader] rather than re-derived here: see that field.
class _SessionsHeader extends StatelessWidget {
  const _SessionsHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        AbTokens.space8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RecentSessionsTitle(),
                ),
              ),
              SizedBox(width: AbTokens.space10),
              RecentGroupByChips(),
              SizedBox(width: AbTokens.space10),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: RecentSessionsSummaryBadges(),
                ),
              ),
            ],
          ),
          SizedBox(height: AbTokens.space8),
          AbSeparator.horizontal(),
        ],
      ),
    );
  }
}

/// Uppercase mono section rule for a machine / project / status group:
/// `LABEL · N ────────`. The trailing hairline anchors the group the way
/// panel headers do elsewhere, so groups scan as sections rather than a
/// stray dim line floating between rows.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.count,
    this.machineUuid,
  });

  final String label;
  final int count;

  /// Non-null only for a remote machine group under Machine grouping — shows
  /// a "Connecting…" indicator while that machine's socket is mid-handshake.
  final String? machineUuid;

  @override
  Widget build(BuildContext context) {
    return AbSectionHeader(
      label: label,
      count: count,
      // Mono: this label is a machine or project NAME, not a category word.
      mono: true,
      rule: true,
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        AbTokens.space4,
      ),
      trailing: machineUuid == null
          ? null
          : _ConnectingIndicator(machineUuid: machineUuid!),
    );
  }
}

/// Ladder pill shown next to a machine's group header while its control-plane
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

    // A block is sticky until the user or an out-of-band event clears it, so it
    // gets neither the pulse nor the trailing ellipsis that say "still working".
    final inProgress = status is Climbing;
    final (tone, label) = connectionDisplayInfo(status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbStatusDot(tone: tone, size: AbDotSize.sm, pulse: inProgress),
        const SizedBox(width: AbTokens.space6),
        Text(
          inProgress ? '$label…' : label,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            // AbStatusTone.disabled resolves to iconMuted (3:1, dot-tier) —
            // too dim for this label, which is body text. Every other tone
            // here is already a text-safe semantic color.
            color: tone == AbStatusTone.disabled
                ? context.antgrid.textMuted
                : tone.color(context),
          ),
        ),
      ],
    );
  }
}
