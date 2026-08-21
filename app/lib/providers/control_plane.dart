import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../connection/supervisor_state.dart';
import '../launcher/host_controller.dart';
import '../launcher/local_agent_launcher.dart';
import '../project/project_session_registry.dart';
import '../services/control_plane_client.dart';
import '../util/device_id.dart';
import 'account_agents.dart';
import 'agent_transport.dart';
import 'drawer_expansion.dart';
import 'eager_control_planes.dart';
import 'new_session_picker.dart';
import 'provider_retry.dart';
import 'relay_connection.dart';
import 'ui_attention_providers.dart';

/// The machine-level loopback host controller (singleton; spawns/attaches the
/// host daemon and hands out a verified port+token via `ensureHost`).
final hostControllerProvider = Provider<HostController>(
  (_) => LocalAgentLauncher.sharedHost,
);

/// A [ControlPlaneClient] bound to the relay control plane of the remote machine
/// identified by [bareDeviceUuid]. Reuses `agentTransportForProvider(uuid)` —
/// because `autoOpen` registers `agentDeviceId == deviceUuid`, that transport IS
/// the bare-deviceUuid control-plane connection. Returns null when no transport
/// can be built (unknown/offline target). Lazily built on first watch; the
/// client is disposed on teardown, the transport is owned by the transport
/// provider.
final controlPlaneClientForProvider = FutureProvider.family<ControlPlaneClient?, String>((
  ref,
  bareDeviceUuid,
) async {
  final transport = await ref.watch(
    agentTransportForProvider(bareDeviceUuid).future,
  );
  if (transport == null) return null;
  // Reactive offline: the relay transport never emits a disconnect, so feed
  // the client the machine socket's peer-presence. In v3 the phone's socket is
  // NOT cascade-closed when the agent drops — the relay sends
  // `peer-offline` (which keeps the socket `paired`), so presence must key on
  // the peer-presence stream, not the connection state. `RelayService` emits
  // false on both `peer-offline` and a raw socket drop, so a `false` here
  // means the agent is unreachable either way and the client clears its stale
  // advert (picker/drawer flip to offline WITHOUT a manual refresh); the live
  // stream repopulates it when the agent re-adverts.
  //
  // peek (not connectionFor): the transport above already materialized this
  // connection; a null peek just means no live socket → no presence to feed.
  final conn = ref.read(relayConnectionManagerProvider).peek(bareDeviceUuid);
  final presence = conn?.relay.peerPresenceStream;
  final client = ControlPlaneClient(
    transport: transport,
    peerPresence: presence,
  );
  ref.onDispose(client.dispose);
  return client;
  // retry: an offline/mid-reconnect target throws while resolving its
  // transport above; that error must reject `.future` so the refresh helpers
  // catch it and force a fresh attempt — Riverpod 3's default would instead
  // retry silently and leave `.future` pending. See provider_retry.dart.
}, retry: noProviderRetry);

/// The live [ControlPlaneState] stream for [bareDeviceUuid] (projects + tools),
/// so consumers rebuild as `agent:tools` / `agent:projects` arrive. Emits the
/// client's current state first, then every update.
final controlPlaneStateProvider = StreamProvider.family<ControlPlaneState, String>((
  ref,
  bareDeviceUuid,
) async* {
  final client = await ref.watch(
    controlPlaneClientForProvider(bareDeviceUuid).future,
  );
  if (client == null) {
    yield const ControlPlaneState();
    return;
  }
  yield client.currentState;
  yield* client.stateStream;
  // retry: mirror controlPlaneClientForProvider — a failed client resolution
  // must surface, not be retried behind the consumer. See provider_retry.dart.
}, retry: noProviderRetry);

/// The slice of [WidgetRef] / [ProviderContainer] the refresh helpers below
/// need. The two share no common Riverpod supertype, so this tiny adapter keeps
/// the helpers analyzer-checked (vs. `dynamic`) while still accepting a widget
/// ref in production and a bare container in tests. Construct with
/// [RefreshRef.of] (widgets) or [RefreshRef.ofContainer] (tests).
abstract interface class RefreshRef {
  T read<T>(ProviderListenable<T> provider);
  void invalidate(ProviderOrFamily provider);

  /// Whether [provider] currently has a live element. Lets a helper inspect a
  /// family member's cached state without `read`'s side effect of building it.
  bool exists(ProviderBase<Object?> provider);

  /// False once the underlying widget has unmounted (always true for the
  /// container variant — tests own their container's lifecycle directly).
  /// The refresh helpers below re-check this after every `await`: they run
  /// from a `RefreshIndicator.onRefresh` gesture, which keeps running even
  /// after the triggering widget is gone (navigated away, rebuilt out), and a
  /// `WidgetRef` read past that point throws.
  bool get mounted;

  factory RefreshRef.of(WidgetRef ref) = _WidgetRefreshRef;
  factory RefreshRef.ofContainer(ProviderContainer container) =
      _ContainerRefreshRef;
}

class _WidgetRefreshRef implements RefreshRef {
  _WidgetRefreshRef(this._ref);
  final WidgetRef _ref;
  @override
  T read<T>(ProviderListenable<T> provider) => _ref.read(provider);
  @override
  void invalidate(ProviderOrFamily provider) => _ref.invalidate(provider);
  @override
  bool exists(ProviderBase<Object?> provider) => _ref.exists(provider);
  @override
  bool get mounted => _ref.context.mounted;
}

class _ContainerRefreshRef implements RefreshRef {
  _ContainerRefreshRef(this._container);
  final ProviderContainer _container;
  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);
  @override
  void invalidate(ProviderOrFamily provider) => _container.invalidate(provider);
  @override
  bool exists(ProviderBase<Object?> provider) => _container.exists(provider);
  @override
  bool get mounted => true;
}

/// Re-pull the live control-plane project/tool advert for each machine in
/// [uuids], the manual counterpart to the connect-time `state.snapshot`. Backs
/// the picker and drawer pull-to-refresh.
///
/// Each machine is guarded independently: resolving its transport can THROW
/// (the FutureProvider drives connect → pair → v2 handshake, which rejects for
/// an offline / mid-reconnect machine), and `ControlPlaneClient.refresh()` is
/// throw-safe but the provider read above it is not. Swallowing per-machine
/// keeps one bad socket from aborting the others or escaping into the
/// RefreshIndicator gesture (its `onRefresh` must not complete with an error).
Future<void> refreshControlPlanes(
  RefreshRef ref,
  Iterable<String> uuids,
) async {
  await Future.wait(
    uuids.map((uuid) async {
      try {
        final client = await ref.read(
          controlPlaneClientForProvider(uuid).future,
        );
        if (client != null) await _probeAndReconcile(client);
      } catch (_) {
        // Offline / mid-reconnect machine — skip; the others still refresh.
      }
    }),
  );
}

/// Pull-to-refresh's probe-and-reconcile step: re-pull the live advert, and if
/// the peer no longer serves the snapshot RPC, clear its now-stale advert so the
/// picker/drawer flip to offline (an unreachable peer's last advert would
/// otherwise read as "online"). The connection is KEPT either way — the relay
/// transport reports "connected" even for a silent peer, and the connection's
/// repair handshake re-adverts if the peer returns, so tearing it down here
/// would forfeit auto-recovery. Genuine disconnects are handled reactively by
/// the client's `peerPresence`; this only covers the alive-socket-silent-agent
/// window before the relay's dead-detection closes it.
Future<void> _probeAndReconcile(ControlPlaneClient client) async {
  if (!await client.refresh()) client.clearAdvert();
}

/// Invalidates the full per-machine control-plane provider chain
/// (transport → client → state) together. Always all three: the client is
/// built atop the non-autoDispose transport family, so invalidating it alone
/// rebuilds atop the cached — possibly released and dead — transport (it
/// serves the cached element instead of re-running connectionFor) and the
/// machine renders permanently offline. Mirrors the registry onEvict rationale
/// in main.dart.
void invalidateControlPlaneProviders(RefreshRef ref, String uuid) {
  ref.invalidate(agentTransportForProvider(uuid));
  ref.invalidate(controlPlaneClientForProvider(uuid));
  ref.invalidate(controlPlaneStateProvider(uuid));
}

/// Upper bound a refresh gesture waits on any one machine's dial. The dial
/// itself keeps going past this — the supervisor owns it — the gesture just
/// stops riding the outcome. Above the ~6s an offline agent needs to reject,
/// far below awaitSession's 90s relay-unreachable worst case, which would
/// otherwise pin the RefreshIndicator (eager targets put unviewed machines in
/// the refreshed set).
const _kRefreshDialWait = Duration(seconds: 8);

/// Refresh machine inventory, then force a fresh control-plane attempt for the
/// requested machines. This is the manual "device may have come online" path:
/// an earlier offline attempt can leave the transport/client providers in an
/// error state, so simply reading them again would replay the stale failure.
Future<void> refreshMachineInventoryAndControlPlanes(
  RefreshRef ref,
  Iterable<String?> uuids,
) async {
  ref.invalidate(accountAgentsProvider);
  try {
    await ref.read(accountAgentsProvider.future);
  } catch (_) {
    // Keep the gesture best-effort: an inventory error should not prevent
    // already-known/paired machines from retrying their live control plane.
  }
  if (!ref.mounted) return;

  final targets = uuids.whereType<String>().toSet();
  final relayManager = ref.read(relayConnectionManagerProvider);
  await Future.wait(
    targets.map((uuid) async {
      try {
        // A mid-climb machine leaves this read pending until its dial settles;
        // the timeout throws into the catch below, forcing the fresh attempt.
        final client = await ref
            .read(controlPlaneClientForProvider(uuid).future)
            .timeout(_kRefreshDialWait);
        if (client != null) {
          await _probeAndReconcile(client);
          return;
        }
      } catch (_) {
        // Fall through to a fresh connection attempt below.
      }
      if (!ref.mounted) return;

      // A machine can sit Connected UNDER a stale cached rejection (a failed
      // eager launch dial that later self-recovered via peer presence).
      // Releasing it would kill the live E2E session and every project stream
      // riding the socket — and the invalidate + re-read below succeeds on the
      // live connection anyway, so only a not-connected machine is torn down
      // for its fresh attempt.
      if (relayManager.peek(uuid)?.supervisor?.status is! Connected) {
        relayManager.release(uuid);
      }
      invalidateControlPlaneProviders(ref, uuid);
      await refreshControlPlanes(ref, [
        uuid,
      ]).timeout(_kRefreshDialWait, onTimeout: () {});
    }),
  );
}

/// Dial every eager target (see [eagerControlPlaneTargetsProvider]) so opening
/// the phone shows live machine status and session lists without a drawer
/// expand or pull-to-refresh first. Runs at app launch and again on resume.
///
/// Per machine, three states:
///   - No connection: dial it (invalidating first — the providers may hold a
///     stale rejection from an attempt that never materialized a socket).
///   - Live connection whose provider chain is healthy, still building, or was
///     never built: skip — the supervisor owns in-flight recovery, and a kick
///     here would only churn it.
///   - Live connection whose chain SETTLED on a cached rejection
///     (noProviderRetry): repair it. This is the failed-at-launch machine —
///     the dial materialized the connection before awaitSession threw, so a
///     bare peek-skip would strand the cached error forever. A Connected
///     machine keeps its socket (the rebuilt read rides the live session); a
///     stuck ladder is released first so the redial is a genuinely fresh
///     attempt — resume/presence never re-enter a Blocked ladder on their own.
///
/// Failures are swallowed per machine: the drawer still renders from cache,
/// and pull-to-refresh remains the manual retry — the eager targets sit in the
/// reaper's alive set, so refreshDrawer force-retries them too.
Future<void> kickEagerControlPlaneDials(RefreshRef ref) async {
  final targets = ref.read(eagerControlPlaneTargetsProvider);
  if (targets.isEmpty) return;
  final mgr = ref.read(relayConnectionManagerProvider);
  await Future.wait(
    targets.map((uuid) async {
      final existing = mgr.peek(uuid);
      if (existing != null) {
        final clientProvider = controlPlaneClientForProvider(uuid);
        // exists() first: read() would build a never-watched member as a side
        // effect, and a connection with no built chain has nothing to repair.
        if (!ref.exists(clientProvider)) return;
        final cached = ref.read(clientProvider);
        // isLoading covers a rebuild in flight — Riverpod retains the previous
        // error while refreshing, so hasError alone would misread it as stale.
        if (cached.isLoading || !cached.hasError) return;
        if (existing.supervisor?.status is! Connected) mgr.release(uuid);
      }
      invalidateControlPlaneProviders(ref, uuid);
      try {
        await ref.read(controlPlaneClientForProvider(uuid).future);
      } catch (_) {
        // Offline / unreachable machine — leave it to the manual refresh path.
      }
    }),
  );
}

/// Bare deviceUuids whose control-plane socket should stay open right now: the
/// picker's viewed machine (if any), the focused remote target, every machine
/// backing >=1 open project, and every expanded remote MACHINE row. The reaper
/// releases any open control-plane socket NOT in this set. Computed centrally
/// (not per-tab/per-row) so de-selecting a machine — or collapsing its drawer
/// row — is observed even though its picker tab / sessions subtree is no longer
/// rendered.
final controlPlaneAliveTargetsProvider = Provider<Set<String>>((ref) {
  ref.watch(projectSessionRegistryProvider); // rebuild on open-set changes
  final expanded = ref.watch(expandedDrawerIdsProvider);
  final alive = ref
      .read(projectSessionRegistryProvider.notifier)
      .machinesWithOpenProjects();
  // Selection changes before ProjectSession finishes opening and touching the
  // registry. Pin the selected remote's machine during that gap; otherwise the
  // reaper closes the control plane immediately after project selection, before
  // promotion/data-plane setup can settle. This also keeps a focused remote's
  // control plane available for retry and status operations after an open error.
  final focusedTarget = ref.watch(selectedTargetProvider);
  if (focusedTarget != null && !focusedTarget.isLocal) {
    alive.add(baseDeviceUuid(focusedTarget.registrationId));
  }
  // The New Session picker is the only surface that views a machine's control
  // plane directly (it's shown when no project is selected or the surface is
  // explicitly New Session — mirrors app_shell's route switch). Pin the viewed
  // machine ONLY while that surface is live: off-screen, the picker's fallback
  // source would otherwise hold a socket open forever. That fallback bites on
  // mobile especially, where there is no Local tab, so the default 'local'
  // selection resolves `visiblePickerSource` to the first MACHINE.
  final pickerVisible =
      ref.watch(selectedRegistrationIdProvider) == null ||
      ref.watch(workbenchSurfaceProvider) == WorkbenchSurface.newSession;
  if (pickerVisible) {
    // The New Session canvas shows the recent-sessions list alongside the
    // composer's machine picker, and Recents has no single "viewed" machine —
    // while the surface is visible, pin whatever control-plane sockets are
    // ALREADY open (never dials any itself) so one that a pull-to-refresh just
    // opened isn't reaped before the user gets to act on it.
    //
    // Reads the connection manager directly rather than through
    // recentSessionsProvider: recentSessionsProvider watches
    // controlPlaneStateProvider, which THIS reaper invalidates for any
    // socket that falls out of the alive set. Routing the alive set itself
    // through recentSessionsProvider would feed that invalidation straight
    // back into its own dependency chain — Riverpod caught exactly this as
    // "tried to rebuild Provider<List<RecentSessionRow>> multiple times in
    // the same frame" when this was tried.
    ref.watch(relayConnectionChangesProvider);
    alive.addAll(
      ref.watch(relayConnectionManagerProvider).openControlPlaneIds(),
    );
    // The machine the picker actually renders (the selection, or its first-
    // source fallback when the selection is stale/default). Kept alive while
    // the picker shows it — including mid-reload, when it covers the visible
    // fallback that an inventory refresh could momentarily drop.
    final viewedMachine = ref.watch(visiblePickerSourceProvider)?.machineUuid;
    if (viewedMachine != null) alive.add(viewedMachine);
    // Anchor on the explicitly-selected machine too: a refresh can briefly
    // fall `visiblePickerSource` off it (no retained inventory after a prior
    // error), and that machine's own pull-to-refresh must not reap-flap the
    // very socket it is refreshing.
    final selectedMachine = machineUuidFromSourceId(
      ref.watch(selectedSourceIdProvider),
    );
    if (ref.watch(accountAgentsProvider).isLoading && selectedMachine != null) {
      alive.add(selectedMachine);
    }
  }
  // An expanded drawer machine row subscribes to its control-plane advert, so
  // its socket must stay alive or the reaper would tear it down and the row
  // would flap reconnecting. Only bare-uuid (machine) ids count — the dotted
  // project sub-row ids are data-plane sessions, governed by the warm registry.
  for (final id in expanded) {
    if (!id.contains('.')) alive.add(id);
  }
  // Mobile's proactive launch/resume dials (see [kickEagerControlPlaneDials]):
  // eager machines are wanted the moment the app opens, before any selection
  // or expansion exists to claim them. Without this union the reaper would
  // close each eager socket moments after the kick opened it.
  alive.addAll(ref.watch(eagerControlPlaneTargetsProvider));
  return alive;
});
