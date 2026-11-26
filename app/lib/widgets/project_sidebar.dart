import 'package:collection/collection.dart';
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
import '../providers/mobile_connection.dart';
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

  void toggle(String key, {required bool byDefault}) {
    state = {...state, key: !(state[key] ?? byDefault)};
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
              recentStatusKey(
                item.row.origin.registrationId,
                item.row.session.id,
              ),
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
    final holdsFocus = ref.watch(
      selectedRegistrationIdProvider.select(
        (id) => id != null && view.members.any((m) => m.entryId == id),
      ),
    );
    final openByDefault =
        holdsFocus || view.liveCount > 0 || view.needsYouCount > 0;
    final expanded =
        ref.watch(projectGroupExpansionProvider.select((s) => s[key])) ??
        openByDefault;
    final warm = ref.watch(
      projectSessionRegistryProvider.select(
        (open) => view.members.any((m) => open.contains(m.entryId)),
      ),
    );
    final localId = view.members
        .firstWhereOrNull((m) => m.machineId == kLocalMachineKey)
        ?.projectId;
    final localCopy = localId == null
        ? null
        : ref.watch(
            projectsProvider.select(
              (ps) => ps.firstWhereOrNull((p) => p.projectId == localId),
            ),
          );
    final multiMachine = view.group.members.length > 1;
    final machineTags = expanded && multiMachine
        ? ref.watch(machineShortTagsProvider)
        : const <String, String>{};
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
              // menu. Offered only for a project with no sessions on any copy,
              // in scope or not: an empty local copy of a repo in use on
              // another machine still reads, in this merged row, as in use.
              if ((hovered || _focused) &&
                  localCopy != null &&
                  !view.hasSessionsAnywhere &&
                  DrawerRemoveButton.offersFor(
                    ref,
                    LocalProjectEntry(localCopy),
                  ))
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
                      ? drawerProjectTitleStyle(
                          context,
                        ).copyWith(color: p.textMuted)
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
              key: ValueKey(
                recentStatusKey(r.origin.registrationId, r.session.id),
              ),
              entryId: r.origin.registrationId,
              session: r.session,
              machineTag: multiMachine
                  ? machineTags[machineIdOf(r.origin)] ??
                        shortMachineTag(r.origin.deviceName)
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

final _nameWords = RegExp(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+');

/// Two letters for a machine name, short enough to sit in a session row's
/// trailing cell: the initials of its first two words ("MacBook Pro" → "MB",
/// camel case splits), else its first two letters.
String shortMachineTag(String name) {
  final words = _nameWords.allMatches(name).map((m) => m.group(0)!).toList();
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
  final letters = words.isEmpty ? name.trim() : words.first;
  if (letters.isEmpty) return '?';
  return letters.substring(0, letters.length < 2 ? 1 : 2).toUpperCase();
}

/// [machineShortTags] over the machine directory, computed once per change to
/// it rather than once per project row.
final machineShortTagsProvider = Provider<Map<String, String>>(
  (ref) => machineShortTags(ref.watch(machineDirectoryProvider)),
);

/// [shortMachineTag] for every machine, numbered where two would read the
/// same — a tag that cannot tell two machines apart is worse than none.
Map<String, String> machineShortTags(List<MachineInfo> machines) {
  final counts = <String, int>{};
  for (final m in machines) {
    final tag = shortMachineTag(m.name);
    counts[tag] = (counts[tag] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return {
    for (final m in machines)
      m.id: () {
        final tag = shortMachineTag(m.name);
        if (counts[tag] == 1) return tag;
        final n = (seen[tag] ?? 0) + 1;
        seen[tag] = n;
        return '${tag[0]}$n';
      }(),
  };
}

/// Shown in place of the project list when projects exist but the scope hides
/// every machine holding them.
class ScopeHidesEverything extends ConsumerWidget {
  const ScopeHidesEverything({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A phone holds one machine, so there is no wider scope to offer.
    final oneMachine = ref.watch(mobileConnectEnabledProvider);
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
            oneMachine
                ? 'No projects on this machine.'
                : 'No projects on the machines in scope.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
            ),
          ),
          if (!oneMachine) ...[
            const SizedBox(height: AbTokens.space8),
            AbButton(
              label: 'Show all machines',
              compact: true,
              onTap: () => ref.read(machineScopeProvider.notifier).selectAll([
                for (final m in ref.read(machineDirectoryProvider)) m.id,
              ]),
            ),
          ],
        ],
      ),
    );
  }
}
