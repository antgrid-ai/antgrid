// The remote session directory's widget half (`docs/session-messaging.md`
// §5.3-5.4): owns exactly the `Timer` and the `ref.read`/`ref.listenManual`
// calls [RemoteDirectoryPumpEngine] needs, and nothing else — every decision
// about when to push, whom to ask, and how a peer's answer is classified
// lives in `remote_directory_source.dart`, pure and testable without this
// widget.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../project/project_session_registry.dart';
import '../providers/account_agents.dart';
import '../providers/control_plane.dart';
import '../providers/device_provisioning.dart';
import '../providers/relay_connection.dart';
import '../services/account_agents_api.dart' show InventoryAgent;
import '../utils/platform_utils.dart';
import 'directory_warm_targets.dart';
import 'remote_directory_source.dart';

/// Peek [uuid]'s control-plane client without ever building or dialing it.
/// `ref.read` on a `controlPlaneClientForProvider` element that does not
/// already exist runs the provider's body — which awaits a transport that can
/// itself lazily provision a controller device and mint a token — so [ref]
/// must answer `exists` false before this ever reads it
/// (`kickEagerControlPlaneDials` in `providers/control_plane.dart` guards the
/// same way, for the same reason). `ControlPlaneReaper._syncLabelSubscriptions`
/// (`app_shell.dart`) is what normally keeps a candidate's element alive by
/// watching `controlPlaneStateProvider` for every open control-plane id; a
/// candidate this cycle finds with no element yet — or one still resolving,
/// with neither a value nor an error — has not been asked anything, so it is
/// reported [RemoteClientPending] rather than a null client, which would read
/// as "asked, got nothing" and arm a backoff no RPC earned.
@visibleForTesting
RemoteClientPeek peekControlPlaneClient(RefreshRef ref, String uuid) {
  final provider = controlPlaneClientForProvider(uuid);
  if (!ref.exists(provider)) return const RemoteClientPending();
  final state = ref.read(provider);
  if (state.hasValue) return RemoteClientResolved(state.value);
  if (state.hasError) return const RemoteClientResolved(null);
  return const RemoteClientPending();
}

/// Mounts the remote-directory pump for the app's lifetime, desktop only —
/// mobile holds no local bridge to push to. Placed beside
/// `SessionBusCarrierHost` in `app_shell.dart`, above the picker/workspace
/// route switch, so the heartbeat keeps running while the user is looking at
/// an unrelated project, or at no project at all.
class RemoteDirectoryPumpHost extends ConsumerStatefulWidget {
  const RemoteDirectoryPumpHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<RemoteDirectoryPumpHost> createState() =>
      _RemoteDirectoryPumpHostState();
}

class _RemoteDirectoryPumpHostState
    extends ConsumerState<RemoteDirectoryPumpHost> {
  final _engine = RemoteDirectoryPumpEngine();

  Timer? _timer;

  // Re-entry guard: a slow cycle (a peer near its 6s timeout) must not have a
  // second tick — heartbeat or trigger — start collecting on top of it.
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (isMobilePlatform) return;
    // Poll at the min-spacing floor; the engine decides whether a HEARTBEAT
    // or trigger is actually due each time — this timer only offers it the
    // chance. Mirrors the reaper's own poll-then-decide shape
    // (`_pollLocalProjectStatus` in `app_shell.dart`) rather than a
    // variable-interval timer that would have to be re-armed on every
    // cadence change.
    _timer = Timer.periodic(kRemoteDirectoryMinSpacing, (_) {
      if (mounted) unawaited(_tick(triggered: false));
    });
    // Off-cadence: a control-plane socket opened or was reaped — a fresh
    // candidate to ask this cycle, or one that just went away and should stop
    // being pushed. listenManual, never a build-time watch over the manager's
    // connection set — see the two crash notes on `ControlPlaneReaper` in
    // `app_shell.dart` for what a per-machine watch loop already did to this
    // app.
    ref.listenManual<void>(relayConnectionChangesProvider, (prev, next) {
      if (mounted) unawaited(_tick(triggered: true));
    });
    // Off-cadence: the open-project set changed — a session-bus link may have
    // pinned or released a peer's control plane.
    ref.listenManual<List<String>>(projectSessionRegistryProvider, (
      prev,
      next,
    ) {
      if (mounted) unawaited(_tick(triggered: true));
    });
  }

  Future<void> _tick({required bool triggered}) async {
    if (_running) return;
    _running = true;
    try {
      final now = DateTime.now();
      // Pruned before the host peek, and on the pump's tick rather than by a
      // timer of its own. A warm mark pins a peer socket past the reaper, and a
      // desktop whose local bridge went down returns from the peek below every
      // tick — pruning after it would hold those sockets for the rest of the
      // app's life.
      ref.read(directoryWarmTargetsProvider.notifier).prune(now);
      final host = ref.read(hostControllerProvider);
      final hostFile = await host.peekHost(); // peek only — never spawns
      if (!mounted || hostFile == null) return;
      final localUuid = ref.read(localDeviceUuidProvider).value;
      final openIds = ref
          .read(relayConnectionManagerProvider)
          .openControlPlaneIds();
      final candidates = remoteDirectoryCandidates(openIds, localUuid);
      final inventory =
          ref.read(accountAgentsProvider).value ?? const <InventoryAgent>[];
      final client = HostControlClient(
        port: hostFile.controlPort,
        token: hostFile.token,
      );
      final refreshRef = RefreshRef.of(ref);
      final RemoteDirectoryCycleResult? cycle;
      try {
        cycle = await _engine.maybeRunCycle(
          now: now,
          triggered: triggered,
          controlPort: hostFile.controlPort,
          candidates: candidates,
          localUuid: localUuid,
          peekClient: (uuid) => peekControlPlaneClient(refreshRef, uuid),
          inventory: inventory,
          pushFn: (machines, notConnected) => client.pushRemoteDirectory(
            machines: machines,
            notConnected: notConnected,
          ),
        );
      } finally {
        client.close();
      }
      if (!mounted || cycle == null) return;
      _warmMissedPeers(refreshRef, cycle, inventory, localUuid, now);
    } catch (_) {
      // peekHost() reads host.json off disk and can throw on a TOCTOU race;
      // the timer/listener call this unawaited, so an escaping throw is an
      // unhandled rejection every tick. Best-effort — the next tick retries.
    } finally {
      _running = false;
    }
  }

  /// An agent asked this machine something its mirror could not answer
  /// (`unservedReads`), so the peers nobody has reached become worth a socket —
  /// thin once, then real (E13, `docs/session-messaging.md`).
  ///
  /// Marking is not connecting: the warm set only stops the reaper closing what
  /// is already open, so the dial has to happen here. Both halves are bounded by
  /// the same [directoryWarmCandidates] cut, so a large account cannot turn one
  /// missed read into a connection storm.
  void _warmMissedPeers(
    RefreshRef refreshRef,
    RemoteDirectoryCycleResult cycle,
    Iterable<InventoryAgent> inventory,
    String? localUuid,
    DateTime now,
  ) {
    if (cycle.ack.unservedReads <= 0) return;
    // Re-read rather than reusing this tick's candidates: the cycle awaited a
    // per-machine timeout on every peer it asked, and a socket can have opened
    // or closed in that time.
    final open = ref.read(relayConnectionManagerProvider).openControlPlaneIds();
    final missed = directoryWarmCandidates(inventory, localUuid, open);
    if (missed.isEmpty) return;
    ref.read(directoryWarmTargetsProvider.notifier).warm(missed, now);
    // Not awaited: an offline machine's dial walks the supervisor's whole
    // reconnect ladder, and this tick still owns the re-entry guard — waiting
    // on it would stop the directory being pushed at all for as long as the
    // slowest unreachable peer takes to give up. The warm mark above is what
    // the reaper reads, and it is already written.
    unawaited(refreshControlPlanes(refreshRef, missed));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
