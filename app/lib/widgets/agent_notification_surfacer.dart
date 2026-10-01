import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:push/push.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_toast.dart';
import '../models/ab_message.dart';
import '../models/handler_state.dart' show HandlerEscalation;
import '../navigation/notification_route.dart';
import '../project/project_session_registry.dart'
    show projectSessionProvider;
import '../providers/demo_mode.dart';
import '../providers/device_provisioning.dart' show localDeviceUuidProvider;
import '../providers/notification_route_apply.dart';
import '../providers/providers.dart';
import '../providers/recent_sessions.dart' show recentSessionsProvider;
import '../providers/sessions.dart';
import '../providers/surfaced_notifications.dart';
import '../providers/ui_attention_providers.dart';
import '../services/local_notification_service.dart';
import '../services/push_background_handler.dart'
    show decodePush, pushDataOf, pushDedupKey, routeOfPush;
import '../services/push_identity.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import '../utils/notification_routing.dart';
import 'handler/handler_why.dart' show handlerFallbackQuestion;

/// The title an escalation is surfaced under — the in-app toast and the OS
/// notification this app raises for itself.
///
/// HAND-MIRRORED in `composePush`'s `handler:escalation` branch
/// (`bridge/src/push/compose.ts`), which titles the SAME escalation for a phone
/// that is asleep or detached while this titles it for an attached app. Nothing
/// in CI couples them, so a string changed on one side alone describes one
/// event two different ways depending only on whether the device was awake —
/// which is why `handler_escalation_title_test.dart` reads the bridge's own
/// literals back out of that file. A shared golden fixture the bridge test
/// writes and the Dart test reads is the real fix and is not built here; until
/// it is, these three strings live in four places.
///
/// Top-level so the branch can be pinned against literal escalations without
/// pumping a widget.
@visibleForTesting
String handlerEscalationTitle(HandlerEscalation esc) {
  if (esc.urgency == 'high') return 'Handler — urgent';
  // A question Handler raised on a pass that had already replied to the agent:
  // the work went on, so the word must not be the one that means the session
  // stopped. Safe to read straight off the row here because every escalation
  // reaching this point has been through `HandlerService`'s capability gate —
  // an ask a bridge cannot be told the answer to arrives with `nonBlocking`
  // already cleared, so the app never offers a word it cannot honour.
  //
  // The split is also the whole of what reaches a locked phone: the push
  // payload carries no channel, priority or interruption level (see
  // `composePush`), so both titles buzz and light the screen identically.
  // Everything else that separates a question from a stop is visible only once
  // the user has been interrupted and has opened the Handler tab.
  return esc.nonBlocking ? 'Handler has a question' : 'Handler needs you';
}

/// Surfaces what agents and Handler raise for the user's attention, from every
/// warm project: an in-app toast while the app is in front, an OS notification
/// while it is not.
///
/// Wraps the app's root screen (`AppShell`, `DemoHome`) rather than mounting in
/// the workspace, which unmounts behind the New Session canvas: the agent
/// notification sources are event streams with no replay, so one that lands
/// while nothing listens is gone. Also the app's lifecycle observer, since the
/// toast-or-OS choice needs it on every screen, and [appLifecycleStateProvider]
/// mirrors it for everything else.
class AgentNotificationSurfacer extends ConsumerStatefulWidget {
  const AgentNotificationSurfacer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AgentNotificationSurfacer> createState() =>
      _AgentNotificationSurfacerState();
}

class _AgentNotificationSurfacerState
    extends ConsumerState<AgentNotificationSurfacer>
    with WidgetsBindingObserver {
  /// OS-level notifications, used only while the app is backgrounded. Self
  /// degrading: `init`/`show` swallow platform errors.
  final LocalNotificationService _osNotifications = LocalNotificationService();
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// Record [id] as surfaced; false if it already was. See
  /// [SurfacedNotificationIds].
  bool _markNotified(String id) =>
      ref.read(surfacedNotificationIdsProvider).mark(id);

  /// `push` hands back an unsubscribe callback rather than a StreamSubscription.
  VoidCallback? _unsubscribeForegroundPush;

  late final void Function() _stopTerminalNotifications;
  late final void Function() _stopAgentPushNotifications;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Surface agent terminal notifications: in-app toast while foreground,
    // OS notification while backgrounded (gated in _onNotification).
    _stopTerminalNotifications = listenToEvents(
      ref,
      terminalNotificationsProvider,
      (scoped) => _onNotification(scoped.message, scoped.entryId),
    );
    _stopAgentPushNotifications = listenToEvents(
      ref,
      agentPushNotificationsProvider,
      (scoped) {
        final msg = scoped.message;
        // Shared dedup key with the FCM path: the bridge seals
        // `sourceMessageId === msg.id` for agent notifications, so this id
        // guards both surfaces — a connected-but-backgrounded phone that gets
        // the same event live AND via push surfaces it only once (matches the
        // handler-escalation path).
        if (!_markNotified(msg.id)) return; // once/id
        _onAgentNotificationPush(msg, scoped.entryId);
      },
    );
    // The demo has no agent that can notify anyone, and both calls below have a
    // visible cost on iOS: `DarwinInitializationSettings` defaults to
    // requesting alert permission, so `init()` raises the OS prompt — asked, in
    // the demo's case, on behalf of nothing. A reviewer meeting an unexplained
    // permission dialog inside a sample project is exactly the reading we are
    // trying not to invite.
    final demo = ref.read(demoModeProvider);
    // Fire-and-forget: async + self-degrading.
    if (!demo) _osNotifications.init();
    if (!demo &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
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
          // The only caller whose route is built from the wire rather than
          // from a drawer entry: a push arrives from a machine this install has
          // to name for itself, so [routeOfPush] addresses it by machine +
          // project (or by session id) and answers null for a payload sealed by
          // a bridge that carried neither — a projectId alone is unroutable by
          // design, since `computeProjectId` hashes the folder path and can
          // name the wrong machine with confidence.
          _onAgentNotification(
            title: decoded.title,
            body: decoded.body,
            route: routeOfPush(decoded),
          );
        } catch (e) {
          // Async listener: an uncaught throw here is an unhandled rejection.
          AbLog.error(
            'AgentNotificationSurfacer',
            'foreground push failed',
            fields: {'error': '$e'},
          );
        }
      });
    }
    ref.listenManual<AsyncValue<ProjectScoped<HandlerEscalation>>>(
      handlerEscalationsProvider,
      (prev, next) {
        final scoped = next.value;
        if (scoped == null) return;
        final esc = scoped.message;
        // Shared dedup key with the FCM path: the bridge seals
        // `sourceMessageId === escalationId` for handler pushes, so this same
        // id guards both surfaces and a single escalation is surfaced only once
        // whether it arrives live or via push. Keying on the escalationId alone
        // — not the project-scoped record — is also what keeps the provider's
        // per-rebuild re-seed idempotent.
        if (!_markNotified(esc.escalationId)) return; // once/id
        _onHandlerEscalation(esc, scoped.entryId);
      },
    );
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
    _stopTerminalNotifications();
    _stopAgentPushNotifications();
    super.dispose();
  }

  void _onNotification(TerminalNotificationMessage msg, String entryId) {
    // A session terminal's id IS the session id (service PTYs use their own,
    // which never matches an active session).
    if (_isViewingSession(msg.terminalId)) return;
    final body = (msg.body != null && msg.body!.isNotEmpty)
        ? msg.body!
        : 'Notification';
    final title = (msg.title != null && msg.title!.isNotEmpty)
        ? msg.title!
        : 'Agent';
    _onAgentNotification(
      title: title,
      body: body,
      route: NotificationRoute(
        registrationId: entryId,
        terminalId: msg.terminalId,
        kind: 'agent',
        sourceMessageId: msg.id,
      ),
    );
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

  /// Whether [entryId]'s Handler holds an armed slot for [sessionId] — the
  /// app-side reading of the bridge's `isHandlerArmed`, which is what
  /// `handler:status` lists. Read off the notification's OWN project session
  /// rather than the focused one: this surfacer spans every warm project (see
  /// [agentPushNotificationsProvider]), and the focused project's armed set
  /// cannot answer for a background one.
  bool _handlerArmed(String entryId, String? sessionId) {
    if (sessionId == null) return false;
    final session = ref.read(projectSessionProvider(entryId)).value;
    return session?.handlerService.currentState.sessions[sessionId] != null;
  }

  void _onAgentNotificationPush(NotificationPushMessage msg, String entryId) {
    if (_isViewingSession(msg.sessionId)) return;
    // The Handler's escalation for this same block is surfaced by
    // [_onHandlerEscalation] a beat away, carrying the same sentence and the id
    // that answers it. Two buzzes for one question is what the bridge's push
    // lane already refuses; this is the in-band half of that rule.
    if (handlerAnnouncesAgentNotification(
      notificationType: msg.notificationType,
      sessionId: msg.sessionId,
      handlerArmed: _handlerArmed(entryId, msg.sessionId),
    )) {
      return;
    }
    const labels = {
      'permission_request': 'Permission needed',
      'awaiting_input': 'Needs your input',
      'question': 'Agent asks',
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
    _onAgentNotification(
      title: title,
      body: body,
      route: NotificationRoute(
        registrationId: entryId,
        terminalId: msg.sessionId,
        kind: 'agent',
        sourceMessageId: msg.id,
      ),
    );
  }

  void _onHandlerEscalation(HandlerEscalation esc, String entryId) {
    // Handler escalations name their session in `terminalId`.
    if (_isViewingSession(esc.terminalId)) return;
    // Route through the shared surfacer (foreground toast / background OS
    // notification), identical to the agent-notification paths, so an
    // escalation from ANY warm project is surfaced — not just the focused one.
    final title = handlerEscalationTitle(esc);
    final body = esc.question.isNotEmpty
        ? esc.question
        : handlerFallbackQuestion;
    _onAgentNotification(
      title: title,
      body: body,
      route: NotificationRoute(
        registrationId: entryId,
        terminalId: esc.terminalId,
        kind: 'handler',
        sourceMessageId: esc.escalationId,
      ),
    );
  }

  /// [route] is what tapping this notification should open, or null when the
  /// producer could name nothing addressable — which is the foreground-push
  /// path against a bridge that sealed no machine, since a projectId alone is
  /// not a machine (`computeProjectId` hashes the folder path) and must never
  /// be used to pick an entry.
  void _onAgentNotification({
    required String title,
    required String body,
    NotificationRoute? route,
  }) {
    if (shouldShowInAppToast(_lifecycle)) {
      // Gated on the route actually RESOLVING, not on one having been built: an
      // offer that opens nothing is worse than none, and the two conditions part
      // company on any id that names no place (a blank one among them). Resolved
      // synchronously against what is already loaded, which is exact for the
      // in-app producers — they carry a registrationId, and neither that rule
      // nor the terminalId one consults the device uuid.
      //
      // Inside this branch, because it gates the CHIP and nothing else: the OS
      // notification below carries `route` verbatim and never reads this
      // answer, so resolving it there would scan the whole cached-session
      // universe — on the backgrounded path, which is the common one — to
      // discard the result. A chip lives 8s, so "resolves now" is as good as
      // "resolves when pressed", while an OS notification sits in the shade
      // indefinitely and the applier re-resolves at tap time against freshly
      // awaited state; gating the payload here would bake a cold-cache miss
      // into a notification that would have resolved fine an hour later.
      final destination = route == null
          ? null
          : resolveNotificationRoute(
              route,
              known: ref.read(recentSessionsProvider),
              localDeviceUuid: ref.read(localDeviceUuidProvider).value,
            );
      if (destination == null) {
        showAbToastOverlay(
          context,
          toast: AbToast(icon: AbIcons.bell, title: title, description: body),
        );
        return;
      }
      // Both captured before the tap: the toast can outlive this widget (the
      // root screen is replaced around sign-in and demo mode), and `context`
      // read through the State getter at tap time would throw on the defunct
      // element; the captured element answers `mounted` false instead, which
      // is what the applier tests.
      final container = ref.container;
      final toastContext = context;
      showAbToastOverlay(
        context,
        toast: AbToast(
          icon: AbIcons.bell,
          title: title,
          description: body,
          actionLabel: 'Open',
          onAction: () => detached(
            'AgentNotificationSurfacer',
            'notification route failed',
            () => applyNotificationRoute(toastContext, container, route!),
          ),
        ),
        // 8s, not the 4s default: give the user a real window to notice and
        // tap this before it goes.
        duration: const Duration(seconds: 8),
      );
      return;
    }
    // App is not focused (occluded or minimized): only the OS notification can
    // surface above the foreground app — an in-app toast would be painted
    // behind it. Fire-and-forget; `show` logs delivery failures internally.
    //
    // The payload is the whole tap: `main` decodes it back into this same route
    // and applies it. Carried whenever the producer named one — `route`, not the
    // chip's `tappable` — because resolution is redone at tap time and this
    // notification outlives the state it would have been judged against here.
    // Null rather than an empty route when there is nothing to name at all: on
    // Windows the payload is what makes a body tap arrive as
    // `selectedNotificationAction`, and an empty one lands nowhere.
    _osNotifications.show(
      title: title,
      body: body,
      payload: route == null ? null : encodeNotificationRoute(route),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
