import 'dart:async';
import 'dart:io' show Directory, Platform, Process;

import 'package:push/push.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show LocalTransportHandshakeException, RelayConnectionState;

import '../connection/relay_mechanisms.dart' show ConnectionBlockedException;
import '../connection/supervisor_state.dart'
    show BlockReason, Blocked, SupervisorStatus;
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_toast.dart';
import '../launcher/host_control_client.dart' show HostControlException;
import '../launcher/host_discovery.dart' show hostDir;
import '../models/ab_message.dart';
import '../models/handler_state.dart' show HandlerEscalation;
import '../models/preferences_models.dart';
import '../models/session_entry.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/new_session_picker.dart'
    show newSessionStartInFlightProvider;
import '../providers/providers.dart';
import '../providers/relay_error_banner.dart';
import '../providers/sessions.dart';
import '../providers/supervisor_status.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/value_controller.dart';
import '../services/local_notification_service.dart';
import '../services/push_background_handler.dart'
    show decodePush, pushDataOf, pushDedupKey;
import '../services/push_identity.dart';
import '../util/ab_log.dart';
import '../utils/notification_routing.dart';
import '../widgets/agent_panel.dart';
import '../widgets/mobile_bottom_nav.dart';
import '../widgets/operational_error_toaster.dart';
import '../widgets/projects_drawer.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../widgets/resizable_pane.dart';
import '../widgets/workspace_tab_bar.dart';
import '../widgets/ab_banner.dart';
import '../widgets/ab_host_banner.dart';
import '../widgets/workspace_panel.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import 'app_settings_screen.dart';

/// Tracks whether the mobile Scaffold drawer is open, so the back-intercepting
/// PopScope can recompute `canPop` reactively (Scaffold's own drawer state is
/// not observable from a provider).
final _mobileDrawerOpenProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);

enum _PanelMode { normal, agentExpanded, contextExpanded }

/// Root layout orchestrator.
///
/// Mobile (< 600px): two-page [PageView] — agent page | workspace page.
/// Desktop (>= 600px): projects drawer + agent panel + context panel with
/// collapsible strips and a resizable divider.
class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({super.key});

  @override
  ConsumerState<WorkspaceShell> createState() => WorkspaceShellState();
}

class WorkspaceShellState extends ConsumerState<WorkspaceShell>
    with WidgetsBindingObserver {
  late PageController _pageController;
  WorkspaceView _selectedView = WorkspaceView.files;
  double _splitRatio = 0.5;
  _PanelMode _panelMode = _PanelMode.normal;
  bool _prefsApplied = false;
  final _drawerSearchFocus = FocusNode();
  final _mobileScaffoldKey = GlobalKey<ScaffoldState>();

  /// OS-level notifications, used only while the app is backgrounded. Self
  /// degrading: `init`/`show` swallow platform errors.
  final LocalNotificationService _osNotifications = LocalNotificationService();
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// Logical notification ids already surfaced (toast or OS notification), so
  /// each event is shown at most once REGARDLESS of arrival surface. The same
  /// event can reach this screen twice — once via a live provider stream
  /// (foreground) and once via an FCM push (the bridge seals
  /// `sourceMessageId === escalationId` for escalations and `=== msg.id` for
  /// agent notifications, see push-dispatcher.ts) — so a single shared set keyed
  /// on the stable id is what prevents the double toast/notification.
  /// handlerEscalationsProvider re-seeds pending escalations on every rebuild to
  /// close the broadcast-subscribe race; this set is what makes that re-seed
  /// idempotent. NOT shared across isolates, so a background push followed by a
  /// foreground replay of the same id on reopen is a known v1 gap (see
  /// push_background_handler.dart). Insertion-ordered and capped
  /// ([_kMaxNotifiedIds]) via [_markNotified] so a long-lived foreground session
  /// receiving many pushes can't grow it without bound.
  final Set<String> _notifiedIds = <String>{};

  /// Cap on [_notifiedIds]. Dedup only needs recent ids; re-seeing one evicted
  /// long ago risks at most one duplicate — fine for best-effort notifications.
  static const _kMaxNotifiedIds = 512;

  /// Record [id] as surfaced. Returns false if it was already present (a
  /// duplicate to suppress), true if newly recorded. Evicts the oldest id once
  /// past the cap ([_notifiedIds] is a `LinkedHashSet`, so `.first` is oldest).
  bool _markNotified(String id) {
    if (!_notifiedIds.add(id)) return false;
    if (_notifiedIds.length > _kMaxNotifiedIds) {
      _notifiedIds.remove(_notifiedIds.first);
    }
    return true;
  }

  /// `push` hands back an unsubscribe callback rather than a StreamSubscription.
  VoidCallback? _unsubscribeForegroundPush;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Fire-and-forget: async + self-degrading.
    _osNotifications.init();
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      _unsubscribeForegroundPush = Push.instance.addOnMessage((m) async {
        try {
          final decoded = await decodePush(
            pushDataOf(m),
            pushIdentity: PushIdentity.secure(),
          );
          // The widget can be disposed while decodePush awaits; `context` (used
          // by _onAgentNotification's toast path) is dead after that.
          if (!mounted || decoded == null) return;
          // Unified dedup: the key is shared with the live handler stream below,
          // so a push and its live message surface once between them. A null key
          // means show it — never dedup an unidentifiable push away.
          final key = pushDedupKey(decoded);
          if (key != null && !_markNotified(key)) {
            return; // already surfaced (this surface or the live stream)
          }
          _onAgentNotification(title: decoded.title, body: decoded.body);
        } catch (e) {
          // Async listener: an uncaught throw here is an unhandled rejection.
          AbLog.error('WorkspaceShell', 'foreground push failed', fields: {'error': '$e'});
        }
      });
    }
    _pageController = PageController();
    // Register switch callback + run the initial session bootstrap after the
    // first frame so provider writes don't happen during build (which would
    // throw in debug/test mode). The bootstrap is intentionally NOT driven
    // by a `ref.listen(... fireImmediately:)` here because WidgetRef.listen
    // in flutter_riverpod 2.6 has no fireImmediately flag — see the long
    // comment near `ref.listen<String?>(selectedRegistrationIdProvider, ...)` in
    // build() for why we need an initial-mount trigger at all.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(switchToAgentProvider.notifier).set(switchToAgentPage);
      if (ref.read(selectedRegistrationIdProvider) != null) {
        _bootstrapSessions();
      }
    });
  }

  @override
  void deactivate() {
    // Capture the notifier synchronously (ref is still valid here), then
    // defer the state write so it doesn't happen mid-build when the widget
    // tree is being restructured (e.g. project switch).
    final notifier = ref.read(switchToAgentProvider.notifier);
    // `scheduleMicrotask` defers the write off the current build/restructure
    // phase (same intent as the previous `Future(() => ...)`) but does not
    // create a Timer, so it doesn't leak in widget tests under fake_async.
    // The try/catch silences the benign "used after dispose" case when the
    // microtask fires after the entire ProviderContainer has been torn down
    // (app shutdown, or fast widget-tree disposal in tests).
    scheduleMicrotask(() {
      try {
        notifier.set(null);
      } catch (_) {
        // Provider already disposed (Riverpod 3 throws UnmountedRefException,
        // which is @internal and not a StateError, so catch broadly); nothing
        // to reset.
      }
    });
    super.deactivate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    ref.read(appLifecycleStateProvider.notifier).set(state);
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribeForegroundPush?.call();
    _unsubscribeForegroundPush = null;
    _pageController.dispose();
    _drawerSearchFocus.dispose();
    super.dispose();
  }

  // ── Terminal notifications ───────────────────────────────────────────

  void _onNotification(TerminalNotificationMessage msg) {
    final body = (msg.body != null && msg.body!.isNotEmpty)
        ? msg.body!
        : 'Notification';
    final title = (msg.title != null && msg.title!.isNotEmpty)
        ? msg.title!
        : 'Agent';
    _onAgentNotification(title: title, body: body);
  }

  void _onAgentNotificationPush(NotificationPushMessage msg) {
    const labels = {
      'permission_request': 'Permission needed',
      'awaiting_input': 'Needs your input',
      'task_complete': 'Task complete',
      'idle': 'Waiting for you',
      'error': 'Agent error',
    };
    final label = labels[msg.notificationType] ?? 'Agent';
    // Keep in lockstep with bridge/src/push/compose.ts: the same message reaches
    // this path in-band and that one via push, and they must not disagree. body
    // deliberately does not fall back to sessionTitle, or title == body.
    final title = (msg.sessionTitle != null && msg.sessionTitle!.isNotEmpty)
        ? msg.sessionTitle!
        : label;
    final body = (msg.message != null && msg.message!.isNotEmpty)
        ? msg.message!
        : label;
    _onAgentNotification(title: title, body: body);
  }

  void _onHandlerEscalation(HandlerEscalation esc) {
    // Route through the shared surfacer (foreground toast / background OS
    // notification), identical to the agent-notification paths, so an
    // escalation from ANY warm project is surfaced — not just the focused one.
    final title = esc.urgency == 'high'
        ? 'Handler — urgent'
        : 'Handler needs you';
    final body = esc.question.isNotEmpty ? esc.question : 'Agent needs you';
    _onAgentNotification(title: title, body: body);
  }

  void _onAgentNotification({required String title, required String body}) {
    if (shouldShowInAppToast(_lifecycle)) {
      showAbToastOverlay(
        context,
        toast: AbToast(icon: AbIcons.bell, title: title, description: body),
      );
      return;
    }
    // App is not focused (occluded or minimized): only the OS notification can
    // surface above the foreground app — an in-app toast would be painted
    // behind it. Fire-and-forget; `show` logs delivery failures internally.
    _osNotifications.show(title: title, body: body);
  }

  // ── Preferences ──────────────────────────────────────────────────────

  /// Apply preferences, updating state directly (no setState needed when
  /// called from build — the build will use the updated values immediately).
  void _applyPrefs(ProjectPreferences prefs) {
    _splitRatio = prefs.splitRatio;
    _panelMode = _PanelMode.values[prefs.panelMode.clamp(0, 2)];

    // NOTE: workspaceViewIndex is a raw WorkspaceView ordinal persisted to
    // disk, so adding/removing enum values shifts it. A stale index can restore
    // the wrong tab after an upgrade — this bounds check only prevents an
    // out-of-range crash, not a semantic mismatch (e.g. removing "Services"
    // shifted later views down by one with no migration). When Services (or any
    // view) is re-added, remap stored indices in ProjectPreferences.fromJson, or
    // switch to persisting WorkspaceView.name, rather than relying on this guard.
    final idx = prefs.workspaceViewIndex;
    if (idx >= 0 && idx < WorkspaceView.values.length) {
      _selectedView = WorkspaceView.values[idx];
    }
    _prefsApplied = true;
  }

  void _updatePrefs() {
    final service = ref.read(preferencesServiceProvider);
    service.update(
      service.current.copyWith(
        splitRatio: _splitRatio,
        workspaceViewIndex: _selectedView.index,
        panelMode: _panelMode.index,
      ),
    );
  }

  // ── Sessions bootstrap ───────────────────────────────────────────────

  /// Fetch the agent's session list. On empty: route to the New Session page
  /// so the user picks an agent (no auto cold-start) — unless a
  /// `startNewSession` is already in flight, in which case that path owns
  /// session creation. On non-empty: select the most-recently-used session
  /// and auto-start it if stopped, then `focus` to bump server-side
  /// `lastUsedAt` so a second app connecting later sees matching recency.
  ///
  /// Project-switch race guard: capture the project id at entry and re-check
  /// after every await. If the user switches A → B mid-flight, the stale A
  /// run aborts before issuing any further session mutations.
  Future<void> _bootstrapSessions() async {
    final triggeredFor = ref.read(selectedRegistrationIdProvider);
    if (triggeredFor == null) return;

    // Wait for the per-project ProjectSession (transport + services) to
    // finish constructing before reading any per-project service façade.
    // Without this, the sync `ref.read(sessionsServiceProvider)` below
    // races the async session factory and throws
    // `_ProjectSessionLoading` on the first frame after openFolder.
    try {
      await ref.read(projectSessionProvider(triggeredFor).future);
    } catch (_) {
      // Surfaced elsewhere; nothing actionable here.
      return;
    }
    if (!mounted || ref.read(selectedRegistrationIdProvider) != triggeredFor) {
      return;
    }

    final svc = ref.read(sessionsServiceProvider);
    List<SessionEntry> list;
    try {
      list = await svc.requestList();
    } catch (e) {
      // Transport switched / service stopped mid-flight is benign — the
      // next project-open will retry. But a genuine error here means the
      // workspace is going to render with an empty sessions list and
      // unresponsive "+ new session" — surface it inline so the user has
      // an actionable next step instead of staring at a blank panel.
      if (mounted && ref.read(selectedRegistrationIdProvider) == triggeredFor) {
        ref
            .read(relayErrorBannerProvider.notifier)
            .set(
              RelayErrorBanner(
                'SESSIONS',
                'Couldn\'t load this project\'s sessions: $e — '
                    'switch projects and back to retry.',
              ),
            );
      }
      return;
    }
    if (!mounted) return;
    if (ref.read(selectedRegistrationIdProvider) != triggeredFor) return;

    // 1. Pending session-id (from a cross-project session-row click).
    final pendingId = ref.read(pendingActiveSessionIdProvider);
    if (pendingId != null) {
      ref.read(pendingActiveSessionIdProvider.notifier).set(null);
      final desired = list
          .where((s) => s.id == pendingId && !s.archived)
          .firstOrNull;
      if (desired != null) {
        ref.read(activeSessionIdProvider.notifier).set(desired.id);
        if (!desired.running) {
          await svc.start(desired.id);
          if (!mounted) return;
          if (ref.read(selectedRegistrationIdProvider) != triggeredFor) return;
        }
        svc.focus(desired.id);
        return;
      }
      // Stale id (session deleted since cache write) — fall through to
      // default behaviour.
    }

    // 2. Default behaviour (unchanged from before).
    final active = list.where((s) => !s.archived).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));

    if (active.isEmpty) {
      // No sessions for this project: send the user to the New Session page so
      // they pick an agent for the first session (no auto cold-start).
      //
      // BUT skip this when an explicit startNewSession is in flight: that path
      // activates the target (firing this bootstrap) and will itself create the
      // session + own the post-start UI state. Without this guard the empty
      // list here races leaveNewSession() and can strand the user on the New
      // Session page or double-start. See the per-session-agent design.
      if (ref.read(selectedRegistrationIdProvider) != triggeredFor) return;
      if (ref.read(newSessionStartInFlightProvider)) return;
      ref
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.newSession);
      // Record the auto-route to New Session so it is reachable via back(),
      // matching the manual enterNewSession path. (selectProject already
      // recorded this project's workspace entry just before this bootstrap.)
      ref
          .read(navControllerProvider.notifier)
          .commit(
            NavLocation(
              target: ref.read(selectedTargetProvider),
              surface: WorkbenchSurface.newSession,
            ),
          );
      return;
    } else {
      if (ref.read(selectedRegistrationIdProvider) != triggeredFor) return;
      ref.read(activeSessionIdProvider.notifier).set(active.first.id);
      final session = active.first;
      if (!session.running) {
        await svc.start(session.id);
        if (!mounted) return;
        if (ref.read(selectedRegistrationIdProvider) != triggeredFor) return;
      }
      // Transcript hydration is driven by AgentTranscriptView.initState (the
      // single per-session chokepoint), not here — see hydrateAttachedChatIfNeeded.
      // Bump server-side lastUsedAt so a second app connecting later sees
      // the actual recency (parity with manual tap in session_row.dart).
      svc.focus(session.id);
    }
  }

  // ── Public API (used by send-to-agent) ───────────────────────────────

  void switchToAgentPage() {
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Subsequent project switches (A → B while WorkspaceShell stays mounted)
    // bootstrap via this listener. The *initial* mount is handled by the
    // initState post-frame callback below: WorkspaceShell is only built
    // *after* AppShell observes `selectedRegistrationIdProvider != null`, so by
    // the time this listener registers, the null→id change has already
    // happened — leaving a fireImmediately-less listener with nothing to
    // observe. (Originally this listener watched `activeProjectIdProvider`,
    // which was set by the agent's `agent-hello` reply *after* the shell
    // mounted; the selectedRegistrationIdProvider migration introduced this
    // gap, which manifested as "session not added to project drawer or not
    // created" on first folder-open.) WidgetRef.listen in 2.6 has no
    // fireImmediately flag, so we use the initState path instead of
    // ref.listenManual to keep widget lifecycle straightforward.
    ref.listen<String?>(selectedRegistrationIdProvider, (prev, next) {
      if (next == null || prev == next) return;
      _bootstrapSessions();
    });

    // Keep the active session id valid as the session list churns (delete /
    // archive of the currently focused session advances to the next sibling).
    // The "auto-disconnect on empty" behaviour is wired at the delete/archive
    // call sites (session_row.dart) — NOT here — because `_stopAllServices()`
    // empties the session list synchronously during a project switch (see
    // `PairedAgentNotifier.selectAgent`), which would race a listener-based
    // disconnect and partially undo the in-flight switch.
    ref.listen<List<SessionEntry>>(activeSessionsProvider, (_, _) {
      Future.microtask(() {
        if (!mounted) return;
        reconcileActiveSession(ref, ref.read(activeSessionsProvider));
      });
    });

    // Surface agent terminal notifications: in-app toast while foreground,
    // OS notification while backgrounded (gated in _onNotification). The
    // provider reloads on project switch and replays a carried-over value;
    // guard against re-handling the same emission.
    ref.listen<AsyncValue<TerminalNotificationMessage>>(
      terminalNotificationsProvider,
      (prev, next) {
        final msg = next.value;
        if (msg == null) return;
        if (prev?.value == msg) return; // carried-over value on reload
        _onNotification(msg);
      },
    );

    ref.listen<AsyncValue<NotificationPushMessage>>(
      agentPushNotificationsProvider,
      (prev, next) {
        final msg = next.value;
        if (msg == null) return;
        if (prev?.value == msg) return; // carried-over value on reload
        // Shared dedup key with the FCM path: the bridge seals
        // `sourceMessageId === msg.id` for agent notifications, so this id
        // guards both surfaces — a connected-but-backgrounded phone that gets
        // the same event live AND via push surfaces it only once (matches the
        // handler-escalation path below).
        if (!_markNotified(msg.id)) return; // once/id
        _onAgentNotificationPush(msg);
      },
    );

    ref.listen<AsyncValue<HandlerEscalation>>(handlerEscalationsProvider, (
      prev,
      next,
    ) {
      final esc = next.value;
      if (esc == null) return;
      // Shared dedup key with the FCM path: the bridge seals
      // `sourceMessageId === escalationId` for handler pushes, so this same id
      // guards both surfaces and a single escalation is surfaced only once
      // whether it arrives live or via push.
      if (!_markNotified(esc.escalationId)) return; // once/id
      _onHandlerEscalation(esc);
    });

    // Surface launcher/transport errors inline (local-mode spawn
    // failures, a relay stream transport that errors) instead of leaving the
    // user on a frozen boot phase. We watch BOTH the transport and the
    // active project's session future: the launcher can race itself across
    // two consumers (transport family + projectSessionProvider) and only
    // one of them may end up in error state. Without the second gate the
    // workspace renders past a broken session graph — every "+ new
    // session" tap silently no-ops because the SessionsService never
    // attaches.
    final transportAsync = ref.watch(agentTransportProvider);
    final activeProjectId = ref.watch(selectedRegistrationIdProvider);
    final sessionAsync = activeProjectId != null
        ? ref.watch(projectSessionProvider(activeProjectId))
        : null;
    // Only a SETTLED error may take over the screen. While either provider is
    // refreshing, `.error` still holds the PREVIOUS error (Riverpod's
    // AsyncLoading.copyWithPrevious), so a fresh attempt is already in flight —
    // e.g. the transport family self-healing after a transient null transport
    // (folder not yet in projectsProvider). Rendering that retained error
    // during the refresh is what flashed the launch-error screen for a beat
    // before the workspace appeared. Gate on !isLoading so the error screen
    // shows only once the latest attempt has actually failed.
    final transportError = transportAsync.isLoading
        ? null
        : transportAsync.error;
    final sessionError = (sessionAsync == null || sessionAsync.isLoading)
        ? null
        : sessionAsync.error;
    // Remote targets only: a local project has no machine socket, so no
    // supervisor — and its id is not a machine uuid to look one up by.
    final isRemoteTarget = ref.watch(selectedTargetProvider)?.isLocal == false;
    final liveStatus = (isRemoteTarget && activeProjectId != null)
        ? ref.watch(supervisorStatusProvider(activeProjectId)).value
        : null;
    final blockingError = workspaceBlockingError(
      transportError: transportError,
      sessionError: sessionError,
      liveStatus: liveStatus,
    );
    if (blockingError != null) {
      // The host banner must survive this early return: a dead LOCAL bridge is
      // often what CAUSED the blocking error (ensureHost threw), and the
      // banner's "Restart bridge" (retryNow) is the only affordance that
      // clears the supervision crash-loop budget — the generic Retry below
      // only invalidates providers.
      return Column(
        children: [
          const AbHostBanner(),
          Expanded(
            child: _buildBlockingErrorScreen(blockingError, activeProjectId),
          ),
        ],
      );
    }
    final isLocalMode = ref.watch(selectedRegistrationIdProvider) != null;

    // Only listen while prefs haven't been applied yet.
    if (!_prefsApplied) {
      ref.listen(projectPreferencesProvider, (_, next) {
        final prefs = next.value;
        if (prefs != null) {
          setState(() => _applyPrefs(prefs));
        }
      });

      final prefs = ref.read(projectPreferencesProvider).value;
      if (prefs != null) {
        _applyPrefs(prefs);
      } else if (isLocalMode) {
        return const _LocalBootStatus();
      } else {
        return const _WorkspaceBootStatus();
      }
    }

    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < kCompactBreakpoint;

    // Drive DEC-1004 focus routing for agent terminals.
    ref.watch(agentFocusBinderProvider);
    // Desktop always shows the agent panel; mobile visibility is set by the
    // PageView's onPageChanged (and the mobile initializer), so only force-true
    // here on desktop to avoid clobbering the mobile page state.
    if (!isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!ref.read(agentSurfaceVisibleProvider)) {
          ref.read(agentSurfaceVisibleProvider.notifier).set(true);
        }
      });
    }

    final nav = ref.read(navControllerProvider.notifier);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusDrawerSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusDrawerSearch,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            nav.back,
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            nav.forward,
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
            nav.back,
        const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
            nav.forward,
      },
      child: Listener(
        onPointerDown: (event) {
          // Mouse "back"/"forward" side buttons: kBackMouseButton (8),
          // kForwardMouseButton (16). Guarded so a normal click never triggers.
          if (event.buttons == kBackMouseButton) {
            nav.back();
          } else if (event.buttons == kForwardMouseButton) {
            nav.forward();
          }
        },
        // Android 15 forces edge-to-edge (targetSdk 35+): system bars are
        // transparent and we draw behind them. Without this the header collides
        // with the status bar (and the bottom nav with the gesture inset). No-op
        // on desktop, where system-bar insets are zero.
        child: SafeArea(
          child: Column(
            children: [
              const OperationalErrorToaster(),
              const AbBanner(),
              const AbHostBanner(),
              Expanded(child: isMobile ? _buildMobile() : _buildDesktop()),
            ],
          ),
        ),
      ),
    );
  }

  void _focusDrawerSearch() {
    // On mobile, the drawer subtree is built lazily — opening it first lets
    // the FocusNode attach to the TextField before we request focus. Defer
    // the requestFocus() until after the drawer's first build frame.
    final scaffold = _mobileScaffoldKey.currentState;
    if (scaffold != null && !scaffold.isDrawerOpen) {
      scaffold.openDrawer();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _drawerSearchFocus.requestFocus();
      });
      return;
    }
    _drawerSearchFocus.requestFocus();
  }

  // ── Mobile ───────────────────────────────────────────────────────────

  Widget _buildBlockingErrorScreen(Object error, String? activeProjectId) {
    return _LocalLaunchErrorScreen(
      error: error,
      projectId: activeProjectId,
      onRetry: activeProjectId == null
          ? null
          : () {
              // Drop the static dedupe entry too: any prior failure has
              // settled by the time this screen renders, so it's already
              // gone, but invalidating the providers also guarantees fresh
              // family-entry builds rather than re-using a cached error —
              // and, for a block that landed on ALREADY-resolved providers,
              // it is what rebuilds the transport off the dead session.
              // `agentTransportProvider` is a pure forwarder over the
              // family; invalidating the family entry is enough.
              ref.invalidate(projectSessionProvider(activeProjectId));
              if (ref.read(selectedTargetProvider)?.isLocal == false) {
                // A remote transport error is usually the supervisor's
                // Blocked verdict, which is sticky and replayed to every new
                // listener: invalidating alone rebuilds straight back into
                // the same error. `retry()` is the only input that clears it,
                // and retryAgentConnection does the invalidate itself.
                unawaited(
                  ref.read(pairedAgentProvider.notifier).retryAgentConnection(),
                );
                return;
              }
              ref.invalidate(agentTransportForProvider(activeProjectId));
            },
      onBack: () => ref.read(selectedTargetProvider.notifier).set(null),
    );
  }

  Widget _buildMobile() {
    final surface = ref.watch(workbenchSurfaceProvider);
    final surfaceChild = _workbenchSurfaceChild(surface);
    // Seed the agent-surface-visible state from the current page after the
    // first frame (the PageView's onPageChanged only fires on subsequent
    // swipes). Agent panel is page 0.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (surfaceChild != null) {
        ref.read(agentSurfaceVisibleProvider.notifier).set(false);
        return;
      }
      final page = _pageController.hasClients
          ? (_pageController.page?.round() ?? 0)
          : 0;
      ref.read(agentSurfaceVisibleProvider.notifier).set(page == 0);
    });
    // watch (not read): recompute canPop when history OR drawer state changes,
    // even on a same-surface project switch that wouldn't otherwise rebuild.
    final navState = ref.watch(navControllerProvider);
    final drawerOpen = ref.watch(_mobileDrawerOpenProvider);
    final nav = ref.read(navControllerProvider.notifier);
    return PopScope(
      // Intercept system back while the drawer is open (close it) or in-app
      // history can step back. Otherwise allow the default pop (exit the app).
      canPop: !drawerOpen && !navState.canBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final scaffold = _mobileScaffoldKey.currentState;
        if (scaffold?.isDrawerOpen ?? false) {
          scaffold!.closeDrawer();
          return;
        }
        nav.back();
      },
      child: Scaffold(
        key: _mobileScaffoldKey,
        backgroundColor: context.antgrid.bgDeepest,
        onDrawerChanged: (open) =>
            ref.read(_mobileDrawerOpenProvider.notifier).set(open),
        drawer: Drawer(
          backgroundColor: context.antgrid.bgDeep,
          width: 304,
          child: SafeArea(
            child: ProjectsDrawer(searchFocusNode: _drawerSearchFocus),
          ),
        ),
        body:
            surfaceChild ??
            PageView(
              controller: _pageController,
              onPageChanged: (index) {
                // Agent panel is page 0.
                ref.read(agentSurfaceVisibleProvider.notifier).set(index == 0);
              },
              children: [
                AgentPanel(),
                Column(
                  children: [
                    Expanded(
                      child: WorkspacePanel(
                        selectedView: _selectedView,
                        onViewSelected: (v) => setState(() {
                          _selectedView = v;
                          _updatePrefs();
                        }),
                        viewBadges: _workspaceBadges(),
                        showTabBar: false,
                      ),
                    ),
                    MobileBottomNav(
                      selected: _selectedView,
                      onSelected: (v) => setState(() {
                        _selectedView = v;
                        _updatePrefs();
                      }),
                    ),
                  ],
                ),
              ],
            ),
      ),
    );
  }

  Map<WorkspaceView, int> _workspaceBadges() {
    final fileState = ref.watch(fileTreeStateProvider).value;
    final gitCount = fileState?.gitFileStatuses.length ?? 0;
    final pending =
        ref.watch(handlerStateProvider).value?.pendingEscalations ?? 0;
    return {
      if (gitCount > 0) WorkspaceView.git: gitCount,
      if (pending > 0) WorkspaceView.handler: pending,
    };
  }

  // ── Desktop / Tablet ─────────────────────────────────────────────────

  Widget _buildDesktop() {
    final surfaceChild = _workbenchSurfaceChild(
      ref.watch(workbenchSurfaceProvider),
    );
    return Row(
      children: [
        ProjectsDrawer(searchFocusNode: _drawerSearchFocus),
        if (surfaceChild != null)
          Expanded(child: surfaceChild)
        else
          ..._buildPanels(),
      ],
    );
  }

  Widget? _workbenchSurfaceChild(WorkbenchSurface surface) {
    void close() {
      ref
          .read(workbenchSurfaceProvider.notifier)
          .set(WorkbenchSurface.workspace);
      // Closing an overlay surface (settings/devices) is a navigation: record
      // the return to workspace so back() reopens the overlay and nav.current
      // stays in sync with the visible surface. Without this commit the first
      // back press after closing is a no-op (the cursor still points at the
      // overlay entry while the screen already shows workspace).
      ref
          .read(navControllerProvider.notifier)
          .commit(
            NavLocation(
              target: ref.read(selectedTargetProvider),
              surface: WorkbenchSurface.workspace,
              sessionId: ref.read(activeSessionIdProvider),
            ),
          );
    }

    return switch (surface) {
      WorkbenchSurface.appSettings => AppSettingsScreen(onClose: close),
      // Unreachable from any UI affordance (the account-menu entry that drove
      // it was removed); kept only so a lingering `mobileDevices` deep link
      // no-ops the same way here as on new_session_screen.dart, instead of
      // resurfacing the hub on desktop.
      WorkbenchSurface.mobileDevices ||
      WorkbenchSurface.workspace ||
      WorkbenchSurface.newSession => null,
    };
  }

  List<Widget> _buildPanels() {
    switch (_panelMode) {
      case _PanelMode.normal:
        return [
          Expanded(
            child: ResizablePane(
              initialRatio: _splitRatio,
              onRatioChanged: (r) {
                _splitRatio = r;
                _updatePrefs();
              },
              left: AgentPanel(),
              right: WorkspacePanel(
                selectedView: _selectedView,
                onViewSelected: _onSidebarSelected,
                viewBadges: _workspaceBadges(),
                isExpanded: false,
                onToggleExpand: () => setState(() {
                  _panelMode = _PanelMode.contextExpanded;
                  _updatePrefs();
                }),
              ),
            ),
          ),
        ];

      case _PanelMode.agentExpanded:
        return [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: context.antgrid.borderDefault),
                ),
              ),
              child: AgentPanel(),
            ),
          ),
          _buildCollapsedStrip(
            label: _selectedView.label,
            isAgent: false,
            onTap: () => setState(() {
              _panelMode = _PanelMode.normal;
              _updatePrefs();
            }),
          ),
        ];

      case _PanelMode.contextExpanded:
        return [
          _buildCollapsedStrip(
            label: 'Agent',
            isAgent: true,
            onTap: () => setState(() {
              _panelMode = _PanelMode.normal;
              _updatePrefs();
            }),
          ),
          Expanded(
            child: WorkspacePanel(
              selectedView: _selectedView,
              onViewSelected: _onSidebarSelected,
              viewBadges: _workspaceBadges(),
              isExpanded: true,
              onToggleExpand: () => setState(() {
                _panelMode = _PanelMode.normal;
                _updatePrefs();
              }),
            ),
          ),
        ];
    }
  }

  // ── Collapsed strip ──────────────────────────────────────────────────

  Widget _buildCollapsedStrip({
    required String label,
    required bool isAgent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: AbTokens.collapsedStripWidth,
          color: isAgent ? context.antgrid.bgDeep : context.antgrid.bgDeepest,
          child: Center(
            child: RotatedBox(
              quarterTurns: 1,
              child: Text(
                label,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: isAgent
                      ? context.antgrid.accent
                      : context.antgrid.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  void _onSidebarSelected(WorkspaceView view) {
    setState(() {
      _selectedView = view;
      // If context panel was collapsed (agent expanded), restore it
      if (_panelMode == _PanelMode.agentExpanded) {
        _panelMode = _PanelMode.normal;
      }
      _updatePrefs();
    });
  }
}

/// Boot-log style status panel rendered while the workspace is coming up.
/// Each phase is one line with a leading glyph (`▸` running, `✓` done, `×`
/// failed); the running phase pulses indigo. When `agent link` flips to
/// failed (PAIR_TIMEOUT), an inline retry control replaces the
/// indeterminate spinner UX of the previous implementation.
class _WorkspaceBootStatus extends ConsumerStatefulWidget {
  const _WorkspaceBootStatus();

  @override
  ConsumerState<_WorkspaceBootStatus> createState() =>
      _WorkspaceBootStatusState();
}

enum _PhaseStatus { pending, running, done, failed }

class _Phase {
  final String id;
  final String label;
  final String detail;
  final _PhaseStatus status;
  const _Phase(this.id, this.label, this.detail, this.status);
}

class _WorkspaceBootStatusState extends ConsumerState<_WorkspaceBootStatus> {
  bool _retrying = false;

  /// Identity of the phase currently in [_PhaseStatus.running], if any.
  /// When this changes, [_activeSince] resets so each phase shows its own
  /// elapsed time rather than a session-wide counter.
  String? _activePhaseId;
  DateTime? _activeSince;

  /// Drives 1Hz rebuilds so the `· Ns` suffix on the running phase ticks.
  /// Cheaper than an [AnimationController] (no per-frame work, no vsync) —
  /// elapsed seconds only need second-resolution.
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker(_Phase? running) {
    if (running == null) {
      _ticker?.cancel();
      _ticker = null;
      _activePhaseId = null;
      _activeSince = null;
      return;
    }
    if (running.id != _activePhaseId) {
      _activePhaseId = running.id;
      _activeSince = DateTime.now();
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await ref.read(pairedAgentProvider.notifier).retryAgentConnection();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  void _cancel() {
    final notifier = ref.read(pairedAgentProvider.notifier);
    notifier.cancelActiveAgent();
  }

  /// Ordered relay states from cold (-1) to live. The ordinal of the current
  /// state drives every phase's status via a threshold compare, instead of one
  /// bespoke if/else cascade per row.
  static const _stateOrder = [
    RelayConnectionState.connecting, // 0
    RelayConnectionState.authenticating, // 1
    RelayConnectionState.authenticated, // 2
  ];
  static const _kReachedAuthenticating = 1;
  static const _kReachedAuthenticated = 2;

  /// Returns `running`/`done`/`pending` for a phase that is "running while
  /// at exactly [runningAt], done once past it, pending otherwise".
  _PhaseStatus _phaseFor(int reached, int runningAt) {
    if (reached > runningAt) return _PhaseStatus.done;
    if (reached == runningAt) return _PhaseStatus.running;
    return _PhaseStatus.pending;
  }

  List<_Phase> _phases({
    required RelayConnectionState? conn,
    required AgentReachability reach,
    required String agentLabel,
  }) {
    // disconnected / null collapse to "before connecting" — the relay row
    // shows as running while we wait for the first state event.
    final reached = (conn == null || conn == RelayConnectionState.disconnected)
        ? -1
        : _stateOrder.indexOf(conn);

    final pairFailed = reach == AgentReachability.offline;
    _PhaseStatus pairStatus;
    String pairDetail;
    if (pairFailed) {
      pairStatus = _PhaseStatus.failed;
      pairDetail = 'not reachable';
    } else if (reach == AgentReachability.online) {
      // Only the supervisor's Connected — not mere socket auth — proves the
      // agent actually answered (see agentReachabilityProvider).
      pairStatus = _PhaseStatus.done;
      pairDetail = agentLabel;
    } else if (reached >= _kReachedAuthenticated) {
      // Socket is up but the ladder hasn't confirmed the agent yet.
      pairStatus = _PhaseStatus.running;
      pairDetail = '';
    } else {
      pairStatus = _PhaseStatus.pending;
      pairDetail = '';
    }

    return [
      _Phase(
        'relay',
        'relay',
        'ws://…',
        reached >= _kReachedAuthenticating
            ? _PhaseStatus.done
            : _PhaseStatus.running,
      ),
      _Phase(
        'auth',
        'authenticate',
        'license token',
        _phaseFor(reached, _kReachedAuthenticating),
      ),
      _Phase('agent', 'agent link', pairDetail, pairStatus),
      _Phase(
        'workspace',
        'workspace',
        'awaiting hello',
        reached >= _kReachedAuthenticated
            ? _PhaseStatus.running
            : _PhaseStatus.pending,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final connAsync = ref.watch(connectionStateProvider);
    final reach = ref.watch(agentReachabilityProvider);
    final activeAgent = ref.watch(activeAgentProvider);
    final agentLabel = activeAgent?.agentName ?? 'agent';

    final rawPhases = _phases(
      conn: connAsync.value?.connectionState,
      reach: reach,
      agentLabel: agentLabel,
    );
    // Identify the currently-running phase (if any) and decorate its detail
    // with elapsed seconds. Done in a post-frame callback so we don't call
    // setState during build.
    final runningIdx = rawPhases.indexWhere(
      (p) => p.status == _PhaseStatus.running,
    );
    final running = runningIdx >= 0 ? rawPhases[runningIdx] : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTicker(running);
    });

    var phases = rawPhases;
    if (running != null && _activeSince != null) {
      final secs = DateTime.now().difference(_activeSince!).inSeconds;
      if (secs >= 1) {
        final suffix = '${secs}s';
        final newDetail = running.detail.isEmpty
            ? suffix
            : '${running.detail} · $suffix';
        phases = [
          for (var i = 0; i < rawPhases.length; i++)
            if (i == runningIdx)
              _Phase(running.id, running.label, newDetail, running.status)
            else
              rawPhases[i],
        ];
      }
    }

    final hasFailed = phases.any((p) => p.status == _PhaseStatus.failed);

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _cancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: context.antgrid.bgDeepest,
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(AbTokens.space16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Terminal-style header: dim prompt + path
                Row(
                  children: [
                    Text(
                      '\$',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: context.antgrid.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: AbTokens.space6),
                    Text(
                      'antgrid ',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: context.antgrid.textSecondary,
                      ),
                    ),
                    Text(
                      agentLabel,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXs,
                        color: context.antgrid.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AbTokens.space12),

                // Boot log pane
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.antgrid.bgDeep,
                    border: Border.all(color: context.antgrid.borderDefault),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AbTokens.space12,
                      vertical: AbTokens.space10,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < phases.length; i++) ...[
                          if (i > 0) const SizedBox(height: AbTokens.space6),
                          _PhaseRow(phase: phases[i]),
                        ],
                      ],
                    ),
                  ),
                ),

                if (hasFailed) ...[
                  const SizedBox(height: AbTokens.space12),
                  _AgentLinkFailureFooter(retrying: _retrying, onRetry: _retry),
                ],

                // Always offer an escape hatch so the user is never stuck on
                // this screen — placed below the pane (and below the failure
                // footer when one is present) so it doesn't compete with the
                // primary action (retry).
                const SizedBox(height: AbTokens.space12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _CancelLink(onTap: _cancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Subtle text-style "back" affordance — bracketed prompt-style to feel
/// continuous with the boot log above rather than introducing a CTA button
/// that competes with retry visually.
class _CancelLink extends StatefulWidget {
  final VoidCallback onTap;
  const _CancelLink({required this.onTap});

  @override
  State<_CancelLink> createState() => _CancelLinkState();
}

class _CancelLinkState extends State<_CancelLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = _hovered
        ? context.antgrid.textSecondary
        : context.antgrid.textMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AbTokens.space2),
          child: Text.rich(
            TextSpan(
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: color,
              ),
              children: [
                const TextSpan(text: '['),
                TextSpan(
                  text: 'esc',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const TextSpan(text: '] cancel — back to projects'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhaseStyle {
  final String glyph;
  final Color glyphColor;
  final Color labelColor;
  final Color detailColor;
  const _PhaseStyle(
    this.glyph,
    this.glyphColor,
    this.labelColor,
    this.detailColor,
  );
}

Map<_PhaseStatus, _PhaseStyle> _phaseStyles(BuildContext context) {
  final palette = context.antgrid;
  return <_PhaseStatus, _PhaseStyle>{
    _PhaseStatus.pending: _PhaseStyle(
      '·',
      palette.textDisabled,
      palette.textDisabled,
      palette.textMuted,
    ),
    _PhaseStatus.running: _PhaseStyle(
      '▸',
      palette.accent,
      palette.textPrimary,
      palette.textSecondary,
    ),
    _PhaseStatus.done: _PhaseStyle(
      '✓',
      palette.success,
      palette.textSecondary,
      palette.textMuted,
    ),
    _PhaseStatus.failed: _PhaseStyle(
      '×',
      palette.error,
      palette.textPrimary,
      palette.error,
    ),
  };
}

class _PhaseRow extends StatelessWidget {
  final _Phase phase;
  const _PhaseRow({required this.phase});

  @override
  Widget build(BuildContext context) {
    final s = _phaseStyles(context)[phase.status]!;

    Widget glyphWidget = SizedBox(
      width: 14,
      child: Text(
        s.glyph,
        textAlign: TextAlign.center,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          color: s.glyphColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (phase.status == _PhaseStatus.running) {
      glyphWidget = PulsingOpacity(child: glyphWidget);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        glyphWidget,
        const SizedBox(width: AbTokens.space8),
        Text(
          phase.label,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            color: s.labelColor,
            fontWeight: phase.status == _PhaseStatus.running
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
        if (phase.detail.isNotEmpty) ...[
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              phase.detail,
              overflow: TextOverflow.ellipsis,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: s.detailColor,
              ),
            ),
          ),
        ] else
          const Spacer(),
      ],
    );
  }
}

class _AgentLinkFailureFooter extends StatelessWidget {
  final bool retrying;
  final VoidCallback onRetry;
  const _AgentLinkFailureFooter({
    required this.retrying,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Decorative leading bar to suggest a "stderr"-style annotation
        Row(
          children: [
            Container(width: 2, height: 14, color: context.antgrid.error),
            const SizedBox(width: AbTokens.space8),
            Expanded(
              child: Text(
                'agent process not registered with the relay',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AbTokens.space6),
        Padding(
          padding: const EdgeInsets.only(left: AbTokens.space10),
          child: Text(
            'start the agent on the host machine, then retry.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textMuted,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: AbTokens.space12),
        Align(
          alignment: Alignment.centerLeft,
          child: AbButton(
            label: retrying ? 'retrying…' : 'retry',
            color: retrying
                ? context.antgrid.textMuted
                : context.antgrid.accent,
            onTap: retrying ? null : onRetry,
            compact: true,
          ),
        ),
      ],
    );
  }
}

/// The error [_LocalLaunchErrorScreen] should take the workspace over with, or
/// null to render the workspace normally.
///
/// The live [SupervisorStatus] is a source in its own right, not a duplicate of
/// the two provider errors. Those can only report a block the ladder reached
/// while `agentTransportProvider` was still RESOLVING — a block that lands
/// afterwards (another device taking the session over mid-use being the one
/// that has to work) leaves both providers holding their last good value while
/// every send is silently dropped, i.e. a dead workspace stating no reason at
/// all. Feeding the supervisor's own verdict in is what makes a block reach the
/// user whenever it arrives rather than only when it arrives during connect.
///
/// Pulled out of the build so the derivation is pinned against literal
/// [SupervisorStatus] values without pumping the whole provider graph — same
/// reasoning as `reachabilityForStatus` in `providers.dart`.
@visibleForTesting
Object? workspaceBlockingError({
  required Object? transportError,
  required Object? sessionError,
  required SupervisorStatus? liveStatus,
}) {
  if (transportError != null) return transportError;
  if (sessionError != null) return sessionError;
  // Ranked last: while a provider is settling into its own error the two agree,
  // and the thrown exception carries the more specific cause (a local spawn
  // failure, a 4409) than the reason the ladder reduced it to.
  if (liveStatus is Blocked && _takesOverMidSession(liveStatus.reason)) {
    return ConnectionBlockedException(liveStatus.reason);
  }
  return null;
}

/// Whether [reason], reached on an ALREADY-established workspace, is worth
/// unmounting that workspace for.
///
/// Only the reasons that stay blocked until the user acts. `agentOffline` and
/// `handshakeFailing` clear themselves on `notePresence(true)`, and the routable
/// rung reaches `agentOffline` about 6s after a peer-offline (3 ×
/// `routableStallMs`) — so taking the screen over for them would blow the
/// terminal, file tree and panes away on every host restart and rebuild them
/// from scratch seconds later. Those two already have their own non-destructive
/// surface in `agentReachabilityProvider`.
///
/// A block reached while the providers were still resolving is unaffected: it
/// arrives as a thrown [ConnectionBlockedException] above, where there is no
/// established workspace to preserve and every reason must be stated.
bool _takesOverMidSession(BlockReason reason) => switch (reason) {
  BlockReason.sessionTakenOver ||
  BlockReason.superseded ||
  BlockReason.deviceRevoked ||
  BlockReason.licenseExpired => true,
  BlockReason.agentOffline || BlockReason.handshakeFailing => false,
};

/// Shown for whatever [workspaceBlockingError] returns, which is EITHER of two
/// sources — a reader who checks only the first will conclude this screen
/// cannot be the one on the user's display:
///  - [agentTransportProvider] or the active [projectSessionProvider] throwing
///    — typically a local-agent spawn failure (missing antgrid.yaml, bun
///    unavailable, crash before publishing discovery) or a single-owner socket
///    collision (4409) with another running antgrid app;
///  - a live `Blocked(reason)` from the machine's supervisor while BOTH of
///    those providers are healthy `AsyncData` — a session another device took
///    over mid-use, a license verdict, a revoked device.
///
/// Every path leaves the user with at least one button that changes the
/// state: Retry re-runs the launch; Open log opens the host log directory;
/// Back returns to the home screen.
class _LocalLaunchErrorScreen extends StatelessWidget {
  final Object error;
  final String? projectId;
  final VoidCallback? onRetry;
  final VoidCallback onBack;
  const _LocalLaunchErrorScreen({
    required this.error,
    required this.projectId,
    required this.onRetry,
    required this.onBack,
  });

  /// Map specific exception shapes to a user-actionable headline + tip. The
  /// fallback covers everything else without leaving the user staring at a
  /// raw stack-trace-style message. `retryLabel` defaults to 'retry' — only
  /// `sessionTakenOver` needs a different verb ("take back"), since retrying
  /// there specifically reclaims a session another device is holding, rather
  /// than merely reattempting a failed connection.
  ({String headline, String tip, String retryLabel}) _diagnose() {
    final e = error;
    // The supervisor stopped climbing on purpose and named the reason. Each
    // one has a different user action, so none of them may collapse into the
    // generic "agent failed to start" bucket below.
    if (e is ConnectionBlockedException) {
      return switch (e.reason) {
        BlockReason.deviceRevoked => (
          headline: 'the relay would not accept this device',
          // LICENSE_INVALID covers far more than a revoked device: a token the
          // relay cannot verify (wrong issuer — a build pointed at the wrong
          // LICENSE_API_URL), a malformed one, and a missing/invalid
          // sessionLimit claim all land here alongside LICENSE_REVOKED. So the
          // copy has to be true for every cause while still naming the one
          // action that fixes the common ones.
          tip:
              'The relay rejected this device\'s access token — it was '
              'revoked, it no longer matches your plan, or this build is '
              'pointed at a different server. Check you are signed in on the '
              'right account, then sign out and back in to re-provision this '
              'device and Retry.',
          retryLabel: 'retry',
        ),
        BlockReason.licenseExpired => (
          headline: 'subscription expired',
          tip:
              'The relay rejected this connection\'s license. Renew the '
              'subscription, then Retry.',
          retryLabel: 'retry',
        ),
        BlockReason.agentOffline => (
          headline: 'agent is not running',
          tip:
              'The relay could not route to this machine — its antgrid host '
              'is not connected. Start it on the host, then Retry.',
          retryLabel: 'retry',
        ),
        BlockReason.superseded => (
          headline: 'the relay is holding this connection for another session',
          // Reached only after the ladder has already retried long enough for
          // the relay to drop a stale entry of our own, so by this point it is
          // genuinely someone else's — and Retry cannot evict them: this app
          // dials with one epoch per launch, which the relay refuses against
          // an equal-or-higher live holder.
          tip:
              'Another session of this app is connected as the same device. '
              'Close it, or restart this app to connect with a fresh session, '
              'then Retry.',
          retryLabel: 'retry',
        ),
        BlockReason.sessionTakenOver => (
          headline: 'another device took over this agent',
          tip: 'Another of your devices took over this agent.',
          retryLabel: 'take back',
        ),
        BlockReason.handshakeFailing => (
          headline: 'the encrypted session could not be established',
          tip:
              'The agent answered but the E2E handshake kept failing — usually '
              'a host that re-provisioned its identity. Retry; if it persists, '
              'forget the machine and pair it again.',
          retryLabel: 'retry',
        ),
      };
    }
    if (e is LocalTransportHandshakeException && e.closeCode == 4409) {
      return (
        headline: 'another antgrid app is connected to this project',
        tip:
            'The local agent for this folder is owned by another running '
            'antgrid app (or a stale instance that has not yet released its '
            'socket). Close the other app and Retry — or wait a few seconds '
            'and Retry; the agent releases the lock automatically when its '
            'owner disconnects.',
        retryLabel: 'retry',
      );
    }
    if (e is LocalTransportHandshakeException) {
      return (
        headline: 'agent rejected the connection',
        tip:
            'The agent is running but refused this app\'s handshake '
            '(close ${e.closeCode}). Retry; if it persists, open the log '
            'and look for an [ERROR] line near the handshake.',
        retryLabel: 'retry',
      );
    }
    if (e is HostControlException) {
      // Surface the structured code/message the bridge already returned instead
      // of collapsing every control error into the generic bucket below.
      switch (e.code) {
        case 'NO_FOLDER':
          return (
            headline: 'project folder not found',
            tip:
                'The host could not open this folder. Confirm the path still '
                'exists and contains an antgrid.yaml, then Retry.',
            retryLabel: 'retry',
          );
        case 'TRANSPORT':
          return (
            headline: 'could not reach the host control plane',
            tip:
                'The host control socket did not answer — it may have just '
                'exited. Retry to re-discover/respawn the host, or open '
                'host.log for the stderr trace.',
            retryLabel: 'retry',
          );
        case 'HTTP_401':
        case 'HTTP_403':
          return (
            headline: 'host rejected this app\'s control token',
            tip:
                'The loopback control token is stale (the host was replaced). '
                'Retry to re-discover the current host; if it persists, '
                'restart the app.',
            retryLabel: 'retry',
          );
        case 'BAD_RESPONSE':
          return (
            headline: 'host returned an unexpected response',
            tip:
                'The running host may be a different version than this app. '
                'Retry; if it persists, restart the host (see host.log).',
            retryLabel: 'retry',
          );
        default:
          return (
            headline: 'host control plane error (${e.code})',
            tip: e.message.isNotEmpty
                ? e.message
                : 'See host.log in the log directory for details, then Retry.',
            retryLabel: 'retry',
          );
      }
    }
    final msg = e.toString();
    if (msg.contains('no live control plane')) {
      return (
        headline: 'host control plane did not answer',
        tip:
            'The host process started but its control plane was not reachable '
            'within 30s. Check host.log in the log directory for the '
            'startup error, then Retry.',
        retryLabel: 'retry',
      );
    }
    if (msg.contains('no connect info')) {
      return (
        headline: 'host did not return connection info',
        tip:
            'The host control plane answered but returned no socket address for '
            'this project. Retry; if it persists, check host.log for an error '
            'near the project:open call.',
        retryLabel: 'retry',
      );
    }
    return (
      headline: 'agent failed to start',
      tip:
          'Retry runs the launcher again. If it keeps failing, open the log '
          'directory and check host.log for the underlying stderr trace.',
      retryLabel: 'retry',
    );
  }

  Future<void> _openLogFolder() async {
    final dir = hostDir(); // host.log lives here now (one host per machine)
    try {
      await Directory(dir).create(recursive: true);
      if (Platform.isWindows) {
        // hostDir() yields a mixed-separator path (e.g. C:\Users\me/.antgrid).
        // explorer.exe treats '/' as a switch prefix and silently opens the
        // default Documents view, so hand it pure backslashes.
        await Process.start('explorer.exe', [
          dir.replaceAll('/', r'\'),
        ], runInShell: false);
      } else if (Platform.isMacOS) {
        await Process.start('open', [dir]);
      } else {
        await Process.start('xdg-open', [dir]);
      }
    } catch (_) {
      /* best effort */
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _diagnose();
    return Container(
      color: context.antgrid.bgDeepest,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                d.headline,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontMd,
                  color: context.antgrid.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AbTokens.space10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: context.antgrid.bgDeep,
                  border: Border.all(color: context.antgrid.borderDefault),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AbTokens.space12),
                  child: SelectableText(
                    error.toString(),
                    style: AbTokens.monoStyle(
                      fontSize: AbTokens.fontXs,
                      color: context.antgrid.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AbTokens.space10),
              Text(
                d.tip,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: AbTokens.space12),
              Wrap(
                spacing: AbTokens.space8,
                runSpacing: AbTokens.space8,
                children: [
                  if (onRetry != null)
                    AbButton(
                      label: d.retryLabel,
                      color: context.antgrid.accent,
                      onTap: onRetry,
                      compact: true,
                    ),
                  if (projectId != null)
                    AbButton(
                      label: 'open log folder',
                      onTap: _openLogFolder,
                      compact: true,
                    ),
                  AbButton(label: 'back', onTap: onBack, compact: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Local-mode boot indicator: ticks elapsed seconds until `agent:hello`
/// arrives. Local mode skips the relay/auth/pair phases.
class _LocalBootStatus extends StatefulWidget {
  const _LocalBootStatus();
  @override
  State<_LocalBootStatus> createState() => _LocalBootStatusState();
}

class _LocalBootStatusState extends State<_LocalBootStatus> {
  Timer? _ticker;
  late final DateTime _since;

  @override
  void initState() {
    super.initState();
    _since = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = DateTime.now().difference(_since).inSeconds;
    final detail = secs >= 1 ? ' · ${secs}s' : '';
    return Container(
      color: context.antgrid.bgDeepest,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(AbTokens.space16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '▸ ',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'starting agent',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textPrimary,
              ),
            ),
            Text(
              detail,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
