import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_work_status.dart';
import '../models/drawer_entry.dart';
import '../models/memory.dart';
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
import '../utils/platform_utils.dart';
import 'drawer_entry_row.dart'
    show DrawerAttentionDot, DrawerProjectRow, DrawerRemoveButton;
import 'memory/memory_project_button.dart';
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

/// A section title in the sidebar ("Projects", "Needs you"), optionally
/// counted and tinted, with room for one trailing control.
class SidebarSectionHeader extends StatelessWidget {
  const SidebarSectionHeader({
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
    final t = CarbonTheme.of(context);
    final scope = CarbonSideNavScope.of(context);
    final text = count == null ? label : '$label · $count';
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: scope.inset,
        end: scope.endInset,
      ),
      // A full target tall, so on touch a 44pt trailing button sets the
      // header's height and on desktop the header is one compact row.
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: t.minTarget),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.typography.heading.copyWith(
                    color: color ?? t.colors.textPrimary,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
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
        SidebarSectionHeader(
          label: 'Needs you',
          count: items.length,
          color: CarbonTheme.of(context).colors.supportWarning,
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
        const CarbonSideNavDivider(),
      ],
    );
  }
}

class _NeedsYouRow extends ConsumerWidget {
  const _NeedsYouRow({super.key, required this.item});

  final NeedsYouItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CarbonTheme.of(context);
    final asking = item.status == AgentWorkStatus.attention;
    return CarbonSideNavLink(
      label:
          '${asking ? 'Needs you' : 'Failed'}: ${item.row.session.name}, '
          '${item.machineName}, ${item.projectName}',
      leading: ExcludeSemantics(child: DrawerAttentionDot(status: item.status)),
      content: Row(
        children: [
          Flexible(
            child: Text(
              item.row.session.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: CarbonSpacing.spacing03),
          Flexible(
            child: Text(
              '${item.machineName} · ${item.projectName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.typography.helper.copyWith(color: t.colors.textHelper),
            ),
          ),
        ],
      ),
      onPressed: () {
        // The container, not `ref`: opening a session switches projects,
        // which rebuilds this row away mid-activation.
        final container = ref.container;
        detached(
          'NeedsYouRow',
          'open failed',
          () => openRecentSession(context, container, item.row),
        );
      },
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
  bool _latched = false;

  // Marks come and go ahead of the action cell, and a positional rebuild would
  // remount an action and drop its menu's open state.
  final _removeKey = GlobalKey();

  void _setLatched(bool v) {
    if (!mounted || _latched == v) return;
    setState(() => _latched = v);
  }

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
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
    // Removal is of the LOCAL copy only: the remote ones belong to their
    // machines, and forgetting a machine lives in the scope menu. Offered only
    // for a project with no sessions on any copy, in scope or not: an empty
    // local copy of a repo in use on another machine still reads, in this
    // merged row, as in use.
    final removable = localCopy == null || view.hasSessionsAnywhere
        ? null
        : LocalProjectEntry(localCopy);
    final offersRemove =
        removable != null && DrawerRemoveButton.offersFor(ref, removable);
    final multiMachine = view.group.members.length > 1;
    final machineTags = expanded && multiMachine
        ? ref.watch(machineShortTagsProvider)
        : const <String, String>{};
    final helper = t.typography.helper.copyWith(color: t.colors.textHelper);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DrawerProjectRow(
          name: view.group.name,
          spokenName: _rowLabel(view),
          expanded: expanded,
          warm: warm,
          dimmed: view.allOffline,
          onToggle: () => ref
              .read(projectGroupExpansionProvider.notifier)
              .toggle(key, byDefault: openByDefault),
          marks: [
            // Collapsed, the session rows that would carry the call to action
            // are off screen, so the row carries it.
            if (!expanded && view.needsYouCount > 0)
              const DrawerAttentionDot(status: AgentWorkStatus.attention),
            if (view.liveCount > 0) Text('${view.liveCount} live', style: helper),
            if (view.allOffline) Text('offline', style: helper),
          ],
          actions: [
            ?_memoryButton(view, localId),
            if (offersRemove)
              DrawerRemoveButton(
                key: _removeKey,
                entry: removable,
                onLatch: _setLatched,
              ),
          ],
          keepActionsRevealed: _latched,
        ),
        if (expanded)
          CarbonSideNavScope.nested(
            context: context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
            ),
          ),
      ],
    );
  }

  /// Memory is per machine, so a project merged across machines opens the
  /// copy on this one when there is one, and otherwise its only copy.
  ///
  /// None on touch: a row's actions show at rest there, with no hover to hold
  /// them back, so every project would repeat the Memory nav item's lightbulb.
  static Widget? _memoryButton(ProjectView view, String? localId) {
    if (isMobilePlatform) return null;
    if (localId != null) {
      return MemoryProjectButton(
        target: const MemoryTarget.machine(),
        projectId: localId,
        projectName: view.group.name,
      );
    }
    if (view.members.length != 1) return null;
    final only = view.members.single;
    return MemoryProjectButton(
      target: MemoryTarget.machine(machineId: only.machineId),
      projectId: only.projectId,
      projectName: view.group.name,
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
    final t = CarbonTheme.of(context);
    final scope = CarbonSideNavScope.of(context);
    // A phone holds one machine, so there is no wider scope to offer.
    final oneMachine = ref.watch(mobileConnectEnabledProvider);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        scope.inset,
        CarbonSpacing.spacing02,
        scope.endInset,
        CarbonSpacing.spacing03,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            oneMachine
                ? 'No projects on this machine.'
                : 'No projects on the machines in scope.',
            style: t.typography.helper.copyWith(color: t.colors.textHelper),
          ),
          if (!oneMachine) ...[
            const SizedBox(height: CarbonSpacing.spacing03),
            CarbonButton(
              label: 'Show all machines',
              kind: CarbonButtonKind.tertiary,
              size: CarbonButtonSize.small,
              onPressed: () => ref
                  .read(machineScopeProvider.notifier)
                  .selectAll([
                    for (final m in ref.read(machineDirectoryProvider)) m.id,
                  ]),
            ),
          ],
        ],
      ),
    );
  }
}
