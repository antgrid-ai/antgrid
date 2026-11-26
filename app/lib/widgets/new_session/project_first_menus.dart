import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../models/project_catalog.dart';
import '../../providers/demo_mode.dart';
import '../../providers/machine_capability_card.dart';
import '../../providers/machine_directory.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/project_index.dart';
import '../../providers/project_composer.dart';
import '../../utils/platform_utils.dart';
import 'environment_menu.dart';

/// The composer's project picker: every project in scope, merged across
/// machines. Picking one also picks its machine — the one its last session ran
/// on, if that is up — which the machine chip beside it can then change.
class ProjectFirstPanel extends ConsumerWidget {
  const ProjectFirstPanel({super.key, required this.onOpenFolder});

  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(inScopeProjectViewsProvider);
    final current = ref.watch(composerProjectViewProvider)?.group.key;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSectionHeader('Projects'),
        // Desktop only, and never in the demo: this runs the OS folder picker
        // and registers a REAL project.
        if (!isMobilePlatform && !ref.watch(demoModeProvider))
          PanelRow(
            icon: AbIcons.newFolder,
            label: 'Open folder…',
            selected: false,
            onTap: () {
              Navigator.of(context).pop();
              onOpenFolder();
            },
          ),
        if (views.isEmpty)
          const PanelHint('No projects on the machines in scope')
        else
          for (final v in views)
            PanelRow(
              icon: AbIcons.folder,
              label: v.group.name,
              selected: v.group.key == current,
              trailing: Text(
                v.allOffline
                    ? 'offline'
                    : '${v.machines.length} machine${v.machines.length == 1 ? '' : 's'}',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: context.antgrid.textMuted,
                ),
              ),
              // Nothing can be started on a project whose every machine is
              // down; it is listed so the user sees it is known, not missing.
              onTap: v.allOffline
                  ? null
                  : () {
                      pointComposerAtProject(ref.container, v);
                      Navigator.of(context).pop();
                    },
            ),
      ],
    );
  }
}

/// The composer's machine picker once a project is chosen: the machines in
/// scope that hold it, then the ones that do not. Offline machines are listed
/// but cannot be picked.
class ComposerMachinePanel extends ConsumerWidget {
  const ComposerMachinePanel({super.key, required this.view});

  final ProjectView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targetId = ref.watch(selectedTargetProjectProvider)?.id;
    final holding = {for (final m in view.members) m.machineId: m};
    final scoped = ref.watch(scopedMachineIdsProvider);
    final others = [
      for (final m in ref.watch(machineDirectoryProvider))
        if (scoped.contains(m.id) && !holding.containsKey(m.id)) m,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelSectionHeader('${view.group.name} is on'),
        for (final m in view.machines)
          _MachineChoice(
            key: ValueKey(m.id),
            machine: m,
            projectId: holding[m.id]!.projectId,
            selected: holding[m.id]!.entryId == targetId,
            onTap: m.online
                ? () {
                    selectComposerMember(ref.container, holding[m.id]!);
                    Navigator.of(context).pop();
                  }
                : null,
          ),
        if (others.isNotEmpty) ...[
          const PanelSectionHeader('Not on these machines yet'),
          for (final m in others)
            _MachineChoice(
              key: ValueKey('other-${m.id}'),
              machine: m,
              projectId: null,
              selected: false,
              onTap: null,
            ),
        ],
      ],
    );
  }
}

class _MachineChoice extends ConsumerWidget {
  const _MachineChoice({
    super.key,
    required this.machine,
    required this.projectId,
    required this.selected,
    required this.onTap,
  });

  final MachineInfo machine;

  /// Null for a machine that does not hold the project.
  final String? projectId;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = machine;
    final p = context.antgrid;
    final projectId = this.projectId;
    final branch = projectId == null
        ? null
        : _watchMachineBranch(ref, m, projectId);
    final status = [
      if (!m.online) 'Offline' else 'Online',
      ?branch,
      if (projectId == null && m.online) 'project not opened here',
      if (m.isLocal) 'this machine',
    ].join(' · ');
    return Semantics(
      selected: selected,
      enabled: onTap != null,
      label: '${m.name}, $status',
      excludeSemantics: true,
      child: AbListRow(
        leading: AbStatusDot(
          tone: m.online ? AbStatusTone.success : AbStatusTone.disabled,
          style: m.online ? AbDotStyle.filled : AbDotStyle.hollow,
        ),
        title: Text(
          m.name,
          overflow: TextOverflow.ellipsis,
          style: AbTokens.monoStyle(
            fontSize: AbTokens.fontSm,
            color: p.textPrimary,
          ),
        ),
        subtitle: Text(status),
        trailing: SizedBox(
          width: AbTokens.fontSm,
          child: selected
              ? AbIcon(AbIcons.check, size: AbTokens.fontSm, color: p.accent)
              : null,
        ),
        density: AbRowDensity.sm,
        horizontalPadding: AbTokens.space8,
        hoverable: true,
        enabled: onTap != null,
        onTap: onTap,
      ),
    );
  }
}

/// The branch [machine]'s copy of [projectId] is on, from its Capability Card.
/// Asked only of a machine that is up: the card is an RPC, and for a remote
/// machine it rides that machine's control plane.
String? _watchMachineBranch(
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
