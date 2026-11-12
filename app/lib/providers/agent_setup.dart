import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_descriptor.dart';
import '../util/device_id.dart';
import 'agent_catalog.dart';
import 'agent_transport.dart';
import 'control_plane.dart';
import 'new_session_picker.dart';
import 'ui_attention_providers.dart';

typedef AgentSetupMachine = ({String? uuid, String label});

final agentSetupMachineProvider = Provider<AgentSetupMachine>((ref) {
  final inComposer =
      ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.newSession;
  final focused = inComposer ? null : ref.watch(selectedTargetProvider);
  final target =
      focused ?? sessionTargetOf(ref.watch(selectedTargetProjectProvider));
  final source = inComposer ? ref.watch(visiblePickerSourceProvider) : null;
  final uuid = target != null
      ? target.isLocal
            ? null
            : baseDeviceUuid(target.registrationId)
      : inComposer
      ? source?.machineUuid
      : machineUuidFromSourceId(ref.watch(selectedSourceIdProvider));
  if (uuid == null) return (uuid: null, label: 'this computer');
  for (final source in ref.watch(pickerSourcesProvider)) {
    if (source.machineUuid == uuid) return (uuid: uuid, label: source.label);
  }
  return (uuid: uuid, label: 'the selected computer');
});

final agentSetupToolsProvider =
    Provider.autoDispose<AsyncValue<Map<String, String?>?>>((ref) {
      if (ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.newSession) {
        return ref.watch(newSessionDetectedToolsProvider);
      }
      final machine = ref.watch(agentSetupMachineProvider);
      return machine.uuid == null
          ? ref.watch(localDetectedToolsProvider)
          : ref.watch(remoteDetectedToolsProvider(machine.uuid!));
    });

final agentSetupCatalogProvider = Provider.autoDispose<List<AgentDescriptor>>((
  ref,
) {
  final machine = ref.watch(agentSetupMachineProvider);
  final advertised = machine.uuid == null
      ? ref.watch(localToolsListProvider).value?.agents
      : ref.watch(controlPlaneStateProvider(machine.uuid!)).value?.agents;
  return advertised != null && advertised.isNotEmpty
      ? advertised
      : ref.watch(agentCatalogProvider).values.toList();
});

Future<void> retryAgentSetup(
  ProviderContainer container,
  AgentSetupMachine machine,
) async {
  if (machine.uuid == null) {
    container.invalidate(localToolsListProvider);
    container.invalidate(localDetectedToolsProvider);
    await container.read(localDetectedToolsProvider.future);
  } else {
    await retryMachineControlPlane(
      RefreshRef.ofContainer(container),
      machine.uuid!,
    );
  }
}

/// A custom command is usable only after the user has supplied it explicitly.
final newSessionNeedsAgentSetupProvider = Provider.autoDispose<bool>((ref) {
  if (ref.watch(newSessionStartInFlightProvider)) return false;
  if (ref.watch(newSessionAgentProvider) is CustomAgent &&
      ref.watch(newSessionCustomCmdProvider).trim().isNotEmpty) {
    return false;
  }
  final tools = ref.watch(newSessionDetectedToolsProvider);
  return tools.hasError || (tools.value?.isEmpty ?? true);
});
