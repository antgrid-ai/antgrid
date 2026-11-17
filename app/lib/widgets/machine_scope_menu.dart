import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_work_status.dart';
import '../models/drawer_entry.dart';
import '../models/recent_session_row.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/drawer_entries.dart';
import '../providers/machine_directory.dart';
import '../providers/machine_scope.dart';
import '../providers/project_index.dart';
import '../providers/project_work_status.dart';
import '../providers/recent_sessions.dart';
import '../providers/agent_transport.dart' show selectedTargetProvider;
import '../providers/ui_attention_providers.dart';
import '../util/detached.dart';
import '../util/relative_time.dart';
import 'drawer_entry_row.dart' show confirmRemoveDrawerEntry;
import 'machine_summary_tile.dart';

/// The sidebar's machine scope switcher: what the scope shows, and how much of
/// it is alive. Opens the scope menu ([machineScopeEntries]).
class MachineScopeButton extends ConsumerStatefulWidget {
  const MachineScopeButton({super.key});

  @override
  ConsumerState<MachineScopeButton> createState() => _MachineScopeButtonState();
}

class _MachineScopeButtonState extends ConsumerState<MachineScopeButton> {
  final _menu = CarbonPopupController();

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = CarbonSideNavScope.of(context);
    final machines = ref.watch(machineDirectoryProvider);
    final scope = ref.watch(machineScopeProvider);
    final inScope = ref.watch(scopedMachineIdsProvider);
    final online = machines.where((m) => inScope.contains(m.id) && m.online);
    final running = ref
        .watch(projectViewsProvider)
        .fold<int>(0, (n, v) => n + v.liveCount);
    final label = machineScopeLabel(machines, scope);
    final summary = '${online.length} online · $running running';
    final notifier = ref.read(machineScopeProvider.notifier);
    final container = ref.container;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        nav.inset,
        CarbonSpacing.spacing03,
        nav.endInset,
        CarbonSpacing.spacing02,
      ),
      child: CarbonMenu(
        controller: _menu,
        // Pinned at the sidebar's foot, so there is no room below.
        preferAbove: true,
        // Live, so ticking several machines does not reopen the menu each time,
        // and a machine coming online while it is open moves in place.
        closeOnToggle: false,
        minWidth: 260,
        semanticLabel: 'Machine scope',
        entries: machineScopeEntries(
          machines: machines,
          scope: scope,
          rows: ref.watch(recentSessionsProvider),
          statuses: ref.watch(recentSessionStatusesProvider),
          entries: ref.watch(drawerEntriesProvider),
          onToggle: (m) => notifier.toggle(m.id, online: m.online),
          onSelectAll: () =>
              notifier.selectAll([for (final m in machines) m.id]),
          onHideOffline: notifier.setHideOffline,
          onForget: (entry) => detached(
            'MachineScopeButton',
            'forget machine failed',
            () => confirmRemoveDrawerEntry(context, container, entry),
          ),
          onManage: () => openMachineManagement(container),
        ),
        child: MachineSummaryTile(
          leading: const CarbonIcon(CarbonIcons.screen),
          title: label,
          summary: summary,
          semanticLabel: 'Machine scope: $label, $summary',
          onPressed: _menu.toggle,
        ),
      ),
    );
  }
}

/// One check item per machine, then the scope-wide toggles.
///
/// A machine's status line rides the item's trailing text, and a machine whose
/// remote access is off carries the lock: both say what checking it would show.
/// Forgetting a remote machine is a submenu rather than an item per machine,
/// so the destructive action is never one slip from a checkbox.
List<CarbonMenuEntry> machineScopeEntries({
  required List<MachineInfo> machines,
  required MachineScope scope,
  required List<RecentSessionRow> rows,
  required Map<String, AgentWorkStatus> statuses,
  required List<DrawerEntry> entries,
  required ValueChanged<MachineInfo> onToggle,
  required VoidCallback onSelectAll,
  required ValueChanged<bool> onHideOffline,
  required ValueChanged<RemoteAgentEntry> onForget,
  required VoidCallback onManage,
}) {
  final forgettable = [
    for (final m in machines)
      if (entries.firstWhereOrNull((e) => e.machineUuid == m.id)
          case final RemoteAgentEntry e)
        e,
  ];
  return [
    CarbonMenuGroup(
      label: 'Machines',
      children: [
        for (final m in machines)
          CarbonMenuCheckItem(
            label: m.isLocal ? '${m.name} (this machine)' : m.name,
            checked: scope.isChecked(m.id, online: m.online),
            icon: m.remoteAccessEnabled == false
                ? const CarbonIcon(CarbonIcons.locked)
                : null,
            shortcut: [
              machineStatusLine(m, rows, statuses),
              if (m.remoteAccessEnabled == false) 'remote off',
            ].join(' · '),
            onChanged: (_) => onToggle(m),
          ),
      ],
    ),
    const CarbonMenuDivider(),
    CarbonMenuItem(label: 'Select all', onPressed: onSelectAll),
    CarbonMenuCheckItem(
      label: 'Hide offline machines',
      checked: scope.hideOffline,
      onChanged: onHideOffline,
    ),
    if (forgettable.isNotEmpty)
      CarbonMenuSubmenu(
        label: 'Forget machine',
        entries: [
          for (final e in forgettable)
            CarbonMenuItem(
              label: e.displayName,
              kind: CarbonMenuItemKind.danger,
              onPressed: () => onForget(e),
            ),
        ],
      ),
    CarbonMenuItem(
      label: 'Manage machines…',
      icon: const CarbonIcon(CarbonIcons.settings),
      onPressed: onManage,
    ),
  ];
}

/// The machine's state in a few words: "2 running", "Online · idle",
/// "Offline · seen 1 day ago".
///
/// Counts every session on the machine, in scope or not: the menu is where an
/// unchecked machine has to say what the user is missing.
String machineStatusLine(
  MachineInfo m,
  List<RecentSessionRow> rows,
  Map<String, AgentWorkStatus> statuses,
) {
  if (!m.online) {
    final seen = m.lastSeenAt;
    return seen == null ? 'Offline' : 'Offline · seen ${relativeTime(seen)}';
  }
  return machineActivityLine(m, rows, statuses) ?? 'Online · idle';
}

/// What is running on [m] and what waits on the user there, e.g.
/// "2 running · 1 needs you"; null when nothing is.
String? machineActivityLine(
  MachineInfo m,
  List<RecentSessionRow> rows,
  Map<String, AgentWorkStatus> statuses,
) {
  var running = 0;
  var needs = 0;
  for (final r in rows) {
    if (machineIdOf(r.origin) != m.id) continue;
    final status =
        statuses[recentStatusKey(r.origin.registrationId, r.session.id)];
    if (status == null) continue;
    switch (sessionBucket(status)) {
      case SessionBucket.running:
        running++;
      case SessionBucket.needsYou:
        needs++;
      case SessionBucket.done:
        break;
    }
  }
  final parts = [
    if (running > 0) '$running running',
    if (needs > 0) '$needs need${needs == 1 ? 's' : ''} you',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Where "Manage machines…" lands: the machine-level surface that owns this
/// machine's remote-access switch and the devices allowed to reach it.
void openMachineManagement(ProviderContainer container) {
  container
      .read(workbenchSurfaceProvider.notifier)
      .set(WorkbenchSurface.remoteDevices);
  container
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: container.read(selectedTargetProvider),
          surface: WorkbenchSurface.remoteDevices,
        ),
      );
}

