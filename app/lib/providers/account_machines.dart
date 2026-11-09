import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/supervisor_state.dart' show Connected;
import '../launcher/host_controller.dart' show HostPhase;
import '../util/device_id.dart';
import '../utils/platform_utils.dart';
import 'account_agents.dart';
import 'agent_coordinates.dart' show resolveMachineDisplay;
import 'demo_mode.dart';
import 'device_provisioning.dart';
import 'host_status.dart';
import 'recent_agents.dart';
import 'supervisor_status.dart';
import 'value_controller.dart';

const kLocalMachineKey = 'local';
const kLocalMachineName = 'Local machine';

/// Shared so a phone's machine-wide surfaces open the machine last chosen.
/// Written by the machine selectors and by the phone default latch, never by a
/// project lightbulb.
final machinePickProvider = NotifierProvider<ValueController<String?>, String?>(
  () => ValueController(null),
);

final accountMachinesProvider = Provider<Map<String, String>>((ref) {
  // accountAgentsProvider is deliberately not demo-gated at its source, so the
  // gate has to come before anything reads it.
  if (ref.watch(demoModeProvider)) return const {};
  final machines = <String, String>{
    if (!isMobilePlatform) kLocalMachineKey: kLocalMachineName,
  };
  final recents = ref.watch(recentAgentsProvider);
  final inventory = ref.watch(accountAgentsProvider).value;
  final ids = {
    for (final recent in recents) baseDeviceUuid(recent.agentDeviceId),
    for (final machine in inventory ?? const []) machine.deviceUuid,
  };
  for (final id in ids) {
    // The drawer's resolver, so a machine reads the same in both places.
    final display = resolveMachineDisplay(
      base: id,
      inventory: inventory,
      recents: recents,
    );
    if (display != null) machines[id] = display.name;
  }
  // This desktop's own agent comes back from /account/agents as a phantom
  // remote of itself.
  if (ref.watch(localDeviceUuidProvider).value case final own?) {
    machines.remove(own);
  }
  return machines;
});

final machinesSettlingProvider = Provider<bool>((ref) {
  if (ref.watch(demoModeProvider)) return false;
  final agents = ref.watch(accountAgentsProvider);
  return ref.watch(accountMachinesProvider).isEmpty &&
      agents.isLoading &&
      !agents.hasValue;
});

/// Null means the local loopback host.
final machineTargetProvider = Provider<String?>((ref) {
  if (ref.watch(demoModeProvider)) return null;
  final pick = ref.watch(machinePickProvider);
  final machines = ref.watch(accountMachinesProvider);
  if (pick != null && machines.containsKey(pick)) {
    return pick == kLocalMachineKey ? null : pick;
  }
  if (!isMobilePlatform) return null;
  final recents = [...ref.watch(recentAgentsProvider)]
    ..sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
  if (recents.isNotEmpty) return baseDeviceUuid(recents.first.agentDeviceId);
  return machines.keys.firstOrNull;
});

/// Only peeks at the supervisor, so watching it never dials.
final machineConnectedProvider = Provider.autoDispose.family<bool, String?>((
  ref,
  machineId,
) {
  if (machineId != null) {
    return ref.watch(supervisorStatusProvider(machineId)).value is Connected;
  }
  if (isMobilePlatform) return false;
  return ref.watch(hostStatusProvider).value?.phase == HostPhase.up;
});
