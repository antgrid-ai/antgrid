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

/// HAND-MIRRORED in `composePush`'s `handler:escalation` branch
/// (`bridge/src/push/compose.ts`); CI does not couple the two.
@visibleForTesting
String handlerEscalationTitle(HandlerEscalation esc) {
  if (esc.urgency == 'high') return 'Handler — urgent';
  // Raised after Handler already replied, so the work went on: the title
  // must not say the session stopped.
  return esc.nonBlocking ? 'Handler has a question' : 'Handler needs you';
}

/// Surfaces agent and Handler attention requests from every warm project; wraps
/// the root screen because the event streams have no replay.
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
  /// Seeded from the binding: a rebuild while unfocused with a stale `resumed`
  /// would paint an unseen toast.
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

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
        // Dedup key shared with the FCM path (`sourceMessageId === msg.id`):
        // an event arriving live and via push surfaces once.
        if (!_markNotified(msg.id)) return; // once/id
        _onAgentNotificationPush(msg, scoped.entryId);
      },
    );
    // The demo has no agent that can notify; `init()` would raise the iOS
    // permission prompt for nothing.
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
          // Dedup key shared with the live handler stream; null means show it.
          final key = pushDedupKey(decoded);
          if (key != null && !_markNotified(key)) {
            return; // already surfaced (this surface or the live stream)
          }
          // A projectId alone is unroutable (it hashes the folder path), so
          // [routeOfPush] needs machine + project or a session id.
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
        // Dedup key shared with the FCM path; keying on escalationId alone
        // keeps the provider's per-rebuild re-seed idempotent.
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

  /// Whether [entryId]'s Handler holds an armed slot for [sessionId]. Reads the
  /// notification's own project: this spans every warm project.
  bool _handlerArmed(String entryId, String? sessionId) {
    if (sessionId == null) return false;
    final session = ref.read(projectSessionProvider(entryId)).value;
    return session?.handlerService.currentState.sessions[sessionId] != null;
  }

  void _onAgentNotificationPush(NotificationPushMessage msg, String entryId) {
    if (_isViewingSession(msg.sessionId)) return;
    // An armed slot's question is surfaced by [_onHandlerEscalation]; dropping
    // the agent's copy avoids two buzzes for one question.
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
    // Keep in lockstep with bridge/src/push/compose.ts: both must agree.
    // body deliberately does not fall back to sessionTitle, or title == body.
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
    // Route through the shared surfacer so an escalation from ANY warm project
    // is surfaced, not just the focused one.
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

  /// [route] is what tapping opens, or null when the producer named nothing
  /// addressable; a projectId alone must never pick an entry.
  void _onAgentNotification({
    required String title,
    required String body,
    NotificationRoute? route,
  }) {
    if (shouldShowInAppToast(_lifecycle)) {
      // Gate the chip on the route RESOLVING: an offer that opens nothing is
      // worse than none. The OS payload is re-resolved at tap time instead.
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
      // Captured before the tap: the toast can outlive this widget, and the
      // State's `context` getter would throw then; the element says unmounted.
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
    // Unfocused: only an OS notification can surface above the app. Its payload
    // is the whole tap, carried whenever `route` exists.
    _osNotifications.show(
      title: title,
      body: body,
      payload: route == null ? null : encodeNotificationRoute(route),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
