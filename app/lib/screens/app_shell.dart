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
import '../providers/relay_connection.dart';
import '../providers/ui_attention_providers.dart';
import '../services/control_plane_client.dart';
import '../storage/cached_sessions_store.dart';
import '../launcher/host_control_client.dart';
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

  @override
  void initState() {
    super.initState();
    if (isMobilePlatform) {
      _mobileLifecycle = MobileLifecycleObserver(
        registry: ref.read(projectSessionRegistryProvider.notifier).registry,
        focusedProjectId: () => ref.read(selectedRegistrationIdProvider),
        backgroundDemoteDelay: kMobileBackgroundDemoteDelay,
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
  }

  @override
  void dispose() {
    _mobileLifecycle?.dispose();
    _lifecycleListener.dispose();
    super.dispose();
  }

  void _reconnectRelay() {
    ref.invalidate(licenseTokenMinterProvider);
    final notifier = ref.read(pairedAgentProvider.notifier);
    final agent = ref.read(activeAgentProvider);
    if (agent != null) {
      debugPrint('App resumed, reconnecting to relay...');
      notifier.ensureListenersRunning(agent).ignore();
    }
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

  // Periodic poll of the HOST CONTROL PLANE (desktop only) for LOCAL project
  // work status. Feeds bare-key entries into remoteProjectStatusProvider so the
  // drawer shows working/attention/error/done for projects started from mobile
  // without a loopback connection from the Windows app.
  Timer? _hostStatusTimer;

  // entryIds ('$machineUuid.$projectId') with an in-flight listSessions peek,
  // so a slow reply isn't re-requested on every subsequent advert emission for
  // the same project. See _peekProjectSessions.
  final Set<String> _seedingSessions = {};

  // Last-seen per-project advert `running`, keyed by entryId. A project-level
  // run-state transition re-peeks that project's session list so cached Recent /
  // sidebar rows track the agent's live work without a manual pull-to-refresh.
  final Map<String, bool> _lastAdvertRunning = {};

  // Last-seen per-project advert work status, keyed by entryId. `running`
  // (dialability) flips only on core register/deregister, NOT when an
  // already-registered agent starts or finishes a turn — so run-state alone
  // misses working↔done↔attention transitions. Re-peeking on a status change
  // refreshes the cached per-session `running` flags a NON-focused Recent row
  // reads (the focused project overlays its live state directly, see
  // recentSessionsProvider). Absent key = never observed (first advert).
  final Map<String, AgentWorkStatus?> _lastAdvertStatus = {};

  // Last-seen per-project advert running-session count, keyed by entryId. A
  // count change is the bridge's "the session list actually changed" signal —
  // it fires when a session starts/exits on the DESKTOP (done→working there is
  // filtered out of _lastAdvertStatus's trigger, and `running` never moves), so
  // without this the Recent row for a desktop-started session stays stale until
  // attention/error or a manual pull-to-refresh. Null value = older bridge.
  final Map<String, int?> _lastAdvertRunningCount = {};

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
    // Desktop only: periodically poll the host control plane for local project
    // work status. Mobile has no local host; skip to avoid pointless reads.
    if (!isMobilePlatform) {
      _hostStatusTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) { if (mounted) _pollLocalProjectStatus(); },
      );
    }
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
        // Socket closed → its advert can't refresh; drop the machine's live
        // status so rows fall back to session-running instead of showing stale
        // work state. Labels intentionally persist; status is cleared from both
        // the live provider and the on-disk cache so a cold boot after a
        // disconnect doesn't re-seed stale badges for an offline machine.
        ref
            .read(remoteProjectStatusProvider.notifier)
            .setMachineStatuses(uuid, const {});
        ref.read(cachedSessionsStoreProvider).clearStatusesForMachine('$uuid.');
        // Clear stale advert-delta tracking so a reconnect triggers a fresh
        // re-peek regardless of whether the new advert matches the pre-disconnect
        // snapshot (the common case — agent didn't stop during the gap).
        final prefix = '$uuid.';
        _lastAdvertRunning.removeWhere((k, _) => k.startsWith(prefix));
        _lastAdvertStatus.removeWhere((k, _) => k.startsWith(prefix));
        _lastAdvertRunningCount.removeWhere((k, _) => k.startsWith(prefix));
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
    // Fold the advert's per-project work status into the live status map (one
    // write for the whole machine, so a project dropped from the advert clears).
    // Null status (older bridge / cold project) is simply omitted → the row
    // falls back to session-running.
    final statuses = <String, AgentWorkStatus>{
      for (final ap in state.projects)
        if (ap.status != null) '$uuid.${ap.projectId}': ap.status!,
    };
    ref
        .read(remoteProjectStatusProvider.notifier)
        .setMachineStatuses(uuid, statuses);
    // Persist the new statuses so a cold boot can seed the status map before
    // the first advert arrives. Only projects in the current advert are written;
    // projects dropped from the advert are cleared via clearStatusesForMachine
    // before writing so the cache never grows with stale entries.
    store.clearStatusesForMachine('$uuid.');
    for (final e in statuses.entries) {
      store.putStatus(e.key, e.value.name);
    }
    // Peeked (never dialed) from the transport this advert already came from —
    // matches _syncLabelSubscriptions' peek-only contract; null when no live
    // socket. The eager auto-connect-everywhere design caused connection storms,
    // so this only ever reuses a socket already open for an unrelated reason.
    final cp = ref.read(controlPlaneClientForProvider(uuid)).value;
    for (final ap in state.projects) {
      final entryId = '$uuid.${ap.projectId}';
      final label = ap.label;
      if (label != null && label.isNotEmpty) {
        // Write through so the NEXT cold boot / offline visit still shows the
        // real name instead of falling back to the raw projectId.
        store.putLabel(entryId, label);
        labels.put(entryId, label);
      }
      final prevRunning = _lastAdvertRunning[entryId];
      _lastAdvertRunning[entryId] = ap.running;
      final hadStatus = _lastAdvertStatus.containsKey(entryId);
      final prevStatus = _lastAdvertStatus[entryId];
      _lastAdvertStatus[entryId] = ap.status;
      final hadCount = _lastAdvertRunningCount.containsKey(entryId);
      final prevCount = _lastAdvertRunningCount[entryId];
      _lastAdvertRunningCount[entryId] = ap.runningSessions;
      if (cp == null) continue;
      // Seed a never-synced project's sessions, OR re-peek when its advertised
      // run-state or work status flips — the bridge peek reports true per-session
      // `running`, so a cached Recent/sidebar row tracks the agent's live work
      // without a manual pull-to-refresh. A status flip (working↔done↔attention)
      // is the signal an already-registered agent started/finished a turn, which
      // never moves `running`. Without the seed, Recent would stay empty for an
      // allowed, actively-running project until the user pulls to refresh AND it
      // already has a cached row (pull-to-refresh only re-syncs known rows, see
      // refreshRecentSessions), or opens it manually.
      final neverSynced = !store.has(entryId);
      final runStateFlipped = prevRunning != null && prevRunning != ap.running;
      // Re-peek on status flip only when transitioning TO a call-to-action state
      // (attention/error). Regular working↔done cycling on a cached project never
      // changes session running flags — peeking on every turn boundary causes
      // redundant RPCs and cache writes that rebuild recentSessionsProvider each turn.
      final statusFlipped = hadStatus && prevStatus != ap.status &&
          (ap.status == AgentWorkStatus.attention ||
              ap.status == AgentWorkStatus.error);
      // Running-session count moved → the session list itself changed (a
      // session started/exited, e.g. from the desktop app). Precise where the
      // status filter above is deliberately coarse: a re-prompt cycles
      // working↔done without moving the count, so this never peeks on mere
      // turn boundaries.
      final sessionCountChanged =
          hadCount && prevCount != ap.runningSessions;
      if (neverSynced || runStateFlipped || statusFlipped ||
          sessionCountChanged) {
        _peekProjectSessions(cp, ap.projectId, entryId, store);
      }
    }
  }

  /// Peek a remote project's session list over an ALREADY-open control-plane
  /// socket and write it through to the Recent cache. Dedup-guarded via
  /// [_seedingSessions] so a slow reply isn't re-requested while in flight.
  /// Never dials — `cp` is peeked by the caller (see [_onControlPlaneState]).
  void _peekProjectSessions(
    ControlPlaneClient cp,
    String projectId,
    String entryId,
    CachedSessionsStore store,
  ) {
    if (_seedingSessions.contains(entryId)) return;
    _seedingSessions.add(entryId);
    unawaited(
      cp
          .listSessions(projectId)
          .then((sessions) => store.put(entryId, sessions))
          .catchError(
            (_) {},
          ) // offline/NOT_ALLOWED — retried on the next advert
          .whenComplete(() => _seedingSessions.remove(entryId)),
    );
  }

  /// Release every open control-plane socket whose machine is neither viewed nor
  /// backing an open project (i.e. absent from [alive]).
  void _reconcile(Set<String> alive) {
    final mgr = ref.read(relayConnectionManagerProvider);
    // A currently-open project is never a reapable control-plane socket. The
    // `openControlPlaneIds()` heuristic ("dotless id") can't tell a bare machine
    // uuid from a bare LOCAL project id, so without this guard a stray relay
    // connection accidentally materialized for a local project would be released
    // and its transport invalidated mid-open — disposing the live ProjectSession.
    final openProjects = ref.read(projectSessionRegistryProvider).toSet();
    for (final id in mgr.openControlPlaneIds()) {
      if (!alive.contains(id) && !openProjects.contains(id)) {
        mgr.release(id);
        // The control-plane client is built atop the non-autoDispose transport
        // family (controlPlaneClientForProvider watches
        // agentTransportForProvider(id).future), so the transport entry must be
        // invalidated too — otherwise a re-view rebuilds the client on the
        // released, now-dead transport (it serves the cached element instead of
        // re-running connectionFor) and the machine renders permanently offline.
        // Mirrors the registry onEvict rationale in main.dart.
        ref.invalidate(agentTransportForProvider(id));
        ref.invalidate(controlPlaneClientForProvider(id));
        ref.invalidate(controlPlaneStateProvider(id));
      }
    }
  }

  @override
  void dispose() {
    _hostStatusTimer?.cancel();
    _hostStatusTimer = null;
    for (final sub in _labelSubs.values) {
      sub.close();
    }
    _labelSubs.clear();
    super.dispose();
  }

  /// Poll the host control plane for all warm local projects and their work
  /// status, then write bare-key entries to [remoteProjectStatusProvider].
  /// Uses [peekHost] so a dead host (not yet spawned, or crashed) is a no-op
  /// rather than triggering a respawn on every timer tick.
  Future<void> _pollLocalProjectStatus() async {
    final host = ref.read(hostControllerProvider);
    final hostFile = await host.peekHost();
    if (hostFile == null) return;
    if (!mounted) return;
    final client = HostControlClient(
      port: hostFile.controlPort,
      token: hostFile.token,
    );
    try {
      final projects = await client.projectList();
      if (!mounted) return;
      final statuses = <String, AgentWorkStatus>{};
      for (final p in projects) {
        final s = AgentWorkStatus.fromWire(p.workStatus);
        if (s != null) statuses[p.projectId] = s;
      }
      ref.read(remoteProjectStatusProvider.notifier).setLocalStatuses(statuses);
    } catch (_) {
      // Host went away between peek and list — ignore; next tick will retry.
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Always mounted, so a machine de-selected in the picker (whose tab is no
    // longer rendered) is still reaped — unlike a per-tab listener. The
    // subscription itself lives in initState (see listenManual above).
    return widget.child;
  }
}
