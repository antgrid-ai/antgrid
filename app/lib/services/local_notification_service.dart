import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../util/ab_log.dart';

/// Thin wrapper over flutter_local_notifications. Used only for FOREGROUND
/// OS notifications when the app is backgrounded; the caller decides when to
/// invoke based on AppLifecycleState. Degrades silently if unavailable.
class LocalNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Monotonic, wrapping notification id. A wall-clock id (seconds) collides
  /// for notifications fired within the same second — on Android/iOS a
  /// duplicate id replaces the prior notification, silently dropping it. A
  /// per-instance counter (masked to a positive 31-bit int for the Android
  /// `int` id) gives each show() a distinct id.
  int _nextId = 0;

  Future<void> init() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
        windows: WindowsInitializationSettings(
          appName: 'Antgrid',
          appUserModelId: 'com.antgrid.app',
          guid: 'd49b0314-ee7a-4626-bf79-97cdb8a991ab',
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      // `initialize` returns an explicit `false` when the platform plugin
      // failed to register (e.g. the Windows AUMID / COM activation server
      // couldn't be set up) — honor that. But its `bool?` is platform-specific
      // (Darwin returns permission state; `null` when the impl isn't resolved,
      // on web, or under test bindings), so a `null` stays OPTIMISTIC: leave
      // `_ready` true and let `show` attempt delivery, matching the prior
      // always-ready behavior. Only a definitive `false` disables us.
      final ok = await _plugin.initialize(settings: settings);
      _ready = ok ?? true;
      if (!_ready) {
        AbLog.warn(
          'LocalNotificationService',
          'plugin.initialize returned false — OS notifications unavailable '
              'on this platform/build.',
        );
      }
    } catch (e) {
      AbLog.error(
        'LocalNotificationService',
        'init failed',
        fields: {'error': '$e'},
      );
    }
  }

  /// Best-effort OS notification. No-ops if the plugin failed to initialize
  /// (`_ready == false`); logs and swallows any platform error so a delivery
  /// failure never breaks the caller. Callers fire-and-forget.
  ///
  /// Carries no `payload:`/`actions:` and [init] registers no response
  /// callback, because a tapped action here has nothing to deliver and nowhere
  /// to deliver it: `bridge/src/push/push-dispatcher.ts` seals only
  /// `{title, body, kind, projectId, sourceMessageId}`, so an escalation's
  /// quick choices never reach this layer; and an answer must be sealed on a
  /// live E2E session (`HandlerService.reply` → `ProjectSession.send`), which
  /// a background/headless isolate does not have and no offline queue holds.
  /// On iOS the escalation notification is not ours at all — the NSE in
  /// `ios/NotificationService` renders the APNs alert, and the forked `push`
  /// plugin never forwards `response.actionIdentifier`.
  ///
  /// TODO(handler): quick-choice notification actions (spec §4.6) need, in
  /// order: `choices` sealed into the push payload and carried through
  /// `DecodedPush`; a pending-answer store flushed once `handler:status`
  /// replays the still-unanswered escalation; then `showsUserInterface: true`
  /// actions here so the tap resumes the app instead of a headless isolate.
  Future<void> show({required String title, required String body}) async {
    if (!_ready) return;
    final id = _nextId;
    _nextId = (_nextId + 1) & 0x7fffffff;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'agent_notifications',
            'Agent notifications',
            importance: Importance.high,
            priority: Priority.high,
            // Bodies carry agent output, which reaches the shade and possibly a
            // lock screen. Deliberately no in-app toggle: Android already owns
            // this control, so users who set "hide sensitive content" get OS
            // redaction here for free, and a second in-app switch would be a
            // worse duplicate of a setting they already have.
            visibility: NotificationVisibility.private,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      AbLog.error(
        'LocalNotificationService',
        'show failed',
        fields: {'error': '$e'},
      );
    }
  }
}
