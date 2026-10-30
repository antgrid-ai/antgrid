import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_status_dot.dart';
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
import 'drawer_entry_row.dart' show DrawerRemoveButton;
import 'new_session/environment_menu.dart' show PanelRow, PanelSectionHeader;
import '../util/relative_time.dart';

/// The sidebar's machine scope switcher: what the scope shows, and how much of
/// it is alive. Opens [MachineScopePanel].
class MachineScopeButton extends ConsumerWidget {
  const MachineScopeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machineDirectoryProvider);
    final scope = ref.watch(machineScopeProvider);
    final inScope = ref.watch(scopedMachineIdsProvider);
    final online = machines.where((m) => inScope.contains(m.id) && m.online);
    final running = ref
        .watch(projectViewsProvider)
        .fold<int>(0, (n, v) => n + v.liveCount);
    final label = machineScopeLabel(machines, scope);
    final summary = '${online.length} online · $running running';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AbTokens.drawerGutter,
        AbTokens.space8,
        AbTokens.drawerGutter,
        AbTokens.space4,
      ),
      child: Builder(
        builder: (anchorContext) => Semantics(
          button: true,
          label: 'Machine scope: $label, $summary',
          excludeSemantics: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: context.antgrid.borderDefault),
              borderRadius: AbTokens.borderRadius5,
            ),
            child: AbListRow(
              leading: AbIcon(
                AbIcons.deviceDesktop,
                size: AbTokens.iconButtonGlyph,
                color: context.antgrid.textSecondary,
              ),
              title: Text(
                label,
                style: AbTokens.sansStyle(fontSize: AbTokens.fontMd),
              ),
              subtitle: Text(summary),
              trailing: AbIcon(
                AbIcons.chevronDown,
                size: AbTokens.fontSm,
                color: context.antgrid.textMuted,
              ),
              density: AbRowDensity.sm,
              horizontalPadding: AbTokens.space8,
              hoverable: true,
              onTap: () async {
                final anchor = abMenuAnchorRect(anchorContext);
                if (anchor == null) return;
                await showAbPanel<void>(
                  context: anchorContext,
                  anchorRect: anchor,
                  width: 300,
                  builder: (_) => const MachineScopePanel(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// One checkbox row per machine, then the scope-wide toggles. Live, so a
/// machine coming online while the menu is open moves without reopening it.
class MachineScopePanel extends ConsumerWidget {
  const MachineScopePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machineDirectoryProvider);
    final scope = ref.watch(machineScopeProvider);
    final rows = ref.watch(recentSessionsProvider);
    final statuses = ref.watch(recentSessionStatusesProvider);
    final entries = ref.watch(drawerEntriesProvider);
    final notifier = ref.read(machineScopeProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Machines'),
        for (final m in machines)
          _ScopeMachineRow(
            key: ValueKey(m.id),
            machine: m,
            checked: scope.isChecked(m.id, online: m.online),
            hiddenAsOffline: scope.hideOffline && !m.online,
            status: machineStatusLine(m, rows, statuses),
            entry: entries.firstWhereOrNull((e) => e.machineUuid == m.id),
            onToggle: () => notifier.toggle(m.id, online: m.online),
          ),
        const _PanelDivider(),
        PanelRow(
          icon: AbIcons.check,
          label: 'Select all',
          mono: false,
          selected: false,
          onTap: () => notifier.selectAll([for (final m in machines) m.id]),
        ),
        PanelRow(
          icon: AbIcons.eyeClosed,
          label: 'Hide offline machines',
          mono: false,
          selected: scope.hideOffline,
          onTap: () => notifier.setHideOffline(!scope.hideOffline),
        ),
        PanelRow(
          icon: AbIcons.settings,
          label: 'Manage machines…',
          mono: false,
          selected: false,
          onTap: () {
            Navigator.of(context).pop();
            openMachineManagement(ref.container);
          },
        ),
      ],
    );
  }
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
  return parts.isEmpty ? 'Online · idle' : parts.join(' · ');
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

class _ScopeMachineRow extends StatefulWidget {
  const _ScopeMachineRow({
    super.key,
    required this.machine,
    required this.checked,
    required this.hiddenAsOffline,
    required this.status,
    required this.entry,
    required this.onToggle,
  });

  final MachineInfo machine;
  final bool checked;
  final bool hiddenAsOffline;
  final String status;

  /// The drawer entry behind a remote machine, which is what "forget" acts on.
  final DrawerEntry? entry;
  final VoidCallback onToggle;

  @override
  State<_ScopeMachineRow> createState() => _ScopeMachineRowState();
}

class _ScopeMachineRowState extends State<_ScopeMachineRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final p = context.antgrid;
    final remote = switch (m.remoteAccessEnabled) {
      true => 'remote on',
      false => 'remote off',
      null => null,
    };
    final entry = widget.entry;
    final forget = (_hovered || _focused) && entry is RemoteAgentEntry;
    return Semantics(
      checked: widget.checked,
      label: '${m.name}, ${m.online ? 'online' : 'offline'}, ${widget.status}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(
          // Still choosable — the box is the user's pick — but visibly not
          // what the scope shows while "Hide offline" is on.
          opacity: widget.hiddenAsOffline ? AbTokens.opacityDisabled : 1,
          child: AbListRow(
            leading: AbStatusDot(
              tone: m.online ? AbStatusTone.success : AbStatusTone.disabled,
              style: m.online ? AbDotStyle.filled : AbDotStyle.hollow,
            ),
            title: Row(
              children: [
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
                if (m.isLocal) ...[
                  const SizedBox(width: AbTokens.space6),
                  Text(
                    'this machine',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: p.textMuted,
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(widget.status),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (forget)
                  DrawerRemoveButton(entry: entry)
                else if (remote != null) ...[
                  if (m.remoteAccessEnabled == false) ...[
                    AbIcon(AbIcons.lock, size: AbTokens.fontXs, color: p.textMuted),
                    const SizedBox(width: AbTokens.space4),
                  ],
                  Text(
                    remote,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXxs,
                      color: p.textMuted,
                    ),
                  ),
                ],
                const SizedBox(width: AbTokens.space8),
                SizedBox(
                  width: AbTokens.fontSm,
                  child: widget.checked
                      ? AbIcon(AbIcons.check, size: AbTokens.fontSm, color: p.accent)
                      : null,
                ),
              ],
            ),
            density: AbRowDensity.sm,
            horizontalPadding: AbTokens.space8,
            hoverable: true,
            contentFloor: AbRowContentFloor.iconButton,
            onFocusChange: (v) => setState(() => _focused = v),
            onTap: widget.onToggle,
          ),
        ),
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AbTokens.space4),
    child: Container(height: 1, color: context.antgrid.borderStrong),
  );
}
