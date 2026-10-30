import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_row_trailing.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/agent_work_status.dart';
import '../models/drawer_entry.dart';
import '../models/project_catalog.dart';
import '../project/project_session_registry.dart'
    show projectSessionRegistryProvider;
import '../providers/agent_transport.dart' show selectedRegistrationIdProvider;
import '../providers/machine_directory.dart';
import '../providers/machine_scope.dart';
import '../providers/project_index.dart';
import '../providers/project_work_status.dart' show recentStatusKey;
import '../providers/projects.dart';
import '../providers/recent_sessions.dart';
import '../util/detached.dart';
import 'drawer_entry_row.dart'
    show
        DrawerProjectLeading,
        DrawerRemoveButton,
        HoverableDrawerRow,
        drawerProjectTitleStyle;
import 'session_row.dart';

/// Which merged project rows are open in the sidebar, keyed by
/// [ProjectGroup.key]. Holds explicit choices only; a row the user never
/// touched is open while it holds the focused project or has a session running
/// or waiting, so the session on screen and anything asking for attention is
/// never folded away.
final projectGroupExpansionProvider =
    NotifierProvider<ProjectGroupExpansion, Map<String, bool>>(
      ProjectGroupExpansion.new,
    );

class ProjectGroupExpansion extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  bool isExpanded(String key, {required bool byDefault}) =>
      state[key] ?? byDefault;

  void toggle(String key, {required bool byDefault}) {
    state = {...state, key: !isExpanded(key, byDefault: byDefault)};
  }
}

/// Sessions waiting on the user across every machine in scope. Renders
/// nothing when there are none — an empty "needs you" is not news.
class NeedsYouSection extends ConsumerWidget {
  const NeedsYouSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(needsYouProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarSectionLabel(
          label: 'NEEDS YOU',
          count: items.length,
          color: context.antgrid.warning,
        ),
        for (final item in items)
          _NeedsYouRow(
            key: ValueKey(
              recentStatusKey(item.row.origin.registrationId, item.row.session.id),
            ),
            item: item,
          ),
        const SizedBox(height: AbTokens.space4),
      ],
    );
  }
}

/// The drawer's section label (the "PROJECTS" treatment), optionally counted
/// and tinted.
class SidebarSectionLabel extends StatelessWidget {
  const SidebarSectionLabel({
    super.key,
    required this.label,
    this.count,
    this.color,
    this.trailing,
  });

  final String label;
  final int? count;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = AbTokens.sansStyle(
      fontSize: AbTokens.fontXs,
      color: color ?? context.antgrid.textMuted,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.space10,
        AbTokens.drawerGutter,
        AbTokens.space6,
      ),
      child: Row(
        children: [
          Text(label, style: style),
          if (count != null) ...[
            const SizedBox(width: AbTokens.space6),
            Text('· $count', style: style.copyWith(letterSpacing: 0)),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _NeedsYouRow extends ConsumerWidget {
  const _NeedsYouRow({super.key, required this.item});

  final NeedsYouItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asking = item.status == AgentWorkStatus.attention;
    return Semantics(
      button: true,
      label:
          '${asking ? 'Needs you' : 'Failed'}: ${item.row.session.name}, '
          '${item.machineName}, ${item.projectName}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
        child: AbListRow(
          leadingGapOverride: AbTokens.drawerSessionLeadingGap,
          leading: SizedBox(
            width: AbTokens.drawerSessionLeadingSlot,
            child: AbStatusDot(
              tone: asking ? AbStatusTone.warning : AbStatusTone.danger,
              pulse: asking,
            ),
          ),
          title: Text(
            item.row.session.name,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
              color: context.antgrid.textPrimary,
            ),
          ),
          subtitle: Text(
            '${item.machineName} · ${item.projectName}',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXxs,
              color: context.antgrid.textMuted,
            ),
          ),
          density: AbRowDensity.sm,
          horizontalPadding: AbTokens.space6,
          hoverable: true,
          margin: const EdgeInsets.symmetric(vertical: 1),
          onTap: () {
            // The container, not `ref`: opening a session switches projects,
            // which rebuilds this row away mid-activation.
            final container = ref.container;
            detached(
              'NeedsYouRow',
              'open failed',
              () => openRecentSession(context, container, item.row),
            );
          },
        ),
      ),
    );
  }
}

/// One project merged across machines, and — while open — its sessions.
class ProjectGroupRow extends ConsumerStatefulWidget {
  const ProjectGroupRow({super.key, required this.view});

  final ProjectView view;

  @override
  ConsumerState<ProjectGroupRow> createState() => _ProjectGroupRowState();
}

class _ProjectGroupRowState extends ConsumerState<ProjectGroupRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final key = view.group.key;
    final focusedEntry = ref.watch(selectedRegistrationIdProvider);
    final holdsFocus =
        focusedEntry != null && view.members.any((m) => m.entryId == focusedEntry);
    final openByDefault =
        holdsFocus || view.liveCount > 0 || view.needsYouCount > 0;
    ref.watch(projectGroupExpansionProvider);
    final expanded = ref
        .read(projectGroupExpansionProvider.notifier)
        .isExpanded(key, byDefault: openByDefault);
    final warm = ref.watch(
      projectSessionRegistryProvider.select(
        (open) => view.members.any((m) => open.contains(m.entryId)),
      ),
    );
    final localCopy = ref.watch(
      projectsProvider.select((ps) {
        for (final p in ps) {
          for (final m in view.members) {
            if (m.machineId == kLocalMachineKey && m.entryId == p.projectId) {
              return p;
            }
          }
        }
        return null;
      }),
    );
    final multiMachine = view.group.members.length > 1;
    final machineNames = {
      for (final m in ref.watch(machineDirectoryProvider)) m.id: m.name,
    };
    final p = context.antgrid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HoverableDrawerRow(
          builder: (context, hovered, pointerOver) {
            final cells = <Widget>[
              if (!expanded && view.needsYouCount > 0)
                const AbStatusDot(tone: AbStatusTone.warning),
              if (view.liveCount > 0)
                Text(
                  '${view.liveCount} live',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textSecondary,
                  ),
                ),
              if (view.allOffline)
                Text(
                  'offline',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: p.textMuted,
                  ),
                ),
              // Removal is of the LOCAL copy only: the remote ones belong to
              // their machines, and forgetting a machine lives in the scope
              // menu.
              if ((hovered || _focused) &&
                  localCopy != null &&
                  DrawerRemoveButton.offersFor(ref, LocalProjectEntry(localCopy)))
                DrawerRemoveButton(entry: LocalProjectEntry(localCopy)),
            ];
            // Whatever ends up outermost takes the rail cell, so this row's
            // last glyph lines up with every other row's.
            if (cells.isNotEmpty) {
              cells.last = AbRowTrailingCell(child: cells.last);
            }
            return Semantics(
              label: _rowLabel(view),
              expanded: expanded,
              child: AbListRow(
                horizontalPadding: 0,
                density: AbRowDensity.sm,
                contentFloor: AbRowContentFloor.iconButton,
                leading: DrawerProjectLeading(
                  expanded: expanded,
                  pointerOver: pointerOver,
                  warm: warm,
                ),
                title: Text(
                  view.group.name,
                  overflow: TextOverflow.ellipsis,
                  style: view.allOffline
                      ? drawerProjectTitleStyle(context).copyWith(color: p.textMuted)
                      : drawerProjectTitleStyle(context),
                ),
                trailing: AbRowTrailingCell.kit(cells),
                margin: const EdgeInsets.symmetric(vertical: AbTokens.space2),
                onFocusChange: (v) => setState(() => _focused = v),
                onTap: () => ref
                    .read(projectGroupExpansionProvider.notifier)
                    .toggle(key, byDefault: openByDefault),
              ),
            );
          },
        ),
        if (expanded)
          for (final r in view.sessions)
            SessionRow(
              key: ValueKey(recentStatusKey(r.origin.registrationId, r.session.id)),
              entryId: r.origin.registrationId,
              session: r.session,
              machineTag: multiMachine
                  ? machineNames[machineIdOf(r.origin)] ?? r.origin.deviceName
                  : null,
            ),
      ],
    );
  }

  String _rowLabel(ProjectView view) {
    final parts = [
      view.group.name,
      'on ${view.machines.length} machine${view.machines.length == 1 ? '' : 's'}',
      if (view.liveCount > 0) '${view.liveCount} running',
      if (view.needsYouCount > 0) '${view.needsYouCount} need you',
      if (view.allOffline) 'offline',
    ];
    return parts.join(', ');
  }
}

/// Shown in place of the project list when projects exist but the scope hides
/// every machine holding them.
class ScopeHidesEverything extends ConsumerWidget {
  const ScopeHidesEverything({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.space4,
        AbTokens.drawerGutter,
        AbTokens.space8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No projects on the machines in scope.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
            ),
          ),
          const SizedBox(height: AbTokens.space8),
          AbButton(
            label: 'Show all machines',
            compact: true,
            onTap: () => ref
                .read(machineScopeProvider.notifier)
                .selectAll([
                  for (final m in ref.read(machineDirectoryProvider)) m.id,
                ]),
          ),
        ],
      ),
    );
  }
}
