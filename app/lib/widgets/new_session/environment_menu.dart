import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/new_session_picker.dart';
import '../../providers/project_composer.dart';
import 'context_picker.dart';
import 'picker_sources.dart';
import 'project_first_menus.dart';

/// Environment picker for the New Session composer: shows the picker's visible
/// source (Local or a machine) and opens a menu of sources on tap.
/// Selection writes [selectedSourceIdProvider] — the same provider the old
/// rail tabs wrote, so control-plane keep-alive (controlPlaneAliveTargetsProvider)
/// and target validation keep working unchanged.
///
/// Once a project is picked, the menu picks among the machines holding it
/// ([composerMachineEntries]); before that it browses machines.
class EnvironmentChip extends ConsumerStatefulWidget {
  const EnvironmentChip({super.key, this.enabled = true});

  /// Passed down by the composer rather than read from the start-progress
  /// provider here: one owner decides when the context row is frozen, and the
  /// chip stays mountable on its own in tests.
  final bool enabled;

  @override
  ConsumerState<EnvironmentChip> createState() => _EnvironmentChipState();
}

class _EnvironmentChipState extends ConsumerState<EnvironmentChip> {
  // The machine entries watch each holder's Capability Card, which is an RPC,
  // so they are built only while the menu is up.
  bool _open = false;

  void _setOpen(bool open) {
    if (!mounted || open == _open) return;
    setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(visiblePickerSourceProvider);
    final isLocal = source?.isLocal ?? true;
    return ContextPicker(
      icon: isLocal ? CarbonIcons.screen : CarbonIcons.serverDns,
      label: source?.label ?? 'Local',
      field: 'Environment',
      enabled: widget.enabled,
      onOpenChanged: _setOpen,
      entries: _open ? _entries(source?.id) : const [],
    );
  }

  List<CarbonMenuEntry> _entries(String? visibleId) {
    final project = ref.watch(composerProjectViewProvider);
    if (project != null) return composerMachineEntries(ref, project);
    return environmentEntries(
      ref.watch(pickerSourcesProvider),
      visibleId,
      (id) => ref.read(selectedSourceIdProvider.notifier).set(id),
    );
  }
}

/// A LOCAL group (when a Local source exists) and a MACHINES group with one
/// row per remote machine.
List<CarbonMenuEntry> environmentEntries(
  List<PickerSource> sources,
  String? visibleId,
  ValueChanged<String> onPick,
) {
  final locals = sources.where((s) => s.isLocal).toList();
  final machines = sources
      .where((s) => !s.isLocal && s.machineUuid != null)
      .toList();

  CarbonMenuRadioGroup<String> group(String label, List<PickerSource> from) =>
      CarbonMenuRadioGroup<String>(
        label: label,
        value: visibleId,
        options: [
          for (final s in from) CarbonOption(value: s.id, label: s.label),
        ],
        onChanged: onPick,
      );

  return [
    if (locals.isNotEmpty) group('Local', locals),
    if (machines.isEmpty)
      const CarbonMenuGroup(
        label: 'Machines',
        children: [CarbonMenuItem(label: 'No machines on this account')],
      )
    else
      group('Machines', machines),
  ];
}
