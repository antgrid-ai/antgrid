import 'dart:convert' show utf8;
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../util/ab_log.dart';

/// The notification id for a tagged notification: 32-bit FNV-1a over the
/// tag's UTF-8 bytes, masked to the positive 31 bits Android's `int` id takes.
///
/// Not `String.hashCode`, which is free to differ between isolates and runs —
/// and the headless push isolate that posts a notification is never the one
/// that next posts to the same tag, so an unstable id would add where it was
/// meant to replace.
int notificationIdForTag(String tag) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(tag)) {
    hash ^= byte;
    // The FNV prime 0x01000193 as 2^24 + 0x193, keeping every intermediate
    // under 2^53: a direct multiply loses its low bits to a web double.
    hash = (hash * 0x193 + (hash & 0xff) * 0x1000000) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Prefixes a group's summary tag, so the summary never shares a (tag, id) with
/// a project-level child, whose tag is the bare group key.
const _summaryTagPrefix = 'summary|';

/// FOREGROUND OS notifications while backgrounded. One instance per isolate:
/// the demo skips [init], so per-instance readiness would no-op [show] there.
class LocalNotificationService {
  LocalNotificationService._();

  static final LocalNotificationService _instance =
      LocalNotificationService._();

  factory LocalNotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Where a tapped notification is delivered. Assigned once from `main`,
  /// before any shell mounts — a warm tap can arrive before the first frame.
  ///
  /// Reached through the stable [_dispatchTap] trampoline rather than handed to
  /// the plugin directly, so assigning it after [init] still takes effect.
  void Function(NotificationResponse)? onTap;

  /// Monotonic, wrapping notification id, seeded per isolate rather than from
  /// zero. A wall-clock id (seconds) collides for notifications fired within
  /// the same second, so this is a counter (masked to a positive 31-bit int for
  /// the Android `int` id) — but the headless push isolate and the main engine
  /// each run their own, and from a shared origin they mint the same ids. Now
  /// that a payload rides along, such a collision is no longer a duplicate
  /// harmlessly replacing its twin (`FLAG_UPDATE_CURRENT`) but a tap carrying
  /// the WRONG route; a random base makes the two ranges all but certain to
  /// differ.
  int _nextId = Random().nextInt(1 << 20) << 10;

  /// Stable target for `onDidReceiveNotificationResponse`, so the callback the
  /// plugin holds is never the one that has to be replaced.
  ///
  /// Required rather than tidy: `FlutterLocalNotificationsWindows.initialize`
  /// early-returns when it is already ready — BEFORE assigning its user
  /// callback — and [init] runs on every shell mount, so a closure captured at
  /// any later call would never be installed.
  void _dispatchTap(NotificationResponse response) => onTap?.call(response);

  Future<void> init() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_antgrid'),
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
      //
      // No `onDidReceiveBackgroundNotificationResponse`: that entry point is
      // for action buttons answered without resuming the app, and there are
      // none here — every tap means "show me this", which needs the app.
      final ok = await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _dispatchTap,
      );
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
  /// [payload] is what a tap hands back through [onTap] — the encoded route the
  /// caller wants opened (`navigation/notification_route.dart`), and the only
  /// channel one rides on: nothing else about the notification survives to the
  /// tap. Pass null, not an empty route, when there is nothing to open — on
  /// Windows the payload is what makes a BODY tap arrive as
  /// `selectedNotificationAction`, so an empty one turns a plain launch into a
  /// tap that resolves to nothing.
  ///
  /// Never the sealed push blob itself: on Windows the payload becomes the
  /// toast XML's `launch` attribute, and an oversized document makes `show`
  /// throw into the swallowed log below — after which Windows notifications
  /// silently stop appearing.
  ///
  /// Still no `actions:`, because an escalation's quick choices have nowhere to
  /// go: they are not in the sealed payload, and an answer must be sealed on a
  /// live peer session (`HandlerService.reply` → `ProjectSession.send`), which a
  /// background/headless isolate does not have and no offline queue holds. On
  /// iOS the escalation notification is not ours at all — the NSE in
  /// `ios/NotificationService` renders the APNs alert, and the forked `push`
  /// plugin never forwards `response.actionIdentifier`.
  ///
  /// TODO(handler): quick-choice notification actions need, in order:
  /// `choices` sealed into the push payload and carried through `DecodedPush`;
  /// a pending-answer store flushed once `handler:status` replays the
  /// still-unanswered escalation; then `showsUserInterface: true` actions here
  /// so the tap resumes the app instead of a headless isolate.
  ///
  /// [tag] makes the notification REPLACE whatever this app last posted under
  /// the same tag, so a thread shows only its latest state: the id becomes
  /// [notificationIdForTag] instead of the next counter value, and Android
  /// keys a notification by (tag, id). Hashed ids cannot displace counter ones
  /// there, because a counter notification carries no tag.
  ///
  /// [groupKey] bundles notifications into one expandable group, and on
  /// Android also posts the group's summary, without which the OS will not
  /// bundle them. The summary is silent — the child that prompted it already
  /// alerted — and carries no payload, since it stands for every thread in the
  /// group rather than one route. Elsewhere there is no summary to post: a
  /// second visible notification is all it would be.
  Future<void> show({
    required String title,
    required String body,
    String? payload,
    String? tag,
    String? groupKey,
  }) async {
    if (!_ready) return;
    final int id;
    if (tag != null) {
      id = notificationIdForTag(tag);
    } else {
      id = _nextId;
      _nextId = (_nextId + 1) & 0x7fffffff;
    }
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: _details(tag: tag, groupKey: groupKey),
      );
      if (groupKey != null && defaultTargetPlatform == TargetPlatform.android) {
        final summaryTag = '$_summaryTagPrefix$groupKey';
        await _plugin.show(
          id: notificationIdForTag(summaryTag),
          title: title,
          body: body,
          notificationDetails: _details(
            tag: summaryTag,
            groupKey: groupKey,
            summary: true,
          ),
        );
      }
    } catch (e) {
      AbLog.error(
        'LocalNotificationService',
        'show failed',
        fields: {'error': '$e'},
      );
    }
  }

  static NotificationDetails _details({
    String? tag,
    String? groupKey,
    bool summary = false,
  }) => NotificationDetails(
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
      tag: tag,
      groupKey: groupKey,
      setAsGroupSummary: summary,
      onlyAlertOnce: summary,
      groupAlertBehavior: summary
          ? GroupAlertBehavior.children
          : GroupAlertBehavior.all,
    ),
    iOS: const DarwinNotificationDetails(),
    macOS: const DarwinNotificationDetails(),
    linux: const LinuxNotificationDetails(),
    windows: const WindowsNotificationDetails(),
  );
}
