import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/project_catalog.dart';
import '../../providers/machine_capability_card.dart';
import '../../providers/machine_directory.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/project_index.dart';
import '../../providers/project_composer.dart';

/// The composer's project menu: every project in scope, merged across
/// machines. Picking one also picks its machine — the one its last session ran
/// on, if that is up — which the machine chip beside it can then change.
///
/// [onOpenFolder] null hides the "Open folder…" row.
List<CarbonMenuEntry> projectFirstEntries({
  required List<ProjectView> views,
  required String? currentKey,
  required VoidCallback? onOpenFolder,
  required ValueChanged<ProjectView> onPick,
}) {
  final byKey = {for (final v in views) v.group.key: v};
  return [
    CarbonMenuGroup(
      label: 'Projects',
      children: [
        if (onOpenFolder != null)
          CarbonMenuItem(
            label: 'Open folder…',
            icon: const CarbonIcon(CarbonIcons.folderAdd),
            onPressed: onOpenFolder,
          ),
        if (views.isEmpty)
          const CarbonMenuItem(label: 'No projects on the machines in scope')
        else
          CarbonMenuRadioGroup<String>(
            value: currentKey,
            options: [
              for (final v in views)
                CarbonOption(
                  value: v.group.key,
                  label: v.group.name,
                  description: v.allOffline
                      ? 'offline'
                      : '${v.machines.length} machine'
                            '${v.machines.length == 1 ? '' : 's'}',
                  // Nothing can be started on a project whose every machine is
                  // down; it is listed so the user sees it is known, not
                  // missing.
                  enabled: !v.allOffline,
                ),
            ],
            onChanged: (key) {
              final v = byKey[key];
              if (v != null) onPick(v);
            },
          ),
      ],
    ),
  ];
}

/// The composer's machine menu once a project is chosen: the machines in scope
/// that hold it, then the ones that do not. Offline machines are listed but
/// cannot be picked.
///
/// Watches each holding machine's Capability Card for its branch, which is an
/// RPC — so call it only while the menu is open.
List<CarbonMenuEntry> composerMachineEntries(
  WidgetRef ref,
  ProjectView view,
) {
  final targetId = ref.watch(selectedTargetProjectProvider)?.id;
  final holding = {for (final m in view.members) m.machineId: m};
  final scoped = ref.watch(scopedMachineIdsProvider);
  final others = [
    for (final m in ref.watch(machineDirectoryProvider))
      if (scoped.contains(m.id) && !holding.containsKey(m.id)) m,
  ];
  final container = ref.container;
  return [
    CarbonMenuRadioGroup<String>(
      label: '${view.group.name} is on',
      value: view.members
          .firstWhereOrNull((m) => m.entryId == targetId)
          ?.entryId,
      options: [
        for (final m in view.machines)
          CarbonOption(
            value: holding[m.id]!.entryId,
            label: m.name,
            description: _machineStatus(ref, m, holding[m.id]!.projectId),
            enabled: m.online,
          ),
      ],
      onChanged: (entryId) {
        final member = view.members.firstWhereOrNull(
          (m) => m.entryId == entryId,
        );
        if (member != null) selectComposerMember(container, member);
      },
    ),
    if (others.isNotEmpty)
      CarbonMenuGroup(
        label: 'Not on these machines yet',
        children: [
          for (final m in others)
            CarbonMenuItem(
              label: m.name,
              disabledReason: m.online ? 'Project not opened here' : 'Offline',
            ),
        ],
      ),
  ];
}

/// Terse, because a menu row has no second line and every character the
/// description takes is one the machine name loses to truncation.
String _machineStatus(WidgetRef ref, MachineInfo m, String projectId) {
  final parts = [
    if (!m.online) 'Offline',
    ?_watchMachineBranch(ref, m, projectId),
    if (m.isLocal) 'this machine',
  ];
  return parts.isEmpty ? 'Online' : parts.join(' · ');
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
