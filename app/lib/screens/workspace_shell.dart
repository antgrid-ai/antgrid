import 'dart:async';
import 'dart:io' show Directory, Platform, Process;

import 'package:push/push.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart'
    show PointerDownEvent, PointerMoveEvent, PointerUpEvent, VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show LocalTransportHandshakeException, RelayConnectionState, RpcException;

import '../connection/relay_mechanisms.dart' show ConnectionBlockedException;
import '../connection/supervisor_state.dart'
    show BlockReason, Blocked, SupervisorStatus;
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
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
import '../providers/session_search.dart';
import '../providers/sessions.dart';
import '../providers/supervisor_status.dart';
import '../providers/ui_attention_providers.dart';
import '../providers/visible_surface.dart';
import '../services/app_settings_service.dart';
import '../services/local_notification_service.dart';
import '../services/push_background_handler.dart'
    show decodePush, pushDataOf, pushDedupKey;
import '../services/push_identity.dart';
import '../services/sessions_service.dart'
    show SessionOperationException, SessionsService;
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../utils/notification_routing.dart';
import '../utils/platform_utils.dart';
import '../widgets/agent_panel.dart';
import '../widgets/mobile_bottom_nav.dart';
import '../widgets/operational_error_toaster.dart';
import '../widgets/projects_drawer.dart';
import '../widgets/session_search_modal.dart';
import '../widgets/session_start_refusal.dart';
import '../design/widgets/pulsing_opacity.dart';
import '../widgets/resizable_pane.dart';
import '../widgets/workspace_tab_bar.dart';
import '../widgets/ab_banner.dart';
import '../widgets/ab_host_banner.dart';
import '../widgets/workspace_panel.dart';
import '../navigation/back_intent.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import 'app_settings_screen.dart';

/// Mobile page order. The drawer is NOT a page — it stays a `Scaffold.drawer`
/// so it slides in as a panel over the content rather than replacing it — but
/// the swipe that reveals it is the same continuous rightward gesture that
/// walks workspace → agent, so the chain reads as one motion.
abstract final class _MobilePage {
  static const int agent = 0;
  static const int workspace = 1;
}

/// How far the `PageView` must be pulled past its leading edge before the
/// gesture counts as "one more step back".
///
/// Reading the drawer off the page's own overscroll is what makes the swipe
/// work from ANYWHERE rather than from an edge strip: the PageView already owns
/// horizontal drags across the whole viewport, and it already loses them
/// correctly to the horizontal scrollables the agent page is full of (terminal
/// output, transcript diffs, tool-call cards) while those still have room. A
/// drag detector layered over the shell would have had to reproduce all of that
/// by inspection, and would have fought the PageView for every swipe.
const double _kBackOverscrollThreshold = 48.0;

/// Desktop panel arrangement. Persisted by NAME as
/// `ProjectPreferences.panelMode`, so reordering these is safe; renaming one
/// drops that stored preference back to unchosen (see `_PanelModeNames` there).
enum _PanelMode { normal, contextHidden, contextExpanded }

/// Root layout orchestrator.
///
/// Mobile (< kCompactBreakpoint): two-page [PageView] — agent page | workspace
/// page, with the projects drawer a true swipeable `Scaffold.drawer` overlay.
/// Desktop/tablet (>= kCompactBreakpoint): projects drawer + agent panel +
/// context panel. On a MOUSE desktop that's a resizable split with
/// collapsible strips ([_buildDesktop]), toggled from the window title bar,
/// which only mounts at >= kMediumBreakpoint (see app_shell.dart). On any
/// touch platform (Android/iOS) that title bar never mounts at all, at any
/// width — [_buildTabletTouch] gives the SAME docked split as the mouse
/// desktop for both side panes (sidebar open by default, context pane closed
/// until the user asks for it), animated open/closed by swipe or the agent
/// bar's own buttons instead of a title-bar click, since there's no toggle
/// to click there.
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

  /// Null until the user picks a mode (or a stored pref supplies one), so
  /// [_effectivePanelMode] can keep re-deriving the viewport default. Resolving
  /// lazily rather than freezing a value at prefs-apply time is what makes a
  /// phone rotated into landscape pick up the hidden default — prefs are
  /// applied once, while in portrait.
  _PanelMode? _panelMode;
  bool _prefsApplied = false;
  final _mobileScaffoldKey = GlobalKey<ScaffoldState>();

  /// Desktop-shaped layout, touch platform only: both the projects sidebar
  /// and the context panel are docked panes like the mouse desktop's Row
  /// (see [_buildDesktop]), just animated open/closed by swipe rather than a
  /// title-bar toggle that isn't mounted here.
  ///
  /// Whether the touch tablet's docked sidebar pane is open. Starts true —
  /// a session opens with the sidebar already alongside the agent, matching
  /// the mouse desktop's own always-on rail, rather than mobile's swiped-in
  /// overlay. Swiping and the agent bar's "Projects" button both flip this
  /// same flag (see [_openDrawer]), so either one puts the other in sync.
  bool _tabletDrawerOpen = true;

  /// Whether the touch tablet's docked context pane is open. Starts false —
  /// a session opens on the agent alone, full width; the pane only appears
  /// once the user actually asks for it, by swiping, tapping the agent bar's
  /// workspace button while the pane is closed, or picking a view from its
  /// popup menu (see [_openContextPanel], `WorkspaceMenuButton`, and
  /// [_revealWorkspaceView]) — all three flip this same flag, so any one puts
  /// the others in sync.
  bool _tabletEndDrawerOpen = false;

  /// The touch tablet endDrawer's own expand toggle — mirrors the mouse
  /// desktop's [_PanelMode.contextExpanded] but as a width change rather than
  /// a mode, since the panel is already an overlay, not a pane to trade space
  /// with the agent panel.
  bool _tabletContextPanelExpanded = false;

  /// Accumulated leading-edge overscroll past the agent page.
  double _backOverscroll = 0;
  bool _exitPromptOpen = false;

  /// The exact callback published to [openDrawerProvider], held so [deactivate]
  /// can retract ITS OWN and never the next route's (see that provider's doc).
  late final VoidCallback _publishedOpenDrawer = _openDrawer;

  /// Same identity-retraction need as [_publishedOpenDrawer], for the record
  /// published to [sidebarControlProvider] — see the mirrored field's doc in
  /// `new_session_screen.dart`, the other route that publishes this same
  /// provider.
  late final VoidCallback _publishedToggleSidebar = _toggleSidebar;

  /// Identity for the two desktop panels ACROSS [_PanelMode] changes. Each mode
  /// builds a structurally different Row (see [_buildPanels]), so without these
  /// Flutter reconciles by position, fails to match the panel, and unmounts it —
  /// taking the preview's platform WebView and the agent terminal with it. The
  /// rebuilt PreviewScreen then re-anchors from a null origin and reloads the
  /// page through the relay tunnel, which is why toggling the panel used to cost
  /// a full page load rather than a relayout. A GlobalKey makes the mode switch
  /// reparent the live element instead. Not used on the mobile PageView, whose
  /// panels never move between slots.
  final _agentPanelKey = GlobalKey();
  final _contextPanelKey = GlobalKey();

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
          AbLog.error(
            'WorkspaceShell',
            'foreground push failed',
            fields: {'error': '$e'},
          );
        }
      });
    }
    _pageController = PageController(initialPage: _MobilePage.agent);
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
      ref.read(revealHandlerTabProvider.notifier).set(revealHandlerTab);
      ref.read(openDrawerProvider.notifier).set(_publishedOpenDrawer);
      if (ref.read(selectedRegistrationIdProvider) != null) {
        detached(
          'WorkspaceShell',
          'session bootstrap failed',
          _bootstrapSessions,
        );
      }
    });
  }

  @override
  void deactivate() {
    // Capture the notifiers synchronously (ref is still valid here), then
    // defer the state writes so they don't happen mid-build when the widget
    // tree is being restructured (e.g. project switch).
    final notifier = ref.read(switchToAgentProvider.notifier);
    // Same lifetime: the title bar outlives this route, so a stale panel
    // control would leave a dead toggle on the New Session page.
    final panelNotifier = ref.read(contextPanelControlProvider.notifier);
    // Same lifetime again: the New Session route publishes its own control on
    // mount (same pattern, see `new_session_screen.dart`), so a stale one left
    // here would fight it. Retracted by identity too — see
    // _publishedToggleSidebar's doc.
    final sidebarNotifier = ref.read(sidebarControlProvider.notifier);
    // Same lifetime once more: a stale `true` here would leave the title bar
    // withholding the session controls on a route with no agent bar to show
    // them.
    final agentBarNotifier = ref.read(agentBarMountedProvider.notifier);
    // The reveal callback closes over this State (setState + _pageController),
    // so leaving it published would let the agent header's NEEDS YOU pill call
    // into a disposed shell after a project switch.
    final revealNotifier = ref.read(revealHandlerTabProvider.notifier);
    // Same lifetime again: a stale tab left published here would let a back
    // press dispatch into handlers this route no longer has.
    final visibleViewNotifier = ref.read(visibleWorkspaceViewProvider.notifier);
    // Closes over this State via `_revealWorkspaceView`, so the same rule as
    // the reveal callback above: left published, the agent bar's workspace menu
    // would call setState on a disposed shell.
    final menuNotifier = ref.read(workspaceMenuControlProvider.notifier);
    // Closes over _pageController too, so the same rule: NewSessionScreen
    // republishes its own on mount, and a stale one would animate a dead route.
    // Retracted by identity, not unconditionally — see openDrawerProvider's doc:
    // NewSessionScreen has already published its own by the time this runs.
    final openDrawerNotifier = ref.read(openDrawerProvider.notifier);
    final container = ref.container;
    // `scheduleMicrotask` defers the write off the current build/restructure
    // phase (same intent as the previous `Future(() => ...)`) but does not
    // create a Timer, so it doesn't leak in widget tests under fake_async.
    // The try/catch silences the benign "used after dispose" case when the
    // microtask fires after the entire ProviderContainer has been torn down
    // (app shutdown, or fast widget-tree disposal in tests).
    scheduleMicrotask(() {
      try {
        notifier.set(null);
        panelNotifier.set(null);
        if (identical(
          container.read(sidebarControlProvider)?.toggle,
          _publishedToggleSidebar,
        )) {
          sidebarNotifier.set(null);
        }
        agentBarNotifier.set(false);
        revealNotifier.set(null);
        visibleViewNotifier.set(null);
        menuNotifier.set(null);
        if (identical(
          container.read(openDrawerProvider),
          _publishedOpenDrawer,
        )) {
          openDrawerNotifier.set(null);
        }
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
    super.dispose();
  }

  // ── Terminal notifications ───────────────────────────────────────────

  void _onNotification(TerminalNotificationMessage msg) {
    // A session terminal's id IS the session id (service PTYs use their own,
    // which never matches an active session).
    if (_isViewingSession(msg.terminalId)) return;
    final body = (msg.body != null && msg.body!.isNotEmpty)
        ? msg.body!
        : 'Notification';
    final title = (msg.title != null && msg.title!.isNotEmpty)
        ? msg.title!
        : 'Agent';
    _onAgentNotification(title: title, body: body);
  }

  /// Reads the live focus state into [isViewingSession] — every surfacer below
  /// checks it first, so nothing is announced about the chat already on screen.
  bool _isViewingSession(String? sessionId) => isViewingSession(
    sessionId: sessionId,
    activeSessionId: ref.read(activeSessionIdProvider),
    onWorkspaceSurface:
        ref.read(workbenchSurfaceProvider) == WorkbenchSurface.workspace,
    // On mobile the workspace surface is a PageView, so being on it does not
    // mean the transcript is showing — a user reading files must still be told.
    agentSurfaceVisible: ref.read(agentSurfaceVisibleProvider),
    lifecycle: _lifecycle,
  );

  void _onAgentNotificationPush(NotificationPushMessage msg) {
    if (_isViewingSession(msg.sessionId)) return;
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
    // Handler escalations name their session in `terminalId`.
    if (_isViewingSession(esc.terminalId)) return;
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
    // An unrecognized name resolves to null — unchosen, so the viewport default
    // applies — rather than throwing on prefs written by a newer build.
    final storedMode = prefs.panelMode;
    _panelMode = storedMode == null
        ? null
        : _PanelMode.values.asNameMap()[storedMode];

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
        // Null while unchosen, which copyWith reads as "leave alone" — so a
        // split-drag or tab switch never pins the derived default as if the
        // user had picked it.
        panelMode: _panelMode?.name,
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
  ///
  /// Both callers run this detached, so nothing here may reject — see
  /// [detached].
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
          // The cross-project half of a session-row / Recent-list tap, so a
          // refused start has to speak here too — otherwise the same tap reports
          // its failure only when the project happened to be focused already.
          // The `active.first` auto-start below stays silent: it is aimed at no
          // session the user named.
          try {
            await _startBestEffort(svc, desired.id, raiseRefusal: true);
          } on SessionOperationException catch (error) {
            if (mounted) reportStartRefusal(context, error);
            return;
          }
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
        await _startBestEffort(svc, session.id);
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

  /// Auto-start on project-open, which the user did not ask for and is not
  /// waiting on. A dropped or late `session:start` reply throws (the service's
  /// 15s pending-reply bound) — routine when the project is opened on a resume
  /// that finds the transport still re-establishing — and the bridge may well
  /// have started the session anyway, with `session:updated` reconciling the row.
  /// So the failure is logged and the bootstrap continues to the focus + nav
  /// writes below rather than abandoning them; the stopped-session empty state
  /// carries the retry if the start really never landed.
  ///
  /// [raiseRefusal] is for the one caller whose session the user NAMED. A coded
  /// refusal there is the bridge's answer that the session did not start — not
  /// a dropped frame — so it is rethrown for the caller to show. Everything
  /// else stays swallowed either way: the two failures are different events and
  /// only the first is worth interrupting a project open for.
  Future<void> _startBestEffort(
    SessionsService svc,
    String sessionId, {
    bool raiseRefusal = false,
  }) async {
    try {
      await svc.start(sessionId, raiseRefusal: raiseRefusal);
    } on SessionOperationException {
      rethrow;
    } catch (e) {
      AbLog.error(
        'WorkspaceShell',
        'auto-start failed',
        fields: {'sessionId': sessionId, 'error': '$e'},
      );
    }
  }

  // ── Public API (used by send-to-agent) ───────────────────────────────

  void switchToAgentPage() => _goToPage(_MobilePage.agent);

  /// Reveal the Handler workspace tab from anywhere (e.g. the agent header's
  /// NEEDS YOU pill). Desktop: selects the sidebar view, un-hiding the panel
  /// first if the user had it closed — a pill that selected a tab nobody can
  /// see would answer a call to action with nothing at all. Mobile: also swipes
  /// to the workspace page.
  void revealHandlerTab() {
    _openContextPanel();
    _selectView(WorkspaceView.handler);
    _goToPage(_MobilePage.workspace);
  }

  /// Opens the projects drawer on mobile. Published through `openDrawerProvider`
  /// so the agent header's button can reach it from above this State.
  void openMobileDrawer() {
    final scaffold = _mobileScaffoldKey.currentState;
    if (scaffold != null && !scaffold.isDrawerOpen) scaffold.openDrawer();
  }

  /// Opens the projects drawer regardless of which layout is live, so
  /// [openDrawerProvider]'s one published callback works whether the window is
  /// phone width ([openMobileDrawer]'s [_mobileScaffoldKey]) or a touch
  /// tablet (the docked sidebar pane, see [_buildTabletTouch]). A mouse
  /// desktop publishes no callback at all — its drawer opens from the window
  /// title bar instead — so this is never called there.
  void _openDrawer() {
    if (_isMobileLayout) {
      openMobileDrawer();
      return;
    }
    if (!_tabletDrawerOpen) setState(() => _tabletDrawerOpen = true);
  }

  void _goToPage(int page) {
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  int get _currentPage => _pageController.hasClients
      ? (_pageController.page?.round() ?? _MobilePage.agent)
      : _MobilePage.agent;

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
      detached(
        'WorkspaceShell',
        'session bootstrap failed',
        _bootstrapSessions,
      );
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

    // Watched rather than listened to, and only past the boot gate above,
    // because a rebuild is also the RETRY: a link can name a tab before this
    // route has prefs or a PageView, and the build that finally lands one is the
    // frame the drain has to run on. Deferred a frame so the drain's provider
    // writes never land during build.
    if (ref.watch(pendingWorkspaceViewProvider) != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _drainPendingWorkspaceView();
      });
    }

    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < kCompactBreakpoint;

    // Resolved here rather than per-layout so the desktop visibility gate below
    // sees it: an overlay surface replaces the panels entirely, and publishing a
    // tab it has unmounted is the same lie the mobile path already guards.
    final surfaceChild = _workbenchSurfaceChild(
      ref.watch(workbenchSurfaceProvider),
    );
    // Desktop always shows the agent panel; mobile visibility is set by the
    // PageView's onPageChanged (and the mobile initializer), so only force-true
    // here on desktop to avoid clobbering the mobile page state.
    if (!isMobile) {
      // Two entirely different mechanisms drive these, branching on platform:
      // a mouse desktop's [_PanelMode] (toggled from the window title bar) vs.
      // a touch tablet's own docked-pane open state (toggled by swipe or a
      // button in AgentBar — see [_buildDesktop]/[_buildTabletTouch]). Both
      // still feed the SAME providers below, so nothing downstream needs to
      // know which layout produced them.
      final touch = isMobilePlatform;
      // contextPanelControlProvider/sidebarControlProvider feed ONLY the
      // window title bar's pane-toggle icons, which never mount on a touch
      // platform (see app_shell.dart) — published null there, same as the
      // isMobile (phone-width) case above skips this whole block.
      final control = touch
          ? null
          : (
              hidden: _effectivePanelMode == _PanelMode.contextHidden,
              toggle: _toggleContextPanel,
            );
      // Below the title bar's own mount floor there is no toggle to restore
      // it with, so the drawer can never actually be hidden there — see the
      // same gate in [_buildDesktop].
      final sidebar = touch
          ? null
          : (
              hidden:
                  width >= kMediumBreakpoint &&
                  ref.watch(appSettingsServiceProvider).sidebarHidden,
              toggle: _publishedToggleSidebar,
            );
      // Which workspace view is genuinely on screen: the docked tab (mouse
      // desktop) or the open endDrawer's tab (touch tablet), or nothing at all
      // behind a workbench surface or a hidden/closed panel. Shared by the
      // back-handler gate and the menu's check mark so the two can never
      // disagree.
      final visibleView = surfaceChild != null
          ? null
          : touch
                ? (_tabletEndDrawerOpen ? _selectedView : null)
                : (_effectivePanelMode == _PanelMode.contextHidden
                      ? null
                      : _selectedView);
      final menu = surfaceChild != null
          ? null
          : (
              active: visibleView,
              reveal: _revealWorkspaceView,
              open: _openContextPanel,
            );
      // Whether [_agentPanel] is actually mounted/on screen: false behind a
      // workbench surface (settings/new-session); on a mouse desktop, also
      // false in [_PanelMode.contextExpanded] (only the workspace panel
      // renders there, full width); on a touch tablet, also false only while
      // the context pane is BOTH open and expanded — the sidebar and the
      // context pane's normal open states are docks, not overlays, so either
      // (or both) being open still leaves the agent genuinely on screen
      // beside them, same as the mouse desktop's [_PanelMode.normal]. Shared
      // by [agentBarMountedProvider] (the title bar's "does a route below me
      // own the session controls" gate) and [agentSurfaceVisibleProvider]
      // (whether the transcript is on screen for notification-suppression
      // purposes) so the two can never disagree.
      final agentPanelVisible =
          surfaceChild == null &&
          (touch
              ? !(_tabletEndDrawerOpen && _tabletContextPanelExpanded)
              : _effectivePanelMode != _PanelMode.contextExpanded);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(agentSurfaceVisibleProvider) != agentPanelVisible) {
          ref.read(agentSurfaceVisibleProvider.notifier).set(agentPanelVisible);
        }
        // Publish the panel control for the title bar, which mounts above this
        // route and so cannot reach this State. A record of equal fields is ==,
        // so an unchanged mode re-publishes without notifying.
        ref.read(contextPanelControlProvider.notifier).set(control);
        // Same handover, for the agent bar's workspace menu — it is mounted
        // inside AgentPanel and cannot reach this State either.
        ref.read(workspaceMenuControlProvider.notifier).set(menu);
        // Desktop only, and for the whole route — the settings overlay covers
        // the panels but leaves the drawer beside it, so it stays toggleable
        // there too.
        ref.read(sidebarControlProvider.notifier).set(sidebar);
        // The arrangements that mount no AgentPanel are the ones where the
        // window title bar has to take the session controls back (see the
        // provider).
        ref.read(agentBarMountedProvider.notifier).set(agentPanelVisible);
        // A hidden context panel — or an overlay surface covering the whole
        // route — means no workspace tab is on screen at all, so nothing in it
        // may consume a back press.
        ref.read(visibleWorkspaceViewProvider.notifier).set(visibleView);
      });
    }

    // Back/forward inputs (Alt+←, ⌘[, mouse side buttons) live in AppBackScope
    // so they behave identically on the New Session route, which this shell
    // isn't mounted under. Only the workspace-specific bindings stay here.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSessionSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _focusSessionSearch,
        // ⌥⌘→ / Ctrl+Alt+→ — macOS's inspector-pane toggle. Distinct from the
        // alt-only forward binding in AppBackScope: SingleActivator requires an
        // exact modifier match, so alt+meta never lands on alt.
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          alt: true,
          meta: true,
        ): _toggleContextPanel,
        const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          alt: true,
          control: true,
        ): _toggleContextPanel,
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
            Expanded(
              child: isMobile
                  ? _buildMobile(surfaceChild)
                  : _buildDesktop(surfaceChild),
            ),
          ],
        ),
      ),
    );
  }

  /// Ctrl/⌘-K. On desktop, focusing the title-bar field is all it takes: the
  /// field opens its result popup on focus, so this one binding both reveals
  /// the search and shows the recent sessions to pick from. The node is
  /// provider-owned because that field mounts above this route.
  ///
  /// A narrow window has no title-bar field to focus — its search is a modal —
  /// so the binding opens that instead. Below kMediumBreakpoint there's no
  /// title bar at all (mobile and tablet alike — see app_shell.dart); a touch
  /// platform has none EITHER, at any width — a keyboard is rare but not
  /// impossible on a tablet, and this must not be a silent no-op against a
  /// field that was never mounted.
  void _focusSessionSearch() {
    if (isMobilePlatform || MediaQuery.sizeOf(context).width < kMediumBreakpoint) {
      showSessionSearch(context);
      return;
    }
    ref.read(sessionSearchFocusProvider).requestFocus();
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

  Widget _buildMobile(Widget? surfaceChild) {
    // Seed the surface-visibility state from the current page after the first
    // frame — onPageChanged only fires on subsequent swipes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Mobile reaches the workspace by swiping to its own page, so there is no
      // menu to publish — and a value left over from a desktop-width layout
      // would survive a window resize into this one.
      ref.read(workspaceMenuControlProvider.notifier).set(null);
      if (surfaceChild != null) {
        ref.read(agentSurfaceVisibleProvider.notifier).set(false);
        ref.read(visibleWorkspaceViewProvider.notifier).set(null);
        return;
      }
      _publishVisibleSurfaces(_currentPage);
    });
    return BackHandler(
      priority: BackPriority.drawer,
      onBack: _closeMobileDrawer,
      child: Scaffold(
        key: _mobileScaffoldKey,
        backgroundColor: context.antgrid.bgDeepest,
        // The page overscroll below is the way in, and it works from anywhere;
        // an edge strip on top of it would only hand the OS back gesture
        // something to collide with.
        drawerEdgeDragWidth: 0,
        drawer: Drawer(
          backgroundColor: context.antgrid.bgDeep,
          width: 304,
          child: SafeArea(
            // A rightward fling with the drawer already open is the end of the
            // chain — nothing left to unwind.
            child: _HorizontalFlingDetector(
              towards: AxisDirection.right,
              onFling: _confirmExitFling,
              child: const ProjectsDrawer(),
            ),
          ),
        ),
        body:
            surfaceChild ??
            BackHandler(
              priority: BackPriority.mobileAgentPage,
              onBack: _backToAgentPage,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onPageScroll,
                child: PageView(
                  controller: _pageController,
                  onPageChanged: _publishVisibleSurfaces,
                  children: [
                    // The page's leading overscroll below is the primary way to
                    // the drawer, but it only reports "one more step back" once
                    // every horizontal scrollable under the finger has run out
                    // of room — over a terminal wide enough to scroll, it never
                    // does, so the gesture died exactly where the agent page is
                    // busiest. A fling on top gives this page the same
                    // flick-right-for-the-drawer the New Session route has,
                    // from anywhere on it.
                    _HorizontalFlingDetector(
                      towards: AxisDirection.right,
                      onFling: _flingOpenDrawer,
                      child: AgentPanel(),
                    ),
                    Column(
                      children: [
                        Expanded(
                          child: WorkspacePanel(
                            selectedView: _selectedView,
                            onViewSelected: _selectView,
                            viewBadges: _workspaceBadges(),
                            showTabBar: false,
                          ),
                        ),
                        MobileBottomNav(
                          selected: _selectedView,
                          badges: _workspaceBadges(),
                          onSelected: _selectView,
                          onOpenDrawer: openMobileDrawer,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ),
    );
  }

  void _publishVisibleSurfaces(int page) {
    ref
        .read(agentSurfaceVisibleProvider.notifier)
        .set(page == _MobilePage.agent);
    ref
        .read(visibleWorkspaceViewProvider.notifier)
        .set(page == _MobilePage.workspace ? _selectedView : null);
  }

  /// A rightward pull past the agent page — one step further back than the
  /// PageView itself can go — reveals the drawer.
  ///
  /// Only the LEADING edge: overscrolling past the workspace page is just the
  /// end of the tabs and must do nothing.
  bool _onPageScroll(ScrollNotification notification) {
    // ONLY the PageView's own notifications. The agent page is full of nested
    // scrollables (transcript list, terminal, tool-call rows) and every one of
    // them overscrolls at its leading edge — without this gate, flicking the
    // transcript to the top opened the drawer. `depth` counts the viewports a
    // notification has bubbled through, so the PageView's are 0 and a nested
    // scrollable's are >= 1.
    if (notification.depth != 0) return false;
    // Never consume: the PageView's own scroll machinery is downstream of this.
    if (notification is ScrollEndNotification) {
      _backOverscroll = 0;
      return false;
    }
    if (_currentPage != _MobilePage.agent) return false;

    // Two physics, two ways of saying "pulled past the leading edge": Android's
    // ClampingScrollPhysics refuses the pixels and reports them as overscroll,
    // while iOS's BouncingScrollPhysics lets the position itself go negative and
    // returns 0 from applyBoundaryConditions — so it NEVER emits
    // OverscrollNotification. Reading only the former left this gesture dead on
    // iOS. Bouncing also applies friction, so the same threshold costs a longer
    // drag there, which suits a gesture that shouldn't fire by accident.
    final double pastEdge;
    if (notification is OverscrollNotification) {
      if (notification.overscroll >= 0) return false;
      // A single flick arrives as many small notifications, so accumulate
      // rather than firing on the first stray pixel.
      pastEdge = _backOverscroll + -notification.overscroll;
    } else if (notification is ScrollUpdateNotification) {
      // Absolute, not accumulated: the position already carries the total.
      final beyond =
          notification.metrics.minScrollExtent - notification.metrics.pixels;
      if (beyond <= 0) return false;
      pastEdge = beyond;
    } else {
      return false;
    }

    _backOverscroll = pastEdge;
    if (pastEdge >= _kBackOverscrollThreshold) {
      _backOverscroll = 0;
      openMobileDrawer();
    }
    return false;
  }

  /// A fling over the agent page means "drawer" only while that page is the one
  /// on screen: the detector wraps a PageView child, which still holds pointers
  /// mid-transition from the workspace page — and there the swipe's whole job
  /// was the page change that is already under way.
  void _flingOpenDrawer() {
    if (_currentPage != _MobilePage.agent) return;
    openMobileDrawer();
  }

  void _confirmExitFling() =>
      detached('WorkspaceShell', 'exit prompt failed', _confirmExit);

  Future<void> _confirmExit() async {
    // A flick can deliver the threshold twice before the dialog mounts.
    if (_exitPromptOpen) return;
    _exitPromptOpen = true;
    // Captured before the await: `ref` is dead if this State is disposed while
    // the dialog is up, and the exit must still flush prefs.
    final container = ref.container;
    try {
      final go = await AbConfirmDialog.show(
        context: context,
        title: 'Close Antgrid?',
        body: 'Sessions keep running on your machine.',
        confirmLabel: 'Close',
        destructive: true,
      );
      if (go) await exitApp(container);
    } finally {
      _exitPromptOpen = false;
    }
  }

  /// Switch the context-panel tab. Publishes the new tab so back handlers
  /// registered by the OTHER (still-mounted, offscreen) tabs stay inert.
  void _selectView(WorkspaceView view) {
    setState(() {
      _selectedView = view;
      _updatePrefs();
    });
    ref.read(visibleWorkspaceViewProvider.notifier).set(view);
  }

  /// Un-hides the context panel so a revealed view is actually visible,
  /// through whichever mechanism the live layout offers: opening the touch
  /// tablet's docked context pane ([_buildTabletTouch]), or restoring
  /// [_PanelMode.normal] on a mouse desktop. No-op on the mobile PageView
  /// layout, which has no docked panel to reveal — callers there fall back to
  /// the ordinary tab switch / page swipe.
  void _openContextPanel() {
    if (_isMobileLayout) return;
    if (isMobilePlatform) {
      if (!_tabletEndDrawerOpen) setState(() => _tabletEndDrawerOpen = true);
      return;
    }
    if (_effectivePanelMode == _PanelMode.contextHidden) {
      setState(() => _panelMode = _PanelMode.normal);
    }
  }

  /// Put [view] in front of the user in the docked context panel, un-hiding it
  /// first if the user had it closed — the same recovery [revealHandlerTab]
  /// gives the NEEDS YOU pill, since the menu is reachable from panel modes
  /// where the context panel is off screen entirely.
  ///
  /// The entry point for every caller that names a view from outside the tab
  /// strip: the agent bar's workspace menu.
  ///
  /// Mobile never gets here (the menu is desktop-only, see
  /// [workspaceMenuControlProvider]), but falls back to the ordinary tab
  /// switch, which is a no-op past the guard above.
  void _revealWorkspaceView(WorkspaceView view) {
    _openContextPanel();
    _selectView(view);
  }

  /// Show the view a navigation left in [pendingWorkspaceViewProvider].
  ///
  /// Spent only once it has actually been honoured, so a route that cannot show
  /// it yet leaves it for the rebuild that can — dropping it there would make
  /// the link a silent no-op. A value stamped for another project is spent
  /// without being shown: it named a destination this route is not.
  void _drainPendingWorkspaceView() {
    final pending = ref.read(pendingWorkspaceViewProvider);
    if (pending == null) return;
    final notifier = ref.read(pendingWorkspaceViewProvider.notifier);
    if (pending.target != ref.read(selectedTargetProvider)) {
      notifier.set(null);
      return;
    }
    final mobile = _isMobileLayout;
    // Mobile needs the PageView, which does not exist until a build past the
    // boot gate — and a tab switched behind the page the user is looking at
    // reads as a no-op, so the move is half the request, not a flourish.
    if (mobile && !_pageController.hasClients) return;
    notifier.set(null);
    if (mobile) {
      // [_revealWorkspaceView] already degrades to the tab here, but leaves
      // the PageView on the agent page.
      _selectView(pending.value);
      _goToPage(_MobilePage.workspace);
      return;
    }
    // Desktop un-hides the docked context panel and selects the view there —
    // same recovery [revealHandlerTab] gives the NEEDS YOU pill, since a
    // navigation can land while the panel is off screen entirely.
    _revealWorkspaceView(pending.value);
  }

  bool get _isMobileLayout =>
      MediaQuery.sizeOf(context).width < kCompactBreakpoint;

  bool _closeMobileDrawer() {
    final scaffold = _mobileScaffoldKey.currentState;
    if (!(scaffold?.isDrawerOpen ?? false)) return false;
    scaffold!.closeDrawer();
    return true;
  }

  bool _backToAgentPage() {
    if (!_pageController.hasClients) return false;
    if (_currentPage != _MobilePage.workspace) return false;
    switchToAgentPage();
    return true;
  }

  Map<WorkspaceView, int> _workspaceBadges() =>
      ref.watch(workspaceBadgesProvider);

  // ── Desktop / Tablet ─────────────────────────────────────────────────

  Widget _buildDesktop(Widget? surfaceChild) {
    if (isMobilePlatform) return _buildTabletTouch(surfaceChild);
    // The setting is shared with the New Session route (see
    // `new_session_screen.dart`, which publishes its own sidebarControlProvider
    // the same way), so hiding the drawer here also hides it there and vice
    // versa — one restore button, reachable from both. Below kMediumBreakpoint
    // that restore button doesn't even mount (no title bar there — see
    // app_shell.dart), so the drawer stays forced visible the whole way down
    // to kCompactBreakpoint.
    final sidebarHidden =
        MediaQuery.sizeOf(context).width >= kMediumBreakpoint &&
        ref.watch(appSettingsServiceProvider).sidebarHidden;
    return Row(
      children: [
        if (!sidebarHidden) const ProjectsDrawer(),
        if (surfaceChild != null)
          Expanded(child: surfaceChild)
        else
          ..._buildPanels(),
      ],
    );
  }

  /// Touch-platform counterpart to [_buildDesktop]'s mouse `Row`: the same
  /// sidebar+agent+context split, both side panes docked rather than
  /// overlays — the sidebar open by default (matching the mouse desktop's
  /// always-on rail), the context pane closed until the user asks for it
  /// (see [_tabletEndDrawerOpen]'s doc for the three ways in). There is no
  /// title bar here to toggle either from (app_shell.dart never mounts one
  /// on a touch platform), so swiping and the agent bar's own buttons
  /// (`WorkspaceMenuButton`, the leading "Projects" button) are the only
  /// paths in either side.
  ///
  /// Neither pane's WIDTH ever changes during its open/close animation —
  /// only an [AnimatedSlide] offset does, so neither [ProjectsDrawer] nor
  /// [WorkspacePanel] is ever laid out at an intermediate width where a tab
  /// bar or row could overflow mid-swipe. The agent pane's reserved space on
  /// both sides animates instead, via one [AnimatedPadding] on the SAME
  /// duration/curve as both slides, so all three move in lockstep and the
  /// agent bar's buttons visibly slide with whichever panel is animating
  /// rather than sitting still underneath it.
  ///
  /// Neither pane is a real `Scaffold.drawer`/`endDrawer`: Flutter's
  /// `DrawerController` drops its child from the tree entirely while closed
  /// (`_buildDrawer`'s `if (_controller.isDismissed) return
  /// SizedBox.shrink()`), which would dispose [WorkspacePanel]'s
  /// `PreviewScreen` WebView and terminal on every swipe-close of the context
  /// pane — the exact regression the [_agentPanelKey]/[_contextPanelKey]
  /// GlobalKeys elsewhere in this file exist to prevent (see their doc). So
  /// both hand-roll a slide-in pane that stays permanently mounted, just
  /// animated off-screen via [AnimatedSlide] rather than removed. The
  /// sidebar itself ([ProjectsDrawer]) carries no such disposable state, but
  /// gets the same treatment for the shared lockstep animation.
  Widget _buildTabletTouch(Widget? surfaceChild) {
    // A workbench surface (settings/devices) takes the whole route, exactly as
    // it does on the mouse desktop, where [_buildDesktop] swaps it in for
    // `_buildPanels()` outright. The panes here are Stack children painted
    // ABOVE the surface, so leaving the context one up would drop it across
    // the settings screen's right-hand side; dropping it from the tree while a
    // surface covers the route is also what disposes its WebView, matching the
    // desktop's own behaviour in that mode.
    final showContextPane = surfaceChild == null && _tabletEndDrawerOpen;
    return BackHandler(
      priority: BackPriority.drawer,
      onBack: _closeTabletDrawers,
      child: Scaffold(
        backgroundColor: context.antgrid.bgDeepest,
        body: Stack(
          children: [
            // Leftward fling opens the context panel, rightward fling opens
            // the sidebar — both watch raw pointers independently (see
            // [_HorizontalFlingDetector]'s own doc), so nesting them over the
            // same agent pane never has one steal the other's gesture, or
            // either one steal from the agent's own scrollables (terminal,
            // transcript).
            _HorizontalFlingDetector(
              towards: AxisDirection.left,
              onFling: () {
                if (!_tabletEndDrawerOpen) {
                  setState(() => _tabletEndDrawerOpen = true);
                }
              },
              child: _HorizontalFlingDetector(
                towards: AxisDirection.right,
                onFling: () {
                  if (!_tabletDrawerOpen) {
                    setState(() => _tabletDrawerOpen = true);
                  }
                },
                // Padded, not resized: the agent's own content already
                // reflows across arbitrary widths (the mouse desktop's
                // [ResizablePane] drag does the same thing continuously), so
                // animating this side is safe where animating either panel's
                // width would not be.
                child: AnimatedPadding(
                  duration: AbTokens.motionPane,
                  curve: Curves.easeOut,
                  padding: EdgeInsets.only(
                    left: _tabletDrawerOpen ? AbTokens.drawerPaneWidth : 0,
                    right: showContextPane
                        ? _tabletContextPanelWidth(context)
                        : 0,
                  ),
                  // Stays mounted even at zero readable width (both panes
                  // open): swapping it out for a placeholder at this same
                  // GlobalKey'd slot — mirroring how desktop's
                  // [_PanelMode.contextExpanded] drops [_agentPanel] from
                  // [_buildPanels]'s list — corrupted the element tree here
                  // instead (this slot sits under an [AnimatedPadding], not a
                  // plain list, and swapping widget types under it blanked
                  // the whole screen). [WorkspaceMenuButton]'s popup is left
                  // alone here too: it stays open across this squeeze by
                  // design — only the icon itself closes it, expand/collapse
                  // included — see the button's own "pinned, not modal" doc.
                  child: surfaceChild ?? _agentPanel(),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: AbTokens.drawerPaneWidth,
              child: AnimatedSlide(
                duration: AbTokens.motionPane,
                curve: Curves.easeOut,
                offset: _tabletDrawerOpen
                    ? Offset.zero
                    : const Offset(-1, 0),
                // Leftward fling on the sidebar itself closes it — the
                // mirror image of the context panel's own rightward-closes
                // gesture below.
                child: _HorizontalFlingDetector(
                  towards: AxisDirection.left,
                  onFling: () {
                    if (_tabletDrawerOpen) {
                      setState(() => _tabletDrawerOpen = false);
                    }
                  },
                  child: ColoredBox(
                    color: context.antgrid.bgDeep,
                    child: SafeArea(child: const ProjectsDrawer()),
                  ),
                ),
              ),
            ),
            if (surfaceChild == null)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: _tabletContextPanelWidth(context),
                child: AnimatedSlide(
                  duration: AbTokens.motionPane,
                  curve: Curves.easeOut,
                  offset: showContextPane
                      ? Offset.zero
                      : const Offset(1, 0),
                  // Rightward fling on the panel itself closes it — the same
                  // direction/gesture the mobile drawer already uses, reused
                  // verbatim here.
                  child: _HorizontalFlingDetector(
                    towards: AxisDirection.right,
                    onFling: () {
                      if (_tabletEndDrawerOpen) {
                        setState(() => _tabletEndDrawerOpen = false);
                      }
                    },
                    child: ColoredBox(
                      color: context.antgrid.bgDeep,
                      child: WorkspacePanel(
                        key: _contextPanelKey,
                        selectedView: _selectedView,
                        onViewSelected: _selectView,
                        viewBadges: _workspaceBadges(),
                        isExpanded: _tabletContextPanelExpanded,
                        onToggleExpand: () => setState(
                          () => _tabletContextPanelExpanded =
                              !_tabletContextPanelExpanded,
                        ),
                        onClose: () =>
                            setState(() => _tabletEndDrawerOpen = false),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Width of the touch tablet's docked context pane: wide enough to usefully
  /// show a file diff or terminal, narrower than the full screen so the agent
  /// pane still reads as on screen alongside it, not buried underneath —
  /// [_tabletContextPanelExpanded] (the tab bar's expand button, mirroring the
  /// mouse desktop's [_PanelMode.contextExpanded]) goes fully edge-to-edge
  /// instead, same as that mode leaving no agent pane visible at all.
  double _tabletContextPanelWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (_tabletContextPanelExpanded) return width;
    return (width * 0.85).clamp(0.0, 560.0);
  }

  /// Closes whichever of the touch tablet's sidebar/context pane is open —
  /// the `BackPriority.drawer` handler for [_buildTabletTouch], mirroring
  /// [_closeMobileDrawer]'s bool-return contract. The context pane takes
  /// priority: it is the one more likely to be mid-read (a file, a diff) when
  /// back is pressed.
  ///
  /// Neither pane is a real Scaffold drawer/endDrawer (see
  /// [_buildTabletTouch]), so both close via their own state flag rather than
  /// a ScaffoldState call.
  bool _closeTabletDrawers() {
    if (_tabletEndDrawerOpen) {
      setState(() => _tabletEndDrawerOpen = false);
      return true;
    }
    if (_tabletDrawerOpen) {
      setState(() => _tabletDrawerOpen = false);
      return true;
    }
    return false;
  }

  void _toggleSidebar() {
    final settings = ref.read(appSettingsServiceProvider);
    unawaited(
      ref
          .read(appSettingsServiceProvider.notifier)
          .setSidebarHidden(!settings.sidebarHidden),
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
      // No longer a surface of its own: the device roster lives in the title
      // bar's RemoteAccessPanel. Kept only so a lingering `devices` deep link
      // no-ops the same way here as on new_session_screen.dart.
      WorkbenchSurface.remoteDevices ||
      WorkbenchSurface.workspace ||
      WorkbenchSurface.newSession => null,
    };
  }

  /// Show/hide the context panel, preserving [_splitRatio] across the round
  /// trip. Hiding from [_PanelMode.contextExpanded] is allowed — the agent
  /// panel comes back with it, which is the only sane restore for a mode whose
  /// own affordances are off screen.
  void _toggleContextPanel() {
    // No-op on the mobile layout, which is a PageView with no panel modes —
    // the keyboard binding is shared with desktop.
    if (_isMobileLayout) return;
    setState(() {
      _panelMode = _effectivePanelMode == _PanelMode.contextHidden
          ? _PanelMode.normal
          : _PanelMode.contextHidden;
      _updatePrefs();
    });
  }

  /// The tab bar's close button. Unlike [_toggleContextPanel] this is one-way:
  /// it hides from either visible mode (normal or expanded), and the title
  /// bar's panel control is the only way back.
  void _hideContextPanel() {
    setState(() {
      _panelMode = _PanelMode.contextHidden;
      _updatePrefs();
    });
  }

  /// The user's stored choice, or [_defaultPanelMode] while they have none.
  _PanelMode get _effectivePanelMode => _panelMode ?? _defaultPanelMode;

  /// Tablets (either orientation) and phones in landscape reach the desktop
  /// three-zone layout at a fraction of a desktop's width, where splitting it
  /// leaves the agent terminal — the primary view — unusably narrow. So the
  /// context panel starts hidden there and stays one tap away in the title bar.
  ///
  /// Keyed on [isMobilePlatform], not width alone: a deliberately narrow
  /// desktop window is still a desktop, and a tablet in landscape is still a
  /// tablet at 1024px. Phone portrait never reaches here — it renders the
  /// PageView, which has no panel modes.
  _PanelMode get _defaultPanelMode =>
      isMobilePlatform ? _PanelMode.contextHidden : _PanelMode.normal;

  /// Shared by the two modes that mount an [AgentPanel]. The GlobalKey is what
  /// makes a mode switch reparent the live panel rather than unmount it — see
  /// [_agentPanelKey].
  Widget _agentPanel() => AgentPanel(key: _agentPanelKey);

  List<Widget> _buildPanels() {
    switch (_effectivePanelMode) {
      case _PanelMode.normal:
        return [
          Expanded(
            child: ResizablePane(
              initialRatio: _splitRatio,
              onRatioChanged: (r) {
                _splitRatio = r;
                _updatePrefs();
              },
              left: _agentPanel(),
              right: WorkspacePanel(
                key: _contextPanelKey,
                selectedView: _selectedView,
                onViewSelected: _selectView,
                viewBadges: _workspaceBadges(),
                isExpanded: false,
                onToggleExpand: () => setState(() {
                  _panelMode = _PanelMode.contextExpanded;
                  _updatePrefs();
                }),
                onClose: _hideContextPanel,
              ),
            ),
          ),
        ];

      // Fully hidden, not collapsed to a strip: the window title bar's panel
      // control is the restore affordance (see [contextPanelControlProvider]),
      // so a vertical stub would be dead chrome eating horizontal space the
      // user just asked to reclaim.
      case _PanelMode.contextHidden:
        return [Expanded(child: _agentPanel())];

      // No collapsed agent stub here either: the title bar's context-panel
      // control (see [_toggleContextPanel]) is the only way back, same as
      // [_PanelMode.contextHidden] below — a tappable strip duplicated that
      // recovery path for no benefit and cost every expanded panel a sliver
      // of width.
      case _PanelMode.contextExpanded:
        return [
          Expanded(
            child: WorkspacePanel(
              key: _contextPanelKey,
              selectedView: _selectedView,
              onViewSelected: _selectView,
              viewBadges: _workspaceBadges(),
              isExpanded: true,
              onToggleExpand: () => setState(() {
                _panelMode = _PanelMode.normal;
                _updatePrefs();
              }),
              onClose: _hideContextPanel,
            ),
          ),
        ];
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────
}

/// Fires [onFling] on a decisive horizontal fling over its child, in the
/// [towards] direction ([AxisDirection.left] or [AxisDirection.right]).
///
/// One detector for both directions, not a pair of mirrored ones: every term
/// below — the thresholds, the axis-dominance guard, the raw-pointer wiring —
/// is direction-independent, and the two halves drifting apart is what makes
/// swipe-open and swipe-close feel different in the same pane.
///
/// Stands in for the PageView's leading overscroll wherever that can't report
/// "one more step back": inside the open drawer, which covers the PageView
/// entirely, and over the agent page, whose horizontal scrollables absorb the
/// drag while they still have room. On a touch tablet it also opens and closes
/// both docked panes ([WorkspaceShellState._buildTabletTouch]) — fling from
/// anywhere over the pane, not just from an edge.
///
/// Velocity-gated rather than distance-gated: both hosts are full of vertical
/// lists a slow horizontal drag more likely belongs to, so a deliberate flick is
/// the only unambiguous signal.
///
/// Watches raw pointers instead of using a `GestureDetector` so it never enters
/// the gesture arena — a descendant recognizer wins that arena outright, and the
/// hosts here have drags of their own that must keep working: the open drawer's
/// swipe-to-close (a GestureDetector consumed the leftward drag too, stranding
/// the drawer open) and the agent page's terminal and PageView. Observing raw
/// pointers takes nothing from them. It also means two of these can be nested
/// over the same child, one per direction, without either stealing from the
/// other.
class _HorizontalFlingDetector extends StatefulWidget {
  const _HorizontalFlingDetector({
    required this.towards,
    required this.onFling,
    required this.child,
  }) : assert(
         towards == AxisDirection.left || towards == AxisDirection.right,
         'horizontal only',
       );

  final AxisDirection towards;
  final VoidCallback onFling;
  final Widget child;

  @override
  State<_HorizontalFlingDetector> createState() =>
      _HorizontalFlingDetectorState();
}

class _HorizontalFlingDetectorState extends State<_HorizontalFlingDetector> {
  static const double _minFlingVelocity = 700.0;

  /// Guards against a fast vertical scroll with a little sideways drift.
  static const double _minDistance = 40.0;

  VelocityTracker? _tracker;
  Offset _origin = Offset.zero;
  Offset _latest = Offset.zero;

  /// +1 rightward, -1 leftward — folds the direction into the two comparisons
  /// that actually depend on it, so nothing else has to branch.
  double get _sign => widget.towards == AxisDirection.right ? 1.0 : -1.0;

  void _onDown(PointerDownEvent event) {
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _origin = _latest = event.position;
  }

  void _onMove(PointerMoveEvent event) {
    _tracker?.addPosition(event.timeStamp, event.position);
    _latest = event.position;
  }

  void _onUp(PointerUpEvent event) {
    final tracker = _tracker;
    _tracker = null;
    if (tracker == null) return;
    final travel = _latest - _origin;
    if (travel.dx * _sign < _minDistance) return;
    if (travel.dx.abs() <= travel.dy.abs()) return;
    if (tracker.getVelocity().pixelsPerSecond.dx * _sign > _minFlingVelocity) {
      widget.onFling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: (_) => _tracker = null,
      child: widget.child,
    );
  }
}

/// Boot-log style status panel rendered while the workspace is coming up.
/// Each phase is one line with a leading glyph (`▸` running, `✓` done, `×`
/// failed); the running phase pulses in the accent. When `agent link` flips to
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
      palette.iconMuted,
      palette.textMuted,
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
          // LICENSE_API_URL) and a malformed one land here alongside
          // LICENSE_REVOKED. So the copy has to be true for every cause while
          // still naming the one action that fixes the common ones.
          tip:
              'The relay rejected this device\'s access token — it was '
              'revoked, it no longer matches your plan, or this build is '
              'pointed at a different server. Check you are signed in on the '
              'right account, then sign out and back in to re-provision this '
              'device and Retry.',
          retryLabel: 'retry',
        ),
        BlockReason.licenseExpired => (
          // LICENSE_EXPIRED is the relay's verdict for "no active plan", which
          // an account that never subscribed hits too — so no "renew your
          // subscription" framing.
          headline: 'this account can\'t reach machines remotely',
          tip:
              'The relay declined this connection\'s access token. Sign in '
              'again on this device to mint a fresh one, or check that your '
              'plan includes remote access, then Retry.',
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
    // A bridge that answered and refused the verb. NOT_ALLOWED is the blanket
    // refusal while the machine's remote-access switch is off — only that
    // machine can fix it, so name where the switch lives instead of echoing
    // the bridge's "mobile access is disabled" vocabulary.
    if (e is RpcException && e.code == 'NOT_ALLOWED') {
      return (
        headline: 'remote access is off on this machine',
        tip:
            'The machine is reachable, but remote access is switched off '
            'there. Turn it on in Antgrid on that computer — the Remote chip '
            'in the title bar — then Retry.',
        retryLabel: 'retry',
      );
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
