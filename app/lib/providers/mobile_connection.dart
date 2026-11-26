import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/supervisor_state.dart';
import '../project/project_session_registry.dart';
import '../storage/mobile_machine_store.dart';
import '../util/detached.dart';
import '../util/device_id.dart';
import 'agent_transport.dart';
import 'control_plane.dart';
import 'demo_mode.dart';
import 'eager_control_planes.dart';
import 'machine_directory.dart';
import 'new_session_picker.dart';
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

/// How long the phone stays bound to the machine it last connected to. Inside
/// it a launch goes straight back to that machine, even one that looks
/// offline — the user sees it connecting, or failing, rather than a picker
/// that hides which machine they were on. Each connection restarts it.
const Duration kMobileMachineStickyWindow = Duration(hours: 24);

/// Overridden by tests that move time past [kMobileMachineStickyWindow].
final mobileConnectionClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// A connection that stays up keeps restarting the window as its socket and
/// project list change, and leaving the foreground reports several lifecycle
/// states in a row; writing each of those to disk would buy nothing.
const Duration _kStampInterval = Duration(minutes: 1);

@immutable
class MobileConnection {
  const MobileConnection({
    this.machineId,
    this.timedOut = false,
    this.lastMachineId,
  });

  /// The machine the phone is connected or connecting to; null shows the
  /// picker.
  final String? machineId;

  /// The current attempt outlasted [kMobileConnectTimeout].
  final bool timedOut;

  final String? lastMachineId;

  MobileConnection copyWith({
    String? machineId,
    bool clearMachine = false,
    bool? timedOut,
    String? lastMachineId,
  }) => MobileConnection(
    machineId: clearMachine ? null : (machineId ?? this.machineId),
    timedOut: timedOut ?? this.timedOut,
    lastMachineId: lastMachineId ?? this.lastMachineId,
  );

  @override
  bool operator ==(Object other) =>
      other is MobileConnection &&
      other.machineId == machineId &&
      other.timedOut == timedOut &&
      other.lastMachineId == lastMachineId;

  @override
  int get hashCode => Object.hash(machineId, timedOut, lastMachineId);
}

final mobileConnectionProvider =
    NotifierProvider<MobileConnectionNotifier, MobileConnection>(
      MobileConnectionNotifier.new,
    );

class MobileConnectionNotifier extends Notifier<MobileConnection> {
  MobileMachineStore? _store;

  /// When the phone last had a connection up to
  /// [MobileConnection.lastMachineId]; null until a picked machine first
  /// connects, and once the user disconnects, so a launch then asks.
  DateTime? _connectedAt;

  @override
  MobileConnection build() {
    // Cleared first: build() re-runs on this instance when the demo switch
    // flips, and the demo must not write the real choice.
    _store = null;
    _connectedAt = null;
    if (!ref.watch(mobileConnectEnabledProvider)) {
      return const MobileConnection();
    }
    _store = ref.watch(mobileMachineStoreProvider);
    final saved = _store?.read();
    final last = saved?.lastMachineId;
    _connectedAt = saved?.connectedAt;
    // No heartbeat check: inside the window a machine that looks down is the
    // supervisor's to reach, not a reason to send the user to the picker. A
    // machine that left the account is dropped by [forget], and sign-out
    // clears the store.
    final restore = _within(_connectedAt, kMobileMachineStickyWindow)
        ? last
        : null;
    ref.listen(machineLiveConnectionProvider, (_, _) => _onLinkChanged());
    ref.listen(machineAdvertisedProjectsProvider, (_, _) => _onLinkChanged());
    return MobileConnection(machineId: restore, lastMachineId: last);
  }

  /// A time ahead of now is a clock that has since moved back; trusting it
  /// would hold [at] fresh for as long as the clock was off.
  bool _within(DateTime? at, Duration window) {
    if (at == null) return false;
    final age = ref.read(mobileConnectionClockProvider)().difference(at);
    return !age.isNegative && age < window;
  }

  /// The window starts only once [machineId] is reached: a tap on a machine
  /// the phone never gets through to must not pin the next launch to it.
  void connect(String machineId) {
    state = state.copyWith(
      machineId: machineId,
      timedOut: false,
      lastMachineId: machineId,
    );
    _connectedAt = _isConnected
        ? ref.read(mobileConnectionClockProvider)()
        : null;
    _persist();
  }

  void retry() => state = state.copyWith(timedOut: false);

  /// Ignored when [machineId] is no longer the attempt in progress — a timer
  /// started for a machine the user has since left.
  void markTimedOut(String machineId) {
    if (state.machineId != machineId || _isConnected) return;
    state = state.copyWith(timedOut: true);
  }

  /// Restarts the window while connected. Called as the app leaves the
  /// foreground: a steady connection only restarts it as often as its socket
  /// or project list changes, so a phone connected for longer than the window
  /// would otherwise come back to the picker.
  void stampIfConnected() {
    if (_isConnected) _stamp();
  }

  bool get _isConnected {
    final id = state.machineId;
    return id != null &&
        ref.read(machineLiveConnectionProvider)[id] == true &&
        ref.read(machineAdvertisedProjectsProvider)[id] != null;
  }

  void _onLinkChanged() {
    if (!_isConnected) return;
    // A timeout is a verdict on one attempt. Once the supervisor gets through
    // anyway it is spent, or the next momentary drop would land straight on
    // Couldn't connect instead of Connecting.
    if (state.timedOut) state = state.copyWith(timedOut: false);
    _stamp();
  }

  void _stamp() {
    if (_within(_connectedAt, _kStampInterval)) return;
    _connectedAt = ref.read(mobileConnectionClockProvider)();
    _persist();
  }

  void disconnect() {
    state = state.copyWith(clearMachine: true, timedOut: false);
    _connectedAt = null;
    _persist();
  }

  /// [machineId] has left the account, so the phone must not stay on it.
  void forget(String machineId) {
    if (state.machineId == machineId) disconnect();
  }

  void _persist() {
    final store = _store;
    if (store == null) return;
    final last = state.lastMachineId;
    final at = _connectedAt;
    detached(
      'MobileConnection',
      'persist failed',
      () => store.write(lastMachineId: last, connectedAt: at),
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
