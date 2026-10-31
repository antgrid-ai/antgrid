import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/agent_work_status.dart';
import '../../models/project_catalog.dart';
import '../../models/recent_session_row.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/machine_capability_card.dart';
import '../../providers/machine_directory.dart';
import '../../providers/machine_scope.dart';
import '../../providers/project_index.dart';
import '../../providers/project_panel.dart';
import '../../providers/project_work_status.dart';
import '../../providers/recent_sessions.dart';
import '../../util/detached.dart';
import '../../util/relative_time.dart';
import '../recent_sessions/recent_session_row_widget.dart';
import '../recent_sessions/recent_sessions_summary.dart' show RecentGroupBy;
import '../recent_sessions/starting_session_row.dart';

/// One project, merged across machines, in place of the Recent list on the New
/// Session canvas: who holds it, what is waiting, what is running.
class ProjectPanelView extends ConsumerWidget {
  const ProjectPanelView({super.key, required this.view});

  final ProjectView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!view.inScope) return _OutOfScope(view: view);

    final filter = ref.watch(projectMachineFilterProvider);
    final cards = machineCardsFor(view);
    // A filter naming a machine that has since left scope (or the project)
    // would empty the list for no visible reason; it lapses instead.
    final activeFilter = cards.any((c) => c.machine.id == filter)
        ? filter
        : null;
    final statuses = ref.watch(recentSessionStatusesProvider);
    AgentWorkStatus statusOf(RecentSessionRow r) =>
        statuses[recentStatusKey(r.origin.registrationId, r.session.id)] ??
        AgentWorkStatus.done;
    final catalog = ref.watch(agentCatalogProvider);
    final rows = [
      for (final r in view.sessions)
        if (activeFilter == null || machineIdOf(r.origin) == activeFilter) r,
    ];
    final grouping = ref.watch(projectGroupingProvider);
    final groups = groupProjectSessions(
      rows: rows,
      by: grouping,
      statusOf: statusOf,
      machines: view.machines,
      agentOf: (r) {
        final key = r.session.agentKey ?? r.session.tool;
        if (key == null) return 'Default agent';
        return catalog[key]?.label ?? key;
      },
    );

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: _Header(view: view, grouping: grouping)),
        SliverToBoxAdapter(
          child: _MachineCards(cards: cards, activeFilter: activeFilter),
        ),
        const SliverToBoxAdapter(child: StartingSessionRow()),
        if (groups.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: AbEmptyState(
              title: 'No sessions here yet',
              subtitle: 'Describe a task below to start one.',
            ),
          ),
        for (final g in groups) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                0,
                AbTokens.space12,
                0,
                AbTokens.space6,
              ),
              child: AbSectionHeader(
                label: g.label,
                count: g.rows.length,
                rule: true,
                mono: grouping == SessionGrouping.machine,
                color: g.bucket == SessionBucket.needsYou
                    ? context.antgrid.warning
                    : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space16,
                ),
              ),
            ),
          ),
          SliverList.list(
            children: [
              for (final r in g.rows)
                _PanelRow(
                  key: ValueKey(
                    recentStatusKey(r.origin.registrationId, r.session.id),
                  ),
                  row: r,
                  needsYou: sessionBucket(statusOf(r)) == SessionBucket.needsYou,
                ),
            ],
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: AbTokens.space16)),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.view, required this.grouping});

  final ProjectView view;
  final SessionGrouping grouping;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void pick(SessionGrouping g) =>
        ref.read(projectGroupingProvider.notifier).set(g);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space8,
        AbTokens.space12,
        AbTokens.space16,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AbIconButton(
                icon: AbIcons.chevronLeft,
                tooltip: 'All sessions',
                onTap: () => closeProjectPanel(ref.container),
              ),
              const SizedBox(width: AbTokens.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      view.group.name,
                      overflow: TextOverflow.ellipsis,
                      style: AbTokens.monoStyle(
                        fontWeight: FontWeight.w600,
                        color: context.antgrid.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AbTokens.space2),
                    Text(
                      projectSummaryLine(view),
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontSm,
                        color: context.antgrid.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                container: true,
                label: 'Group by',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (g, label) in const [
                      (SessionGrouping.status, 'Status'),
                      (SessionGrouping.machine, 'Machine'),
                      (SessionGrouping.agent, 'Agent'),
                    ]) ...[
                      if (g != SessionGrouping.status)
                        const SizedBox(width: AbTokens.space6),
                      AbChip.toggle(
                        label: label,
                        selected: grouping == g,
                        onTap: () => pick(g),
                        color: grouping == g ? context.antgrid.accent : null,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AbTokens.space12),
          const AbSeparator.horizontal(),
        ],
      ),
    );
  }
}

class _MachineCards extends ConsumerWidget {
  const _MachineCards({required this.cards, required this.activeFilter});

  final List<MachineCardInfo> cards;
  final String? activeFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filtered = activeFilter == null
        ? null
        : cards.where((c) => c.machine.id == activeFilter).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space12,
        AbTokens.space16,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AbTokens.space8,
            runSpacing: AbTokens.space8,
            children: [
              for (final c in cards)
                _MachineCard(
                  key: ValueKey(c.machine.id),
                  card: c,
                  selected: c.machine.id == activeFilter,
                ),
            ],
          ),
          if (filtered != null) ...[
            const SizedBox(height: AbTokens.space8),
            Row(
              children: [
                Flexible(
                  child: Text(
                    'Only ${filtered.machine.name}',
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: context.antgrid.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: AbTokens.space8),
                AbButton(
                  label: 'Show all',
                  compact: true,
                  onTap: () => ref
                      .read(projectMachineFilterProvider.notifier)
                      .set(null),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One machine holding the project: state, branch, isolated checkouts and
/// sessions. Tapping narrows the list to it; tapping again clears that.
class _MachineCard extends ConsumerStatefulWidget {
  const _MachineCard({super.key, required this.card, required this.selected});

  final MachineCardInfo card;
  final bool selected;

  @override
  ConsumerState<_MachineCard> createState() => _MachineCardState();
}

class _MachineCardState extends ConsumerState<_MachineCard> {
  // Wide enough for a machine name and a branch side by side, and no wider:
  // the cards wrap, and one long branch must not take a whole row.
  static const double _minWidth = 180;
  static const double _maxWidth = 260;

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    final m = c.machine;
    final p = context.antgrid;
    final branch = watchMachineBranch(ref, m, c.member.projectId);
    final state = m.online
        ? 'Online'
        : 'Offline${m.lastSeenAt == null ? '' : ' · seen ${relativeTime(m.lastSeenAt!)}'}';
    final detail = [
      ?branch,
      if (c.worktreeCount > 0)
        '${c.worktreeCount} worktree${c.worktreeCount == 1 ? '' : 's'}',
    ].join(' · ');
    return Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${m.name}, $state, ${c.sessionCount} sessions'
          '${detail.isEmpty ? '' : ', $detail'}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ref
              .read(projectMachineFilterProvider.notifier)
              .set(widget.selected ? null : m.id),
          child: Container(
            constraints: const BoxConstraints(
              minWidth: _minWidth,
              maxWidth: _maxWidth,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space10,
              vertical: AbTokens.space8,
            ),
            decoration: BoxDecoration(
              color: widget.selected
                  ? p.bgSelected
                  : (_hovered ? p.bgHover : null),
              border: Border.all(
                color: widget.selected ? p.accentMuted : p.borderDefault,
              ),
              borderRadius: AbTokens.borderRadius5,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AbStatusDot(
                      tone: m.online
                          ? AbStatusTone.success
                          : AbStatusTone.disabled,
                      style: m.online ? AbDotStyle.filled : AbDotStyle.hollow,
                    ),
                    const SizedBox(width: AbTokens.space8),
                    Flexible(
                      child: Text(
                        m.name,
                        overflow: TextOverflow.ellipsis,
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontSm,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AbTokens.space8),
                    Text(
                      '${c.sessionCount}',
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontXxs,
                        color: p.textMuted,
                      ),
                    ),
                  ],
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: AbTokens.space4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AbIcon(
                        AbIcons.gitBranch,
                        size: AbTokens.fontXs,
                        color: p.textMuted,
                      ),
                      const SizedBox(width: AbTokens.space4),
                      Flexible(
                        child: Text(
                          detail,
                          overflow: TextOverflow.ellipsis,
                          style: AbTokens.monoStyle(
                            fontSize: AbTokens.fontXs,
                            color: p.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AbTokens.space2),
                Text(
                  '$state${m.isLocal ? ' · this machine' : ''}',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXxs,
                    color: p.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The branch [machine]'s copy of [projectId] is on, from its Capability Card.
/// Asked only of a machine that is up: the card is an RPC, and for a remote
/// machine it rides that machine's control plane.
String? watchMachineBranch(
  WidgetRef ref,
  MachineInfo machine,
  String projectId,
) {
  if (!machine.online) return null;
  final card = machine.id == kLocalMachineKey
      ? ref.watch(localCapabilityCardProvider(projectId)).value
      : ref.watch(machineCapabilityCardProvider(machine.id)).value;
  return card?.projects[projectId]?.branch;
}

/// A Recent row, plus a Respond action on the ones waiting for the user.
class _PanelRow extends ConsumerWidget {
  const _PanelRow({super.key, required this.row, required this.needsYou});

  final RecentSessionRow row;
  final bool needsYou;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tile = RecentSessionRowWidget(
      row: row,
      groupedBy: RecentGroupBy.project,
    );
    if (!needsYou) return tile;
    return Row(
      children: [
        Expanded(child: tile),
        Padding(
          padding: const EdgeInsets.only(right: AbTokens.space16),
          child: AbButton(
            label: 'Respond',
            compact: true,
            variant: AbButtonVariant.primary,
            onTap: () {
              final container = ref.container;
              detached(
                'ProjectPanel',
                'respond failed',
                () => openRecentSession(context, container, row),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The project is known but the scope hides every machine holding it. Never a
/// blank panel: it says where the project is and offers the way back.
class _OutOfScope extends ConsumerWidget {
  const _OutOfScope({required this.view});

  final ProjectView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = [for (final m in view.hiddenMachines) m.name];
    final where = switch (names.length) {
      0 => 'no machine you can reach',
      1 => names.single,
      _ => '${names.take(names.length - 1).join(', ')} and ${names.last}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(view: view, grouping: ref.watch(projectGroupingProvider)),
        Expanded(
          child: AbEmptyState(
            icon: AbIcons.deviceDesktop,
            title: '${view.group.name} is outside your machine scope',
            subtitle: 'It lives on $where.',
            action: AbButton(
              label: 'Show all machines',
              variant: AbButtonVariant.primary,
              onTap: () => ref
                  .read(machineScopeProvider.notifier)
                  .selectAll([
                    for (final m in ref.read(machineDirectoryProvider)) m.id,
                  ]),
            ),
          ),
        ),
      ],
    );
  }
}
