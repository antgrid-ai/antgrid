import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/recent_session_row.dart';
import '../../providers/recent_sessions.dart';
import '../../providers/relay_connection.dart';
import '../ab_status_helpers.dart';
import 'recent_session_row_widget.dart';

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
      // A scrollable empty state so the ancestor RefreshIndicator (in
      // new_session_content.dart) always has a gesture target: AbEmptyState
      // is a bare Center with no Scrollable of its own, so pull-to-refresh
      // would be inert here without this wrapper.
      return const CustomScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: AbEmptyState(
              title: 'No recent sessions',
              subtitle: 'Describe a task below to start your first session.',
            ),
          ),
        ],
      );
    }

    final groups = _groupSessions(rows, _groupBy);
    final working = rows.where((r) => r.session.running).length;
    final done = rows.length - working;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _SessionsHeader(
            total: rows.length,
            working: working,
            done: done,
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
        key = row.session.running ? 'working' : 'done';
        label = key == 'working' ? 'Working' : 'Done';
    }
    buckets.putIfAbsent(key, () => []).add(row);
    labels[key] = label;
  }

  final keys = groupBy == _RecentGroupBy.status
      ? ['working', 'done'].where(buckets.containsKey).toList()
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

/// Title row, group-by filter chips, and running/done summary badges.
class _SessionsHeader extends StatelessWidget {
  const _SessionsHeader({
    required this.total,
    required this.working,
    required this.done,
    required this.groupBy,
    required this.onGroupBy,
  });

  final int total;
  final int working;
  final int done;
  final _RecentGroupBy groupBy;
  final ValueChanged<_RecentGroupBy> onGroupBy;

  @override
  Widget build(BuildContext context) {
    final t = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
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
                  child: Text(
                    'Sessions · $total total',
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontMd,
                      color: t.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AbTokens.space10),
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
              const SizedBox(width: AbTokens.space10),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (working > 0)
                        _SummaryBadge(
                          label: '$working working',
                          color: t.accent,
                          live: true,
                        ),
                      if (working > 0 && done > 0)
                        const SizedBox(width: AbTokens.space8),
                      if (done > 0)
                        _SummaryBadge(label: '$done done', color: t.textMuted),
                    ],
                  ),
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

class _SummaryBadge extends StatelessWidget {
  const _SummaryBadge({
    required this.label,
    required this.color,
    this.live = false,
  });

  final String label;
  final Color color;

  /// Prefix a pulsing activity dot — used for the "working" count so live
  /// activity registers at a glance without reading the numbers.
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live) ...[
          AbStatusDot(
            tone: AbStatusTone.info,
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
            color: color,
            fontWeight: FontWeight.w500,
          ),
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
    final t = context.antgrid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        AbTokens.space4,
      ),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXxs,
              color: t.textMuted,
              letterSpacing: 0.66,
            ),
          ),
          const SizedBox(width: AbTokens.space6),
          Text(
            '· $count',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXxs,
              color: t.textDisabled,
              letterSpacing: 0.66,
            ),
          ),
          if (machineUuid != null) ...[
            const SizedBox(width: AbTokens.space8),
            _ConnectingIndicator(machineUuid: machineUuid!),
          ],
          const SizedBox(width: AbTokens.space10),
          const Expanded(child: AbSeparator.horizontal()),
        ],
      ),
    );
  }
}

/// "Connecting…" pill shown next to a machine's group header while its
/// control-plane socket is mid-handshake. Reads [machineConnectionPhaseProvider]
/// (peek-only, never dials) — invisible once `paired` (the fresh row list
/// already communicates "connected") or when nothing has been dialed yet.
class _ConnectingIndicator extends ConsumerWidget {
  const _ConnectingIndicator({required this.machineUuid});

  final String machineUuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(machineConnectionPhaseProvider(machineUuid)).value;
    final connecting =
        phase != null &&
        phase != RelayConnectionState.paired &&
        phase != RelayConnectionState.disconnected;
    if (!connecting) return const SizedBox.shrink();

    final (tone, label) = connectionDisplayInfo(phase);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbStatusDot(tone: tone, size: AbDotSize.sm, pulse: true),
        const SizedBox(width: AbTokens.space6),
        Text(
          '$label…',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            color: context.antgrid.accent,
          ),
        ),
      ],
    );
  }
}
