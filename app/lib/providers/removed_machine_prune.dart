import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/devices_api.dart';
import '../util/ab_log.dart';
import '../util/device_id.dart';
import 'agent_transport.dart';
import 'auth.dart';
import 'device_provisioning.dart';
import 'providers.dart';
import 'recent_agents.dart';

/// Minimum spacing between [pruneRemovedMachines] probes. Launch and every
/// resume call it; a machine leaving the account is rare and never urgent, so
/// this matches the revocation probe's cadence rather than polling for it.
const _kPruneCooldown = Duration(minutes: 5);

/// Cross-call state. On a plain [Provider] for the same reason the revocation
/// coordinator is: it must survive the provider invalidation a sign-out
/// performs, or the cooldown it guards resets with the teardown.
class _PruneCoordinator {
  DateTime? lastRun;
}

final _coordinatorProvider = Provider<_PruneCoordinator>(
  (ref) => _PruneCoordinator(),
);

/// Drops the local footprint of every machine that has left the account.
///
/// A revoked machine keeps its drawer row forever otherwise: the row is backed
/// by a cached `RecentAgent`, which nothing expires, and it renders with a
/// correct name and dials on tap — so it is indistinguishable from a machine
/// that is merely switched off.
///
/// **`GET /account/devices` is the only honest source for this.** The relay
/// deliberately collapses "not connected", "dead socket" and "different
/// account" into one retryable `PEER_OFFLINE` so an unauthorized sender cannot
/// use it as a presence oracle, and it holds live connections with no
/// tombstones — so no dial failure, at any layer, can distinguish revoked from
/// powered-off. `/account/agents` is the wrong list for the opposite reason: it
/// filters on `mobileAccessEnabled`, so a machine whose remote-access switch is
/// off vanishes from it while remaining on the account.
///
/// Three guards keep an absence from ever being read out of a reply that
/// cannot support it — each covers a case where the honest answer is unknown,
/// and pruning on it would delete a live machine's cache irrecoverably:
///   - a throw is a failed read, never an empty account (see [DevicesApi.list]);
///   - THIS machine must appear in the response, which proves the list both
///     arrived whole and belongs to the account we think we are — it also
///     covers the window right after sign-in where provisioning has not landed
///     yet and the account legitimately has no rows;
///   - the focused machine is never pruned, because [forgetMachine] clears the
///     selection and would drop a user mid-session onto the New Session canvas.
Future<void> pruneRemovedMachines(ProviderContainer ref) async {
  final coordinator = ref.read(_coordinatorProvider);
  final now = DateTime.now();
  final last = coordinator.lastRun;
  if (last != null && now.difference(last) < _kPruneCooldown) return;
  coordinator.lastRun = now;

  // AWAITED, not a synchronous `signedInProvider` read: the cold-start caller
  // runs from `initState`, where `/account/me` has not resolved and the
  // synchronous signal is still `null` — reading it there would make the launch
  // probe a guaranteed no-op and leave resume as the feature's only trigger.
  final bool signedIn;
  try {
    signedIn = await ref.read(currentUserProvider.future) != null;
  } catch (error) {
    AbLog.debug('MachinePrune', 'account unresolved: $error');
    return;
  }
  if (!signedIn) {
    // Nothing was asked of the account, so nothing is owed to the cooldown: a
    // sign-in a minute later must not have to wait it out.
    coordinator.lastRun = last;
    return;
  }

  final List<DeviceSummary> devices;
  try {
    devices = await ref.read(devicesApiProvider).list();
  } catch (error) {
    AbLog.debug('MachinePrune', 'device list unavailable: $error');
    return;
  }

  // Everything past the first await runs against a container the app may have
  // torn down (sign-out, window close), and Riverpod 3 throws from every `ref`
  // member once it is gone. Callers invoke this with `unawaited` from a
  // lifecycle hook, where an escaping rejection is a fatal unhandled async
  // error rather than a failed prune.
  try {
    final live = {for (final d in devices) d.deviceId};
    final localUuid = await ref.read(localDeviceUuidProvider.future);
    if (localUuid == null || !live.contains(localUuid)) {
      AbLog.debug(
        'MachinePrune',
        'skipped - this machine is not in the account response yet',
      );
      return;
    }

    final focused = ref.read(selectedRegistrationIdProvider);
    final focusedBase = focused == null ? null : baseDeviceUuid(focused);
    final gone = <String>{
      for (final r in ref.read(recentAgentsStoreProvider).list())
        baseDeviceUuid(r.agentDeviceId),
    }..removeWhere(
      (uuid) => live.contains(uuid) || uuid == focusedBase || uuid == localUuid,
    );
    if (gone.isEmpty) return;

    AbLog.info('MachinePrune', 'forgetting ${gone.length} removed machine(s)');
    for (final uuid in gone) {
      await ref.read(machineConnectionProvider.notifier).forgetMachine(uuid);
    }
  } catch (error) {
    AbLog.error('MachinePrune', 'prune abandoned: $error');
  }
}
