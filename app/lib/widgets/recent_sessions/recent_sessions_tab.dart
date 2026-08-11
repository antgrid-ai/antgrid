import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connection/supervisor_state.dart';
import '../../constants/breakpoints.dart';
import '../../design/ab_colors.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
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
import '../../utils/platform_utils.dart';
import '../ab_status_helpers.dart';
import '../new_session/first_run_checklist.dart';
import 'recent_session_row_widget.dart';
import 'recent_sessions_summary.dart';

enum _RecentGroupBy { machine, project, status }

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
  const RecentSessionsTab({super.key});

  @override
  ConsumerState<RecentSessionsTab> createState() => _RecentSessionsTabState();
}

class _RecentSessionsTabState extends ConsumerState<RecentSessionsTab> {
  _RecentGroupBy _groupBy = _RecentGroupBy.machine;

  @override
  Widget build(BuildContext context) {
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
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
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

    final groups = _groupSessions(rows, _groupBy, statusFor);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _SessionsHeader(
            groupBy: _groupBy,
            onGroupBy: (g) => setState(() => _groupBy = g),
          ),
        ),
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
  _RecentGroupBy groupBy,
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
      case _RecentGroupBy.machine:
        key = row.origin.machineUuid ?? 'local';
        label = row.origin.deviceName;
      case _RecentGroupBy.project:
        key = row.origin.registrationId;
        label = row.origin.projectName;
      case _RecentGroupBy.status:
        final s = statusFor[row] ?? AgentWorkStatus.done;
        key = s.name;
        label = workStatusLabel(s);
    }
    buckets.putIfAbsent(key, () => []).add(row);
    labels[key] = label;
  }

  final keys = groupBy == _RecentGroupBy.status
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
        machineUuid: groupBy == _RecentGroupBy.machine
            ? buckets[key]!.first.origin.machineUuid
            : null,
      ),
  ];
}

/// Group-by filter chips, plus (on desktop only) the title and summary badges.
///
/// On mobile those two live in the canvas's top bar instead
/// ([RecentSessionsSummaryLine]) — sharing the drawer button's row rather than
/// spending one of their own, and staying put while the list scrolls.
class _SessionsHeader extends StatelessWidget {
  const _SessionsHeader({required this.groupBy, required this.onGroupBy});

  final _RecentGroupBy groupBy;
  final ValueChanged<_RecentGroupBy> onGroupBy;

  @override
  Widget build(BuildContext context) {
    final chips = [
      _GroupChip(
        label: 'Machine',
        selected: groupBy == _RecentGroupBy.machine,
        onTap: () => onGroupBy(_RecentGroupBy.machine),
      ),
      const SizedBox(width: AbTokens.space6),
      _GroupChip(
        label: 'Project',
        selected: groupBy == _RecentGroupBy.project,
        onTap: () => onGroupBy(_RecentGroupBy.project),
      ),
      const SizedBox(width: AbTokens.space6),
      _GroupChip(
        label: 'Status',
        selected: groupBy == _RecentGroupBy.status,
        onTap: () => onGroupBy(_RecentGroupBy.status),
      ),
    ];

    final isNarrow = MediaQuery.sizeOf(context).width < kCompactBreakpoint;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AbTokens.space16,
        isNarrow ? AbTokens.space4 : AbTokens.space12,
        AbTokens.space16,
        AbTokens.space8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isNarrow)
            // No search here: on mobile it is an icon in the canvas's top bar
            // (see SessionSearchButton), which stays put while this list
            // scrolls and costs the list no row of its own.
            Row(mainAxisAlignment: MainAxisAlignment.end, children: chips)
          else
            Row(
              children: [
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: RecentSessionsTitle(),
                  ),
                ),
                const SizedBox(width: AbTokens.space10),
                ...chips,
                const SizedBox(width: AbTokens.space10),
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: RecentSessionsSummaryBadges(),
                  ),
                ),
              ],
            ),
          const SizedBox(height: AbTokens.space8),
          const AbSeparator.horizontal(),
        ],
      ),
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

