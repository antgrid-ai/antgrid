import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/limits.dart';
import '../project/mobile_lifecycle.dart';
import '../project/project_session_registry.dart';
import '../providers/providers.dart';
import '../providers/agent_transport.dart';
import '../providers/cached_sessions.dart';
import '../providers/control_plane.dart';
import '../providers/recent_sessions.dart';
import '../providers/connection_identity.dart';
import '../providers/relay_connection.dart';
import '../providers/ui_attention_providers.dart';
import '../services/control_plane_client.dart';
import '../storage/cached_sessions_store.dart';
import '../util/ab_log.dart';
import 'new_session_screen.dart';
import 'workspace_shell.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final AppLifecycleListener _lifecycleListener;
  MobileLifecycleObserver? _mobileLifecycle;
  Future<void>? _eagerKick;
  DateTime? _lastRemint;

  /// Floor between out-of-band re-mint attempts. Eager pinning keeps a lapsed
  /// account's machines Blocked(licenseExpired) in the manager for the whole
  /// session, so `hasLicenseExpiredBlock` is persistently true there — without
  /// a cooldown every single foregrounding would cost a doomed network mint.
  static const _kRemintCooldown = Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    if (isMobilePlatform) {
      _mobileLifecycle = MobileLifecycleObserver(
        registry: ref.read(projectSessionRegistryProvider.notifier).registry,
        focusedProjectId: () => ref.read(selectedRegistrationIdProvider),
        backgroundDemoteDelay: kMobileBackgroundDemoteDelay,
        setFocusPaused: _setFocusPaused,
      );
    }
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await ref.read(preferencesServiceProvider).flush();
        return AppExitResponse.exit;
      },
      onRestart: _reconnectRelay,
      onResume: _reconnectRelay,
      onStateChange: (state) {
        _mobileLifecycle?.handleState(state);
      },
    );
    // Mobile launch: dial the recently-used machines now, so the first paint
    // shows live status and sessions instead of offline rows waiting for a
    // drawer expand (see kickEagerControlPlaneDials — no-op on desktop).
    // Post-frame so the kick's invalidates never run mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _kickEagerDials();
    });
  }

  /// One kick at a time: a single foregrounding fires both onRestart and
  /// onResume (and cold launch adds the startup resume to the post-frame
  /// kick), and a second concurrent kick would re-invalidate the providers the
  /// first one's dials are still mid-building — restarting them for nothing.
  void _kickEagerDials() {
    _eagerKick ??= kickEagerControlPlaneDials(
      RefreshRef.of(ref),
    ).whenComplete(() => _eagerKick = null);
  }

  @override
  void dispose() {
    _mobileLifecycle?.dispose();
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// Only called for ids the registry lists as open, which the session provider
  /// populates itself — so this read is a cache hit and never builds a session
  /// as a side effect of a lifecycle transition.
  void _setFocusPaused(String projectId, {required bool paused}) {
    ref
        .read(projectSessionProvider(projectId))
        .value
        ?.setLifecyclePaused(paused);
  }

  void _reconnectRelay() {
    ref.invalidate(licenseTokenMinterProvider);
    AbLog.info('AppShell', 'app resumed — re-evaluating machine ladders');
    ref.invalidate(connectionTokenMinterProvider);
    final manager = ref.read(relayConnectionManagerProvider);
    // Level-triggered: every live machine re-evaluates its ladder now instead
    // of waiting out a backoff timer the OS may have frozen while suspended.
    // Fans out to every live machine, including ones with no focused project.
    manager.noteResume();
    // noteResume() alone is a pure re-evaluate that skips a Blocked status
    // outright (ConnectionSupervisor._runOnce), so a machine sitting on
    // Blocked(licenseExpired) needs its own out-of-band re-mint to recover —
    // resume is the one place that can happen without the user pressing
    // Retry. Never wired through the ladder's own in-rung mintToken(): that
    // would reset the socket rung's backoff mid-step (see
    // ConnectionSupervisor.noteFreshToken's doc comment). Gated on an actual
    // license block so a foreground/background flap with nothing stuck never
    // costs a network mint or resets a healthy machine's backoff.
    if (manager.hasLicenseExpiredBlock &&
        (_lastRemint == null ||
            DateTime.now().difference(_lastRemint!) >= _kRemintCooldown)) {
      _lastRemint = DateTime.now();
      unawaited(_remintAndUnblock());
    }
    // Resume is "the user opened the phone" too: an eager machine that had no
    // live connection when the app was backgrounded (offline then, or a failed
    // launch dial) gets a fresh attempt now. Healthy machines are skipped
    // inside the kick — noteResume() above already re-evaluated their ladders.
    _kickEagerDials();
  }

  Future<void> _remintAndUnblock() async {
    try {
      final minter = await ref.read(connectionTokenMinterProvider.future);
      if (minter == null) return;
      await minter.mint();
    } catch (_) {
      // Best-effort: the ladder's own dial-time mint remains authoritative —
      // this only wakes a machine already stuck on Blocked(licenseExpired).
      return;
    }
    if (!mounted) return;
    ref.read(relayConnectionManagerProvider).noteFreshTokenEverywhere();
  }

  @override
  Widget build(BuildContext context) {
    return _buildAgentRouting();
  }

  Widget _buildAgentRouting() {
    final id = ref.watch(selectedRegistrationIdProvider);
    final surface = ref.watch(workbenchSurfaceProvider);
    final Widget body;
    if (id == null || surface == WorkbenchSurface.newSession) {
      body = const NewSessionScreen();
      // Landing trap: with no focused project the New Session screen renders
      // while the surface may still read `workspace` (its default, or a stale
      // value left by deselection). In that state any flow that focuses a
      // project mid-flight (selectProject in the composer's Start, the
      // drawer's "+ new session", the folder picker) instantly flips this
      // route to WorkspaceShell — unmounting the widgets that own the
      // in-flight flow and letting _bootstrapSessions hijack the outcome.
      // Reconcile the surface to `newSession` so leaving this screen always
      // requires an explicit surface write (leaveNewSession / session open).
      // appSettings is exempt: it's an overlay the user opened deliberately.
      if (id == null &&
          (surface == WorkbenchSurface.workspace ||
              surface == WorkbenchSurface.mobileDevices)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final s = ref.read(workbenchSurfaceProvider);
          if (ref.read(selectedRegistrationIdProvider) == null &&
              (s == WorkbenchSurface.workspace ||
                  s == WorkbenchSurface.mobileDevices)) {
            ref
                .read(workbenchSurfaceProvider.notifier)
                .set(WorkbenchSurface.newSession);
          }
        });
      }
    } else {
      // Ensure transport spawns; ProjectSession owns per-project services.
      ref.watch(agentTransportProvider);

      // No first-run wizard: a project without antgrid.yaml lands on the New
      // Session page (via _bootstrapSessions' empty-list route), where the agent
      // is chosen per session. antgrid.yaml's agent block is an optional default,
      // not a prerequisite, so there is nothing to gate the workspace on.
      body = const Scaffold(body: WorkspaceShell());
    }
    // Mounted across BOTH routes (picker + workspace) so a control-plane socket
    // for a machine de-selected in the picker is still reaped — the picker swaps
    // WorkspaceShell out entirely, so a reaper lower than here is unmounted
    // exactly when de-selection happens.
    return ControlPlaneReaper(child: body);
  }
}

/// Always-mounted control-plane socket reconciler. Mounted above the picker/
/// workspace route switch in [_buildAgentRouting] so it survives the route
/// child swap and observes every keep-alive change — a reaper below the switch
/// would unmount exactly when the picker tab is torn down on de-selection.
class ControlPlaneReaper extends ConsumerStatefulWidget {
  const ControlPlaneReaper({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<ControlPlaneReaper> createState() => _ControlPlaneReaperState();
}

class _ControlPlaneReaperState extends ConsumerState<ControlPlaneReaper> {
  // One control-plane-state subscription per currently-open machine, feeding
  // remoteProjectLabelsProvider. See _syncLabelSubscriptions.
  final Map<String, ProviderSubscription<AsyncValue<ControlPlaneState>>>
  _labelSubs = {};

  // entryIds ('$machineUuid.$projectId') with an in-flight listSessions seed
  // fetch, so a slow reply isn't re-requested on every subsequent advert
  // emission for the same never-cached project. See _seedNeverSyncedSessions.
  final Set<String> _seedingSessions = {};

  @override
  void initState() {
    super.initState();
    // Reconcile already-open sockets once at first mount, not only on the next
    // alive-set change. Post-frame so the invalidations don't run mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reconcile(ref.read(controlPlaneAliveTargetsProvider));
    });
    // listenManual here (not `ref.listen` in build — see the removed override
    // below): a build-time `ref.listen` forces Riverpod to synchronously flush
    // controlPlaneAliveTargetsProvider as part of Flutter's build pass. That
    // provider fans in a wide set of watched providers (session registry,
    // drawer, picker, relay) that get invalidated in bursts — e.g.
    // resetNewSessionForm's several back-to-back `.set()` calls while starting
    // a session. When the scheduler's own deferred flush for one of those
    // invalidations lands in the SAME frame as the build-time listen's forced
    // flush, Riverpod trips its reentrant-build guard: "Tried to rebuild
    // Provider<Set<String>> multiple times in the same frame" — reproduced
    // live (crash + app-wide red error screen) simply by starting a session
    // from a freshly-connected machine. listenManual subscribes through the
    // container's regular listener path instead of the build-time path, which
    // the scheduler's deferred flush already coordinates with safely.
    ref.listenManual<Set<String>>(
      controlPlaneAliveTargetsProvider,
      (prev, alive) => _reconcile(alive),
    );
    // Same rationale, same fix shape, different provider: recentSessionsProvider
    // used to `ref.watch` a control-plane state stream per known machine, in a
    // loop over a set that changed shape across rebuilds — N independently-
    // firing streams feeding one Provider reproduced live as "Tried to rebuild
    // Provider<List<RecentSessionRow>> multiple times in the same frame" during
    // Recent-tab pull-to-refresh. _syncLabelSubscriptions below owns those
    // subscriptions imperatively instead, and only for machines with an
    // ALREADY-open socket (never dials one — see remoteProjectLabelsProvider).
    _syncLabelSubscriptions();
    ref.listenManual<void>(relayConnectionChangesProvider, (prev, next) {
      if (mounted) _syncLabelSubscriptions();
    });
  }

  /// Keep [_labelSubs] in lockstep with the manager's currently-open
  /// control-plane sockets: one `controlPlaneStateProvider` subscription per
  /// open machine, closed the moment its socket closes. `listenManual` here
  /// (never `ref.watch`) is what a family member being read via `watch`
  /// avoids triggering a fresh dial — matches the peek-only contract
  /// `controlPlaneClientForProvider`'s callers rely on elsewhere.
  void _syncLabelSubscriptions() {
    final openIds = ref
        .read(relayConnectionManagerProvider)
        .openControlPlaneIds()
        .toSet();
    for (final uuid in _labelSubs.keys.toList()) {
      if (!openIds.contains(uuid)) {
        _labelSubs.remove(uuid)?.close();
      }
    }
    for (final uuid in openIds) {
      if (_labelSubs.containsKey(uuid)) continue;
      _labelSubs[uuid] = ref.listenManual<AsyncValue<ControlPlaneState>>(
        controlPlaneStateProvider(uuid),
        (prev, next) => _onControlPlaneState(uuid, next),
        fireImmediately: true,
      );
    }
  }

  void _onControlPlaneState(String uuid, AsyncValue<ControlPlaneState> next) {
    final state = next.value;
    if (state == null) return;
    final store = ref.read(cachedSessionsStoreProvider);
    final labels = ref.read(remoteProjectLabelsProvider.notifier);
    for (final ap in state.projects) {
      final label = ap.label;
      if (label == null || label.isEmpty) continue;
      final entryId = '$uuid.${ap.projectId}';
      // Write through so the NEXT cold boot / offline visit still shows the
      // real name instead of falling back to the raw projectId.
      store.putLabel(entryId, label);
      labels.put(entryId, label);
    }
    _seedNeverSyncedSessions(uuid, state, store);
  }

  /// Seed the Recent cache with a project's session list the FIRST time this
  /// machine's live advert reveals a project the phone has never synced
  /// before — otherwise Recent stays empty for an allowed, actively-running
  /// project until the user happens to pull-to-refresh AND that project
  /// already has a cached row (pull-to-refresh only re-syncs known rows, see
  /// refreshRecentSessions), or opens it manually. Never dials: `cp` is
  /// peeked from the transport this control-plane state already came from —
  /// matches _syncLabelSubscriptions' peek-only contract (the preceding
  /// eager-auto-connect-everywhere design caused connection storms; this only
  /// ever uses a socket that's already open for an unrelated reason).
  void _seedNeverSyncedSessions(
    String uuid,
    ControlPlaneState state,
    CachedSessionsStore store,
  ) {
    final cp = ref.read(controlPlaneClientForProvider(uuid)).value;
    if (cp == null) return;
    for (final ap in state.projects) {
      final entryId = '$uuid.${ap.projectId}';
      if (store.has(entryId) || _seedingSessions.contains(entryId)) continue;
      _seedingSessions.add(entryId);
      unawaited(
        cp
            .listSessions(ap.projectId)
            .then((sessions) => store.put(entryId, sessions))
            .catchError(
              (_) {},
            ) // offline/NOT_ALLOWED — retried on the next advert
            .whenComplete(() => _seedingSessions.remove(entryId)),
      );
    }
  }

  /// Release every open control-plane socket whose machine is neither viewed nor
  /// backing an open project (i.e. absent from [alive]); assert `wanted` on the
  /// survivors. See [reconcileControlPlaneWantedness] for the pure decision the
  /// widget applies its invalidations around.
  void _reconcile(Set<String> alive) {
    final mgr = ref.read(relayConnectionManagerProvider);
    // A currently-open project is never a reapable control-plane socket. The
    // `openControlPlaneIds()` heuristic ("dotless id") can't tell a bare machine
    // uuid from a bare LOCAL project id, so without this guard a stray relay
    // connection accidentally materialized for a local project would be released
    // and its transport invalidated mid-open — disposing the live ProjectSession.
    final openProjects = ref.read(projectSessionRegistryProvider).toSet();
    final released = reconcileControlPlaneWantedness(
      mgr: mgr,
      alive: alive,
      openProjects: openProjects,
    );
    for (final id in released) {
      // Always the full chain — see invalidateControlPlaneProviders for why a
      // partial invalidate leaves the machine rendering permanently offline.
      invalidateControlPlaneProviders(RefreshRef.of(ref), id);
    }
  }

  @override
  void dispose() {
    for (final sub in _labelSubs.values) {
      sub.close();
    }
    _labelSubs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Always mounted, so a machine de-selected in the picker (whose tab is no
    // longer rendered) is still reaped — unlike a per-tab listener. The
    // subscription itself lives in initState (see listenManual above).
    return widget.child;
  }
}

/// The reaper's release decision, pulled out of [_ControlPlaneReaperState] so
/// it's testable without pumping a widget tree: for every open control-plane
/// socket, feed its supervisor `wanted` — true while [alive] or an
/// [openProjects] entry claims it, false (then released) otherwise. Returns
/// the ids actually released, so the caller can invalidate their downstream
/// providers.
///
/// `setWanted(false)` is this function's OWN call, made explicitly before
/// `mgr.release(id)` rather than left to whatever `release()` happens to do
/// internally — `mgr` is an injected dependency (a test fake, or a future
/// reworking of `RelayConnectionManager`), so the ladder must not depend on a
/// release implementation detail to ever learn it was torn down on purpose.
@visibleForTesting
List<String> reconcileControlPlaneWantedness({
  required RelayConnectionManager mgr,
  required Set<String> alive,
  required Set<String> openProjects,
}) {
  final released = <String>[];
  for (final id in mgr.openControlPlaneIds()) {
    if (alive.contains(id) || openProjects.contains(id)) {
      mgr.peek(id)?.supervisor?.setWanted(true);
      continue;
    }
    mgr.peek(id)?.supervisor?.setWanted(false);
    mgr.release(id);
    released.add(id);
  }
  return released;
}
