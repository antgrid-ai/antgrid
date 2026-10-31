import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/supervisor_state.dart';
import '../project/project_session_registry.dart';
import '../services/account_agents_api.dart';
import '../storage/mobile_machine_store.dart';
import '../util/detached.dart';
import '../util/device_id.dart';
import 'account_agents.dart';
import 'agent_transport.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'eager_control_planes.dart';
import 'machine_directory.dart';
import 'new_session_picker.dart';
import 'project_panel.dart';
import 'recent_sessions.dart';
import 'relay_connection.dart';

/// Whether the phone connects to one machine the user picked, rather than to
/// whichever machines it has used lately. The demo has no machines to pick.
///
/// Also off wherever `main()` opened no [MobileMachineStore]: `flutter test`
/// reports Android as the target platform, so without this every widget test
/// of the New Session canvas would render the machine picker instead. Tests of
/// the flow itself override this provider.
final mobileConnectEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(eagerControlPlanesEnabledProvider) &&
      !ref.watch(demoModeProvider) &&
      ref.watch(mobileMachineStoreProvider) != null,
);

/// How long the Connecting screen waits before offering Try again. Above the
/// few seconds an offline machine takes to refuse, well below the relay's own
/// worst case, which would leave the user watching a spinner for a minute.
const Duration kMobileConnectTimeout = Duration(seconds: 20);

/// Null — in memory only — wherever `main()` did not open one.
final mobileMachineStoreProvider = Provider<MobileMachineStore?>((_) => null);

@immutable
class MobileConnection {
  const MobileConnection({
    this.machineId,
    this.restored = false,
    this.timedOut = false,
    this.lastMachineId,
    this.reconnectNextTime = true,
  });

  /// The machine the phone is connected or connecting to; null shows the
  /// picker.
  final String? machineId;

  /// [machineId] came from last launch rather than a tap, and the inventory
  /// has not yet said whether it is up.
  final bool restored;

  /// The current attempt outlasted [kMobileConnectTimeout].
  final bool timedOut;

  final String? lastMachineId;
  final bool reconnectNextTime;

  MobileConnection copyWith({
    String? machineId,
    bool clearMachine = false,
    bool? restored,
    bool? timedOut,
    String? lastMachineId,
    bool? reconnectNextTime,
  }) => MobileConnection(
    machineId: clearMachine ? null : (machineId ?? this.machineId),
    restored: restored ?? this.restored,
    timedOut: timedOut ?? this.timedOut,
    lastMachineId: lastMachineId ?? this.lastMachineId,
    reconnectNextTime: reconnectNextTime ?? this.reconnectNextTime,
  );

  @override
  bool operator ==(Object other) =>
      other is MobileConnection &&
      other.machineId == machineId &&
      other.restored == restored &&
      other.timedOut == timedOut &&
      other.lastMachineId == lastMachineId &&
      other.reconnectNextTime == reconnectNextTime;

  @override
  int get hashCode => Object.hash(
    machineId,
    restored,
    timedOut,
    lastMachineId,
    reconnectNextTime,
  );
}

final mobileConnectionProvider =
    NotifierProvider<MobileConnectionNotifier, MobileConnection>(
      MobileConnectionNotifier.new,
    );

class MobileConnectionNotifier extends Notifier<MobileConnection> {
  MobileMachineStore? _store;

  @override
  MobileConnection build() {
    // Cleared first: build() re-runs on this instance when the demo switch
    // flips, and the demo must not write the real choice.
    _store = null;
    if (!ref.watch(mobileConnectEnabledProvider)) {
      return const MobileConnection();
    }
    _store = ref.watch(mobileMachineStoreProvider);
    final saved = _store?.read();
    final last = saved?.lastMachineId;
    final reconnect = saved?.reconnect ?? true;
    var restore = reconnect ? last : null;
    var restored = restore != null;
    // Reconnecting is only worth it to a machine that is up; the inventory's
    // heartbeat says so. Decided once: after that a dropped connection is the
    // supervisor's to recover, not a reason to bounce the user to the picker.
    final inventory = ref.read(accountAgentsProvider).value;
    if (restored && inventory != null) {
      if (!_heartbeatFresh(inventory, restore)) restore = null;
      restored = false;
    }
    ref.listen<AsyncValue<List<InventoryAgent>>>(accountAgentsProvider, (
      _,
      next,
    ) {
      final id = state.machineId;
      final inv = next.value;
      if (!state.restored || id == null || inv == null) return;
      final live = ref.read(machineLiveConnectionProvider)[id] ?? false;
      state = live || _heartbeatFresh(inv, id)
          ? state.copyWith(restored: false)
          : state.copyWith(clearMachine: true, restored: false);
    });
    return MobileConnection(
      machineId: restore,
      restored: restored,
      lastMachineId: last,
      reconnectNextTime: reconnect,
    );
  }

  static bool _heartbeatFresh(List<InventoryAgent> inventory, String id) {
    for (final a in inventory) {
      if (a.deviceUuid == id) {
        return machineOnline(
          connected: false,
          lastHeartbeatAt: a.lastSeenAt,
          now: DateTime.now(),
        );
      }
    }
    return false;
  }

  void connect(String machineId) {
    state = state.copyWith(
      machineId: machineId,
      restored: false,
      timedOut: false,
      lastMachineId: machineId,
    );
    _persist();
  }

  void retry() => state = state.copyWith(timedOut: false);

  /// Ignored when [machineId] is no longer the attempt in progress — a timer
  /// started for a machine the user has since left.
  void markTimedOut(String machineId) {
    if (state.machineId != machineId) return;
    state = state.copyWith(timedOut: true);
  }

  void disconnect() => state = state.copyWith(
    clearMachine: true,
    restored: false,
    timedOut: false,
  );

  void setReconnectNextTime(bool value) {
    if (value == state.reconnectNextTime) return;
    state = state.copyWith(reconnectNextTime: value);
    _persist();
  }

  void _persist() {
    final store = _store;
    if (store == null) return;
    final s = state;
    detached(
      'MobileConnection',
      'persist failed',
      () => store.write(
        lastMachineId: s.lastMachineId,
        reconnect: s.reconnectNextTime,
      ),
    );
  }
}

enum MobileConnectPhase { choose, connecting, connected, failed }

enum MobileConnectFailure { unreachable, remoteAccessOff }

@immutable
class MobileConnectStatus {
  const MobileConnectStatus(
    this.phase, {
    this.machineId,
    this.reached = false,
    this.failure,
  });

  final MobileConnectPhase phase;
  final String? machineId;

  /// The socket to the machine is up; what remains is its project list.
  final bool reached;
  final MobileConnectFailure? failure;

  @override
  bool operator ==(Object other) =>
      other is MobileConnectStatus &&
      other.phase == phase &&
      other.machineId == machineId &&
      other.reached == reached &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(phase, machineId, reached, failure);
}

/// Where the phone's connect flow stands. Pure.
///
/// Connected needs both the live socket and the machine's project list: the
/// list is what the home shows, and a socket alone can still be a machine
/// that has not answered.
MobileConnectStatus mobileConnectStatus({
  required String? machineId,
  required bool? live,
  required MachineAdvertSummary? advert,
  required bool clientFailed,
  required bool timedOut,
}) {
  if (machineId == null) {
    return const MobileConnectStatus(MobileConnectPhase.choose);
  }
  // A machine with remote access off answers, then refuses every verb, so
  // reaching it is not being connected to it.
  if (advert?.remoteAccessEnabled == false) {
    return MobileConnectStatus(
      MobileConnectPhase.failed,
      machineId: machineId,
      reached: true,
      failure: MobileConnectFailure.remoteAccessOff,
    );
  }
  if (live == true && advert != null) {
    return MobileConnectStatus(
      MobileConnectPhase.connected,
      machineId: machineId,
      reached: true,
    );
  }
  if (clientFailed || timedOut) {
    return MobileConnectStatus(
      MobileConnectPhase.failed,
      machineId: machineId,
      reached: live == true,
      failure: MobileConnectFailure.unreachable,
    );
  }
  return MobileConnectStatus(
    MobileConnectPhase.connecting,
    machineId: machineId,
    reached: live == true,
  );
}

final mobileConnectStatusProvider = Provider<MobileConnectStatus>((ref) {
  final c = ref.watch(mobileConnectionProvider);
  final id = c.machineId;
  if (id == null) return const MobileConnectStatus(MobileConnectPhase.choose);
  // Watched, so this is also what dials the chosen machine when nothing else
  // has: it is the one machine the phone wants.
  final client = ref.watch(controlPlaneClientForProvider(id));
  return mobileConnectStatus(
    machineId: id,
    live: ref.watch(machineLiveConnectionProvider.select((m) => m[id])),
    advert: ref.watch(machineAdvertisedProjectsProvider.select((m) => m[id])),
    clientFailed:
        !client.isLoading &&
        (client.hasError || (client.hasValue && client.value == null)),
    timedOut: c.timedOut,
  );
});

/// Connect the phone to [machineId], letting go of whatever it was connected
/// to: its open projects, its focus and the composer's target. The socket
/// itself closes on its own once nothing names the old machine.
void chooseMobileMachine(ProviderContainer c, String machineId) {
  final previous = c.read(mobileConnectionProvider).machineId;
  if (previous != null && previous != machineId) _releaseMachine(c, previous);
  c.read(mobileConnectionProvider.notifier).connect(machineId);
  closeProjectPanel(c);
  c.read(selectedSourceIdProvider.notifier).set('machine:$machineId');
  final target = c.read(selectedTargetProjectProvider);
  if (target != null && target.machineUuid != machineId) {
    c.read(selectedTargetProjectProvider.notifier).set(null);
  }
  detached(
    'MobileConnection',
    'dial failed',
    () => kickEagerControlPlaneDials(RefreshRef.ofContainer(c)),
  );
}

void disconnectMobileMachine(ProviderContainer c) {
  final previous = c.read(mobileConnectionProvider).machineId;
  if (previous != null) _releaseMachine(c, previous);
  c.read(mobileConnectionProvider.notifier).disconnect();
  closeProjectPanel(c);
}

/// A fresh attempt at the current machine: a stuck ladder is restarted and the
/// cached failure dropped, as the drawer's own pull-to-refresh does.
Future<void> retryMobileMachine(ProviderContainer c) async {
  final id = c.read(mobileConnectionProvider).machineId;
  if (id == null) return;
  c.read(mobileConnectionProvider.notifier).retry();
  final mgr = c.read(relayConnectionManagerProvider);
  if (mgr.peek(id)?.supervisor?.status is! Connected) await mgr.restart(id);
  invalidateControlPlaneProviders(RefreshRef.ofContainer(c), id);
  try {
    await c.read(controlPlaneClientForProvider(id).future);
  } catch (_) {
    // The status provider shows the failure; nothing to add here.
  }
}

/// Each of these would otherwise hold the old machine's socket open: an open
/// project, and the focused workspace. Pinned projects stay — the session bus
/// pins one only while an agent exchange rides it.
void _releaseMachine(ProviderContainer c, String machineId) {
  final focus = c.read(selectedTargetProvider);
  if (focus != null &&
      !focus.isLocal &&
      baseDeviceUuid(focus.registrationId) == machineId) {
    c.read(selectedTargetProvider.notifier).set(null);
  }
  final registry = c.read(projectSessionRegistryProvider.notifier);
  final pinned = registry.registry.pinnedProjects;
  for (final id in c.read(projectSessionRegistryProvider)) {
    if (id.contains('.') &&
        baseDeviceUuid(id) == machineId &&
        !pinned.contains(id)) {
      registry.forceEvict(id);
    }
  }
}
