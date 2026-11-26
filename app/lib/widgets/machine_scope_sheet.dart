import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_adaptive_sheet.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_status_dot.dart';
import '../providers/machine_directory.dart';
import '../providers/machine_scope.dart';
import '../providers/project_index.dart';
import '../providers/project_work_status.dart';
import '../providers/recent_sessions.dart';
import 'machine_scope_menu.dart' show machineStatusLine, openMachineManagement;

/// The phone's machine scope switcher: what the scope shows and how much of it
/// is live, opening [MachineScopeSheet]. The same scope the desktop sidebar's
/// menu edits — there is only one.
class MobileScopeButton extends ConsumerWidget {
  const MobileScopeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(machineDirectoryProvider);
    final machines = scopeCandidates(all);
    final scope = ref.watch(machineScopeProvider);
    final inScope = ref.watch(scopedMachineIdsProvider);
    final online = machines.where((m) => inScope.contains(m.id) && m.online);
    final running = ref
        .watch(projectViewsProvider)
        .fold<int>(0, (n, v) => n + v.liveCount);
    final locked = all.length - machines.length;
    final label = machineScopeLabel(machines, scope);
    final summary = [
      '${online.length} online',
      '$running running',
      if (locked > 0) '$locked locked',
    ].join(' · ');
    return Semantics(
      button: true,
      label: 'Machine scope: $label, $summary',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: context.antgrid.borderDefault),
          borderRadius: AbTokens.borderRadius5,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AbTokens.tapTargetMin),
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
            horizontalPadding: AbTokens.space10,
            onTap: () => showAbAdaptiveSheet<void>(
              context,
              child: const MachineScopeSheet(),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scope on a phone. A machine whose remote-access switch is off is shown
/// locked rather than as a checkbox: this device could not drive it anyway, and
/// a box that ticked would promise a choice that changes nothing.
class MachineScopeSheet extends ConsumerWidget {
  const MachineScopeSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machineDirectoryProvider);
    final scope = ref.watch(machineScopeProvider);
    final rows = ref.watch(recentSessionsProvider);
    final statuses = ref.watch(recentSessionStatusesProvider);
    final notifier = ref.read(machineScopeProvider.notifier);
    final reachable = scopeCandidates(machines);
    final p = context.antgrid;

    Widget action(String label, VoidCallback onTap, {Widget? trailing}) =>
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AbTokens.touchControlMin),
          child: AbListRow(
            title: Text(label, style: AbTokens.sansStyle(fontSize: AbTokens.fontMd)),
            trailing: trailing,
            horizontalPadding: AbTokens.space16,
            onTap: onTap,
          ),
        );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AbTokens.space16,
                AbTokens.space4,
                AbTokens.space4,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Machine scope',
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontMd,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.close,
                    tooltip: 'Close',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            for (final m in machines)
              if (m.remoteAccessEnabled == false)
                _LockedMachineRow(machine: m)
              else
                _SheetMachineRow(
                  key: ValueKey(m.id),
                  machine: m,
                  checked: scope.isChecked(m.id, online: m.online),
                  status: machineStatusLine(m, rows, statuses),
                  onTap: () => notifier.toggle(m.id, online: m.online),
                ),
            const AbSeparator.horizontal(),
            action(
              'Select all',
              () => notifier.selectAll([for (final m in reachable) m.id]),
            ),
            action(
              'Hide offline machines',
              () => notifier.setHideOffline(!scope.hideOffline),
              trailing: scope.hideOffline
                  ? AbIcon(AbIcons.check, size: AbTokens.fontLg, color: p.accent)
                  : null,
            ),
            action('Manage machines…', () {
              Navigator.of(context).pop();
              openMachineManagement(ref.container);
            }),
            const SizedBox(height: AbTokens.space8),
          ],
        ),
      ),
    );
  }
}

class _SheetMachineRow extends StatelessWidget {
  const _SheetMachineRow({
    super.key,
    required this.machine,
    required this.checked,
    required this.status,
    required this.onTap,
  });

  final MachineInfo machine;
  final bool checked;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = machine;
    final p = context.antgrid;
    return Semantics(
      checked: checked,
      label: '${m.name}, ${m.online ? 'online' : 'offline'}, $status',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AbTokens.rowHeightXl),
        child: AbListRow(
          leading: AbStatusDot(
            tone: m.online ? AbStatusTone.success : AbStatusTone.disabled,
            style: m.online ? AbDotStyle.filled : AbDotStyle.hollow,
            size: AbDotSize.md,
          ),
          title: Text(
            m.name,
            style: AbTokens.monoStyle(fontSize: AbTokens.fontMd, color: p.textPrimary),
          ),
          subtitle: Text(status),
          trailing: SizedBox(
            width: AbTokens.fontLg,
            child: checked
                ? AbIcon(AbIcons.check, size: AbTokens.fontLg, color: p.accent)
                : null,
          ),
          horizontalPadding: AbTokens.space16,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _LockedMachineRow extends StatelessWidget {
  const _LockedMachineRow({required this.machine});

  final MachineInfo machine;

  @override
  Widget build(BuildContext context) {
    final m = machine;
    final p = context.antgrid;
    const reason = 'Remote access is off on this machine';
    return Semantics(
      label: '${m.name}, locked. $reason',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AbTokens.rowHeightXl),
        child: AbListRow(
          leading: AbStatusDot(
            tone: m.online ? AbStatusTone.success : AbStatusTone.disabled,
            style: m.online ? AbDotStyle.filled : AbDotStyle.hollow,
            size: AbDotSize.md,
          ),
          title: Text(
            m.name,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontMd,
              color: p.textSecondary,
            ),
          ),
          subtitle: const Text(reason),
          trailing: AbIcon(AbIcons.lock, size: AbTokens.fontLg, color: p.textMuted),
          horizontalPadding: AbTokens.space16,
        ),
      ),
    );
  }
}
