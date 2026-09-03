import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../project/limits.dart';
import '../project/mobile_lifecycle.dart';
import '../project/project_session_registry.dart';
import '../providers/providers.dart';
import '../providers/account_agents.dart';
import '../providers/agent_catalog.dart';
import '../providers/agent_transport.dart';
import '../providers/cached_sessions.dart';
import '../providers/control_plane.dart';
import '../providers/device_revocation.dart';
import '../providers/recent_sessions.dart';
import '../providers/connection_identity.dart';
import '../providers/device_provisioning.dart';
import '../providers/projects.dart';
import '../providers/relay_connection.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../services/control_plane_client.dart';
import '../storage/cached_sessions_store.dart';
import '../launcher/host_control_client.dart';
import '../navigation/back_intent.dart';
import '../util/ab_log.dart';
import '../design/widgets/ab_window_controls.dart';
import '../widgets/window_title_bar.dart';
import '../window/window_capabilities.dart';
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
    // Cold start: nothing else would notice a device revoked while the app was
    // closed — the session cookie outlives the device row, so the account still
    // resolves and desktop may never dial a relay at all.
    unawaited(checkDeviceRevoked(ref.container));
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
  ///
  /// Resuming also RESTATES which session is on screen. Backgrounding releases
  /// the bridge's focus (that is what lets a turn finishing in your pocket come
  /// back unread — see `clientFocusState` in work-status.ts), and the bridge
  /// deliberately doesn't restore it on its own: only the app knows whether the
  /// session it left on screen is still the one on screen. Without the restate,
  /// the very session the user is looking at when they come back would wear the
  /// unread dot it earned while they were away, and nothing short of navigating
  /// away and back would clear it.
  void _setFocusPaused(String projectId, {required bool paused}) {
    final session = ref.read(projectSessionProvider(projectId)).value;
    session?.setLifecyclePaused(paused);
    if (paused || session == null) return;
    if (ref.read(selectedRegistrationIdProvider) != projectId) return;
    // `activeSessionIdProvider` is the last session PICKED, not the thing on
    // screen: it survives a walk over to New Session or Settings, so restating
    // it from those surfaces would vouch for a session the user cannot see and
    // silently exempt it from unread.
    if (ref.read(workbenchSurfaceProvider) != WorkbenchSurface.workspace) {
      return;
    }
    final active = ref.read(activeSessionIdProvider);
    if (active != null) session.sessionsService.focus(active);
  }

  void _reconnectRelay() {
    // Own cooldown inside; a revoke that landed while backgrounded has no other
    // way in on a machine whose ladder is already Blocked.
    unawaited(checkDeviceRevoked(ref.container));
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
    return AppBackScope(child: _buildShell(context));
  }

  Widget _buildShell(BuildContext context) {
    // DEC-1004 focus routing for agent terminals. Bound HERE and not inside
    // WorkspaceShell because the binder is keep-alive and WorkspaceShell is
    // swapped out whole by the New Session route: with its only listener gone
    // the binder keeps its element but stops flushing, and its terminal
    // dependencies drift stale behind it. The next mount's first `watch` then
    // flushes that chain from inside build(), the changed dependency
    // re-invalidates the binder, and riverpod schedules the refresh by calling
    // setState on the ProviderScope — mid-build, which throws. Any host that
    // survives the picker/workspace swap keeps the chain fresh; this is the
    // nearest one.
    ref.watch(agentFocusBinderProvider);
    final routed = _buildAgentRouting();
    // Mounted here rather than inside WorkspaceShell because the OS bar is
    // hidden process-wide (initDesktopWindowChrome): any full-window route
    // that renders without the bar strands the user with no drag region and
    // no close button. From here it covers NewSessionScreen and every
    // WorkspaceShell early return (blocking error, boot status) alike.
    //
    // Nothing may take vertical space above it on macOS: AppKit positions the
    // traffic lights in window coordinates and they do not move with Flutter
    // layout.
    // Touch platform (Android/iOS) never gets this bar, at ANY width — a real
    // tablet stays a tablet at 1024px (same rationale as _defaultPanelMode in
    // workspace_shell.dart), and there is no mouse to drive the back/forward
    // chevrons or the inline search field with. WorkspaceShell and
    // NewSessionScreen give touch devices swipeable Drawer/endDrawer overlays
    // for the sidebar and context panel instead of this row's toggle icons.
    //
    // A narrow DESKTOP window (mouse-driven, < kMediumBreakpoint) drops the
    // bar's CONTENTS — WorkspaceShell and NewSessionScreen keep their own
    // persistent-sidebar desktop layout there (that split stays at
    // kCompactBreakpoint) and reach nav/search their own way — but it must
    // still get the bar itself wherever we own the window chrome, for the
    // reason stated at the top of this comment: the OS bar is hidden
    // process-wide and `AbWindowControls` and the drag region live nowhere
    // else, so returning the bare route would leave a window that cannot be
    // moved or closed. 640x400 is the enforced minimum size
    // (`initDesktopWindowChrome`), well inside this band, so it is reachable
    // by an ordinary resize. Same chrome-only bar the auth splash uses.
    //
    // Each route wraps its own content in SafeArea, so touch insets are still
    // consumed either way.
    if (isMobilePlatform) return routed;
    final narrow = MediaQuery.sizeOf(context).width < kMediumBreakpoint;
    if (narrow && !appOwnsWindowChrome) return routed;
    // Non-touch desktop platform from here down — system insets are always
    // zero here (no OS status bar or cutout to clear on Windows/macOS/Linux),
    // so nothing below needs to consume any.
    return ColoredBox(
      // The inset strips fall outside the bar's own Container, so without this
      // the bare route background shows through them.
      color: context.antgrid.bgDeepest,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            WindowTitleBar(
              child: narrow
                  ? const Row(children: [Spacer(), AbWindowControls()])
                  : const WindowTitleBarContents(),
            ),
            Expanded(child: routed),
          ],
        ),
      ),
    );
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
              surface == WorkbenchSurface.remoteDevices)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final s = ref.read(workbenchSurfaceProvider);
          if (ref.read(selectedRegistrationIdProvider) == null &&
              (s == WorkbenchSurface.workspace ||
                  s == WorkbenchSurface.remoteDevices)) {
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

  // True while a _pollLocalProjectStatus round-trip is in flight, so a tick
  // that fires before the previous one returns is skipped rather than risking
  // a slower, earlier-started poll overwriting a faster, later one with stale
  // statuses (setLocalStatuses is a full replace, not a merge).
  bool _pollingLocalStatus = false;

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

  // controlPort of the host whose agent catalog has already been folded into
  // agentCatalogProvider. The catalog is static per bridge BUILD, so one
  // tools:list per host process is enough — but a host that restarted may be a
  // newer binary with new agents, and its port is the cheapest proxy for "a
  // different process" available on the poll path.
  int? _catalogSyncedPort;

  // Throttle for the local project-catalog backfill below — unlike the
  // per-tick work-status poll, a new local project (e.g. one opened by a
  // remote-control session on THIS machine, which lands in the bridge's
  // seen-catalog with no local "Open folder…" ever running) is rare enough
  // that a full phones:list round-trip every 2s buys nothing.
  static const _kProjectBackfillInterval = Duration(seconds: 15);
  DateTime? _lastProjectBackfillAt;

  // Last-seen per-project advert running-session count, keyed by entryId. A
  // count change is the bridge's "the session list actually changed" signal —
  // it fires when a session starts/exits on the DESKTOP (done→working there is
  // filtered out of _lastAdvertStatus's trigger, and `running` never moves), so
  // without this the Recent row for a desktop-started session stays stale until
  // attention/error or a manual pull-to-refresh. Null value = older bridge.
  final Map<String, int?> _lastAdvertRunningCount = {};

  // Last-seen per-project advert `lastActiveAt`, keyed by entryId. The bridge
  // bumps this on ANY session-list identity change — rename, create, archive,
  // delete — not just the running-state/status/count moves the three maps
  // above cover. Without it, a rename on an idle session (nothing running,
  // nothing to flip) never re-peeks a cold project: a device that has this
  // project's drawer row collapsed keeps showing the pre-rename cached name
  // forever, since nothing else here would ever differ. Null value = older
  // bridge / never advertised.
  final Map<String, String?> _lastAdvertLastActiveAt = {};

  @override
  void initState() {
    super.initState();
    // Reconcile already-open sockets once at first mount, not only on the next
    // alive-set change. Post-frame so the invalidations don't run mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(controlPlaneResetProvider.notifier).set(_resetForSignOut);
      _reconcile(ref.read(controlPlaneAliveTargetsProvider));
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
      _hostStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) _pollLocalProjectStatus();
      });
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
        // status so rows read "done" (no advert) instead of showing stale work
        // state. Labels intentionally persist; status is cleared from both
        // the live provider and the on-disk cache so a cold boot after a
        // disconnect doesn't re-seed stale badges for an offline machine.
        //
        // BOTH maps, always: the per-session map takes priority over the
        // project one (see sessionRowStatus), so clearing only the project
        // status would leave every session row pulsing its last "working" on a
        // machine we're no longer connected to — the very badge the project
        // clear exists to retire, now unclearable.
        ref
            .read(remoteProjectStatusProvider.notifier)
            .setMachineStatuses(uuid, const {});
        ref
            .read(remoteSessionStatusProvider.notifier)
            .setMachineSessionStatuses(uuid, const {});
        // The advert-count map must stay honest for a disconnected machine —
        // the first-run checklist's persisted latch keeps its step CHECKED,
        // but any live consumer must see this machine advertising nothing.
        ref.read(machineAdvertisedProjectsProvider.notifier).clear(uuid);
        ref.read(cachedSessionsStoreProvider).clearStatusesForMachine('$uuid.');
        // Clear stale advert-delta tracking so a reconnect triggers a fresh
        // re-peek regardless of whether the new advert matches the pre-disconnect
        // snapshot (the common case — agent didn't stop during the gap).
        final prefix = '$uuid.';
        _lastAdvertRunning.removeWhere((k, _) => k.startsWith(prefix));
        _lastAdvertStatus.removeWhere((k, _) => k.startsWith(prefix));
        _lastAdvertRunningCount.removeWhere((k, _) => k.startsWith(prefix));
        _lastAdvertLastActiveAt.removeWhere((k, _) => k.startsWith(prefix));
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

  /// Drops every piece of account-derived in-memory state this reaper owns.
  /// Published via [controlPlaneResetProvider] so [performHardSignOut] has one
  /// call instead of hand-listing this fan-in — see that provider's doc.
  ///
  /// `_catalogSyncedPort` reset is what makes the LOCAL bridge's agent catalog
  /// re-populate after a sign-out + re-sign-in with the bridge process still
  /// running on the same port: without it, [_pollLocalProjectStatus] believes
  /// the (just-invalidated) catalog is already synced for that port and never
  /// re-issues `tools:list`, leaving every local-project agent capability
  /// unknown until the bridge or app restarts.
  void _resetForSignOut() {
    _catalogSyncedPort = null;
    _lastAdvertRunning.clear();
    _lastAdvertStatus.clear();
    _lastAdvertRunningCount.clear();
    _lastAdvertLastActiveAt.clear();
    _seedingSessions.clear();
    for (final sub in _labelSubs.values) {
      sub.close();
    }
    _labelSubs.clear();
    ref.invalidate(accountAgentsProvider);
    ref.invalidate(agentCatalogProvider);
    ref.invalidate(remoteProjectLabelsProvider);
    ref.invalidate(remoteProjectStatusProvider);
    ref.invalidate(remoteSessionStatusProvider);
  }

  void _onControlPlaneState(String uuid, AsyncValue<ControlPlaneState> next) {
    final state = next.value;
    if (state == null) return;
    // Fold this machine's agent catalog in. Single-writer, like the status maps
    // below: a per-machine `ref.watch` fan-in is what reproduced Riverpod's
    // "rebuilt multiple times in the same frame" crash. Merging across machines
    // is sound because the descriptor is a projection of the bridge's static
    // registry, not a fact about this box.
    ref.read(agentCatalogProvider.notifier).merge(state.agents);
    final store = ref.read(cachedSessionsStoreProvider);
    final labels = ref.read(remoteProjectLabelsProvider.notifier);
    // Fold the advert's per-project work status into the live status map (one
    // write for the whole machine, so a project dropped from the advert clears).
    // Null status (older bridge / cold project) is simply omitted → the row
    // reads "done", the only honest answer without an advert.
    final statuses = <String, AgentWorkStatus>{
      for (final ap in state.projects)
        if (ap.status != null) '$uuid.${ap.projectId}': ap.status!,
    };
    ref
        .read(remoteProjectStatusProvider.notifier)
        .setMachineStatuses(uuid, statuses);
    // Advert summary for the mobile first-run checklist's "Remote is on" step
    // — same single-writer discipline as the status maps above.
    ref.read(machineAdvertisedProjectsProvider.notifier).setAdvert(uuid, (
      projectCount: state.projects.length,
      remoteAccessEnabled: state.remoteAccessEnabled,
    ));
    // Same fold for the per-session map the session rows dot themselves from.
    // Absent (older bridge / cold project) stays absent — that's what tells the
    // rows to fall back to the project status above.
    ref
        .read(remoteSessionStatusProvider.notifier)
        .setMachineSessionStatuses(uuid, {
          for (final ap in state.projects)
            if (ap.sessionStatuses != null)
              '$uuid.${ap.projectId}': ap.sessionStatuses!,
        });
    // Persist the new statuses so a cold boot can seed the status map before
    // the first advert arrives. Only projects in the current advert are written;
    // projects dropped from the advert are cleared via clearStatusesForMachine
    // before writing so the cache never grows with stale entries.
    //
    // `unread` is never written. It is READ STATE, and the bridge is the only
    // thing that holds it (see work-status.ts) — writing a copy here would give
    // the app a second, authoritative-looking answer that goes stale the moment
    // someone opens the session from another device, and a restart would replay
    // blue dots for answers already read. A dropped `unread` costs nothing: the
    // advert restates it within a tick of the socket dialing.
    store.clearStatusesForMachine('$uuid.');
    for (final e in statuses.entries) {
      if (e.value == AgentWorkStatus.unread) continue;
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
      final hadLastActiveAt = _lastAdvertLastActiveAt.containsKey(entryId);
      final prevLastActiveAt = _lastAdvertLastActiveAt[entryId];
      _lastAdvertLastActiveAt[entryId] = ap.lastActiveAt;
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
      final statusFlipped =
          hadStatus &&
          prevStatus != ap.status &&
          (ap.status == AgentWorkStatus.attention ||
              ap.status == AgentWorkStatus.error);
      // Running-session count moved → the session list itself changed (a
      // session started/exited, e.g. from the desktop app). Precise where the
      // status filter above is deliberately coarse: a re-prompt cycles
      // working↔done without moving the count, so this never peeks on mere
      // turn boundaries.
      final sessionCountChanged = hadCount && prevCount != ap.runningSessions;
      // `lastActiveAt` moves on a rename/create/archive/delete too — the bridge
      // bumps it on every session-identity change, not just an open (see
      // host-server.ts's onSessionsChange wiring) — so this is what catches an
      // idle session getting renamed, which flips neither running, status, nor
      // the count above.
      final lastActiveAtChanged =
          hadLastActiveAt && prevLastActiveAt != ap.lastActiveAt;
      if (neverSynced ||
          runStateFlipped ||
          statusFlipped ||
          sessionCountChanged ||
          lastActiveAtChanged) {
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
    _hostStatusTimer?.cancel();
    _hostStatusTimer = null;
    for (final sub in _labelSubs.values) {
      sub.close();
    }
    _labelSubs.clear();
    try {
      ref.read(controlPlaneResetProvider.notifier).set(null);
    } catch (_) {
      // Container may already be torn down (app shutdown) — nothing to
      // retract.
    }
    super.dispose();
  }

  /// Poll the host control plane for all warm local projects and their work
  /// status, then write bare-key entries to [remoteProjectStatusProvider].
  /// Uses [peekHost] so a dead host (not yet spawned, or crashed) is a no-op
  /// rather than triggering a respawn on every timer tick.
  Future<void> _pollLocalProjectStatus() async {
    if (_pollingLocalStatus) return;
    _pollingLocalStatus = true;
    try {
      final host = ref.read(hostControllerProvider);
      final hostFile = await host.peekHost();
      if (!mounted) return;
      // No host → no local project is running anything, so the same rule as a
      // closed relay socket applies: retire the live status rather than leave a
      // crashed host's last "working" pulsing until it comes back.
      if (hostFile == null) {
        ref
            .read(remoteProjectStatusProvider.notifier)
            .setLocalStatuses(const {});
        ref
            .read(remoteSessionStatusProvider.notifier)
            .setLocalSessionStatuses(const {});
        return;
      }
      final client = HostControlClient(
        port: hostFile.controlPort,
        token: hostFile.token,
      );
      // One `finally` for the whole client, not one per request: both blocks
      // below bail early on `!mounted`, and a close reachable only from the
      // second block leaks the socket pool whenever the first one returns.
      try {
        // The local bridge is the only machine no control-plane advert covers,
        // so its catalog is pulled here — once per host process, since the
        // descriptor is static per bridge build. Contained separately from the
        // status poll below: a bridge too old to answer tools:list must cost the
        // catalog, not every project's work status.
        if (_catalogSyncedPort != hostFile.controlPort) {
          try {
            final listed = await client.toolsList();
            if (!mounted) return;
            _catalogSyncedPort = hostFile.controlPort;
            ref.read(agentCatalogProvider.notifier).merge(listed.agents);
          } catch (_) {
            // Retried on the next tick — the port stays unrecorded.
          }
        }
        try {
          final projects = await client.projectList();
          if (!mounted) return;
          final statuses = <String, AgentWorkStatus>{};
          final sessionStatuses = <String, Map<String, AgentWorkStatus>>{};
          for (final p in projects) {
            final s = AgentWorkStatus.fromWire(p.workStatus);
            if (s != null) statuses[p.projectId] = s;
            final perSession = p.sessionStatuses;
            if (perSession != null) sessionStatuses[p.projectId] = perSession;
          }
          ref
              .read(remoteProjectStatusProvider.notifier)
              .setLocalStatuses(statuses);
          ref
              .read(remoteSessionStatusProvider.notifier)
              .setLocalSessionStatuses(sessionStatuses);
        } catch (_) {
          // Host went away between peek and list — ignore; next tick retries.
        }
        final now = DateTime.now();
        final last = _lastProjectBackfillAt;
        if (last == null || now.difference(last) >= _kProjectBackfillInterval) {
          _lastProjectBackfillAt = now;
          try {
            final hostUuid = await ref.read(localDeviceUuidProvider.future);
            final known = await client.phonesList();
            if (!mounted || hostUuid == null) return;
            await ref
                .read(projectsProvider.notifier)
                .backfillFromHost(known.knownProjects, hostUuid: hostUuid);
          } catch (_) {
            // Best-effort — retried on the next eligible tick.
          }
        }
      } finally {
        client.close();
      }
    } catch (_) {
      // peekHost() reads host.json off disk and can throw on a TOCTOU race
      // (rewritten mid-read) or a permissions blip. The timer calls us
      // unawaited, so an escaping throw is an unhandled rejection every tick —
      // matching the guard host_controller.dart already puts on the same read.
    } finally {
      _pollingLocalStatus = false;
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
