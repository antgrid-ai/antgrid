import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/account_agents_api.dart';
import '../utils/platform_utils.dart';
import 'account_agents.dart';
import 'demo_mode.dart';
import 'device_provisioning.dart';
import 'machine_directory.dart';
import 'machine_scope.dart';

/// Most machines the desktop holds a control plane open to just because they
/// are in scope. Needs you and the live counts need each machine's advert, and
/// a desktop is otherwise fully lazy; the cap is what keeps this from being
/// the eager-connect-everywhere design that caused connection storms.
const int kScopeControlPlaneCap = 5;

final scopeControlPlanesEnabledProvider = Provider<bool>(
  (_) => !isMobilePlatform,
);

/// Remote machines in scope whose account heartbeat says they are up, most
/// recently seen first, capped. Pure.
///
/// Reads the heartbeat and never the live connection state: a socket this set
/// opened would otherwise be the evidence that keeps its own machine in the
/// set, so a machine that went dark could never fall out.
Set<String> scopeControlPlaneTargets({
  required List<InventoryAgent> inventory,
  required MachineScope scope,
  required String? localDeviceUuid,
  required DateTime now,
  int cap = kScopeControlPlaneCap,
}) {
  final candidates = [
    for (final a in inventory)
      if (a.deviceUuid != localDeviceUuid &&
          machineOnline(
            connected: false,
            lastHeartbeatAt: a.lastSeenAt,
            now: now,
          ) &&
          scope.includes(a.deviceUuid, online: true))
        a,
  ]..sort((a, b) => b.lastSeenAt!.compareTo(a.lastSeenAt!));
  return {for (final a in candidates.take(cap)) a.deviceUuid};
}

final scopeControlPlaneTargetsProvider = Provider<Set<String>>((ref) {
  if (!ref.watch(scopeControlPlanesEnabledProvider)) return const {};
  if (ref.watch(demoModeProvider)) return const {};
  final targets = scopeControlPlaneTargets(
    inventory: ref.watch(accountAgentsProvider).value ?? const [],
    scope: ref.watch(machineScopeProvider),
    localDeviceUuid: ref.watch(localDeviceUuidProvider).value,
    // Not a ticking clock: presence moves with the heartbeat, and the
    // inventory that carries it is re-read on that cadence (AppShell).
    now: DateTime.now(),
  );
  // Same stability trick as the mobile eager set: every input above rebuilds
  // this far more often than the answer changes, and the reaper reconciles
  // sockets on every emission.
  final key = (targets.toList()..sort()).join('\n');
  return ref.watch(_stableTargets(key));
});

final _stableTargets = Provider.autoDispose.family<Set<String>, String>(
  (_, key) => key.isEmpty ? const {} : key.split('\n').toSet(),
);
