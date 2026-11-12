import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/new_session_picker.dart';
import 'context_picker.dart';
import 'picker_sources.dart';

/// Environment picker for the New Session composer: shows the picker's visible
/// source (Local or a machine) and opens a grouped source menu on tap.
/// Selection writes [selectedSourceIdProvider] — the same provider the old
/// rail tabs wrote, so control-plane keep-alive (controlPlaneAliveTargetsProvider)
/// and target validation keep working unchanged.
class EnvironmentChip extends ConsumerWidget {
  const EnvironmentChip({super.key, this.enabled = true});

  /// Passed down by the composer rather than read from the start-progress
  /// provider here: one owner decides when the context row is frozen, and the
  /// chip stays mountable on its own in tests.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(visiblePickerSourceProvider);
    final sources = ref.watch(pickerSourcesProvider);
    final isLocal = source?.isLocal ?? true;
    return ContextPicker(
      icon: isLocal ? CarbonIcons.screen : CarbonIcons.serverDns,
      label: source?.label ?? 'Local',
      field: 'Environment',
      enabled: enabled,
      entries: environmentEntries(
        sources,
        source?.id,
        (id) => ref.read(selectedSourceIdProvider.notifier).set(id),
      ),
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
