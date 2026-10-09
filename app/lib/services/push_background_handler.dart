import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show openPushBlob;
import 'package:push/push.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import '../navigation/notification_route.dart';
import '../util/ab_log.dart';
import 'local_notification_service.dart';
import 'push_identity.dart';

/// Decoded push payload. `kind` distinguishes handler-escalation urgency from
/// ordinary agent notifications; the routing ids say what the push is about.
/// Split across two bridge files: `compose.ts` narrows the message union and so
/// is the only place `terminalId`, `sourceMessageId`, `kind` and the strings can
/// be read; `push-dispatcher.ts` stamps `projectId` and `machineUuid`, which the
/// message never carries.
///
/// `projectId` and `machineUuid` are nullable together: a bridge older than the
/// widened payload seals neither, and the pair is what [routeOfPush] addresses
/// a project by. Neither is guessable — `computeProjectId` hashes the folder
/// path with no machine input — so absence is unroutable, never inferred.
///
/// `terminalId` is nullable because `notification:push` carries an optional
/// `sessionId`: the hook producer often names no session, and such a push is
/// about the project alone.
///
/// `sourceMessageId` is nullable: the bridge does not always stamp one, and two
/// distinct pushes that both lack it MUST NOT collapse to the same dedup key
/// (see [pushDedupKey]).
///
/// Every one of them is absent-as-null, never `''`: an empty id still satisfies
/// a `!= null` test and would address a project nobody has.
///
/// `sentAt` is the bridge's wall clock when it sealed the push, null from a
/// bridge too old to stamp it or when the stamp is malformed (see
/// [isStalePush] for why null must never read as stale).
typedef DecodedPush = ({
  String title,
  String body,
  String? kind,
  String? projectId,
  String? machineUuid,
  String? terminalId,
  String? sourceMessageId,
  DateTime? sentAt,
});

/// How old a push may be and still be shown. A push reports agent state: worth
/// seeing after a night or a flight offline, but a device offline for days must
/// come back to nothing rather than a backlog of state that has moved on.
///
/// Keep in lockstep with `PUSH_TTL_SECONDS` in the relay, which tells FCM and
/// APNs to discard an undelivered push after the same interval; this is the
/// backstop for one the provider already handed over, or queued before that
/// TTL existed.
const kPushMaxAge = Duration(hours: 12);

/// Whether [decoded] is too old to show at [now].
///
/// Only a known, past `sentAt` can be stale. A missing one is an older bridge,
/// whose every push would otherwise vanish; a future one is the two machines'
/// clocks disagreeing, which says nothing about how long the push waited.
bool isStalePush(DecodedPush decoded, DateTime now) {
  final sentAt = decoded.sentAt;
  return sentAt != null && now.difference(sentAt) > kPushMaxAge;
}

/// How long after its `sentAt` a push may arrive and still ring. Later than
/// this, it waited in FCM while the device was offline: FCM sends ours at high
/// priority, so Doze does not hold one this long. It still updates its
/// session's notification, silently — a reconnect backlog is news to read, not
/// a run of alarms for events that are already minutes or hours old.
const kPushLateAfter = Duration(minutes: 5);

/// The shortest gap between two audible push alerts. A burst — a reconnect
/// backlog delivered on time by the clock, or one agent ending several turns in
/// a row — rings once and posts the rest silently. Android itself only softens
/// a burst, and only from 15 on (notification cooldown lowers the volume).
const kPushAlertGap = Duration(seconds: 30);

/// Whether [decoded], arriving at [now], should ring, given when the last push
/// alert rang.
///
/// A Handler escalation that arrives on time always rings: it is the one push
/// the user must answer, so a burst of routine pushes must not mute it. A late
/// one is as stale as any other. A [lastAlertAt] in the future means the device
/// clock moved back, which says nothing about a burst.
bool pushShouldAlert(DecodedPush decoded, DateTime now, DateTime? lastAlertAt) {
  final sentAt = decoded.sentAt;
  if (sentAt != null && now.difference(sentAt) > kPushLateAfter) return false;
  if (decoded.kind == 'handler' || lastAlertAt == null) return true;
  return now.isBefore(lastAlertAt) ||
      now.difference(lastAlertAt) >= kPushAlertGap;
}

final _lastAlertKey = scopedStorageKey('push.lastAlertAtMs');

/// Serialises [claimPushAlert] within an isolate: FCM delivers a backlog in a
/// rush, and two pushes that both read "no recent alert" before either wrote
/// would both ring.
Future<void> _alertClaims = Future<void>.value();

/// [pushShouldAlert] against the persisted time of the last alert, recording
/// [now] when this push rings.
///
/// Persisted rather than held in memory because each background push may run
/// in a fresh headless engine. A storage failure reads as no earlier alert —
/// ringing — since a muted alert is the worse failure.
Future<bool> claimPushAlert(DecodedPush decoded, DateTime now) {
  final claim = _alertClaims.then((_) async {
    final prefs = SharedPreferencesAsync(
      options: desktopSharedPreferencesOptions,
    );
    DateTime? lastAlertAt;
    try {
      final ms = await prefs.getInt(_lastAlertKey);
      if (ms != null) {
        lastAlertAt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      }
    } catch (_) {}
    final alert = pushShouldAlert(decoded, now, lastAlertAt);
    if (alert) {
      try {
        await prefs.setInt(_lastAlertKey, now.millisecondsSinceEpoch);
      } catch (_) {}
    }
    return alert;
  });
  _alertClaims = claim.then((_) {}, onError: (_) {});
  return claim;
}

/// Which OS notification a push occupies: [tag] names its thread, so a newer
/// push for the same session replaces the one already in the shade, and
/// [groupKey] bundles every thread of one project under a summary.
typedef NotificationSlot = ({String tag, String groupKey});

/// The [NotificationSlot] for [decoded], or null when it cannot be placed in
/// one and must stand alone.
///
/// Keyed by machine AND project for the reason [routeOfPush] is: the same repo
/// at the same path on two machines mints one projectId, so a projectId alone
/// would let one machine's push replace another's. A push without the pair gets
/// no slot rather than a guessed one, since a wrong slot silently erases an
/// unrelated alert.
///
/// A Handler escalation is a thread of its own, keyed by its escalation id: it
/// is the one alert the user must answer, and the session it names keeps
/// pushing after it, so sharing the session's tag would let a later "idle"
/// replace the question. Mirrors `pushCollapseKey` in the bridge's
/// `push-dispatcher.ts`, which keeps APNs from collapsing the two either.
NotificationSlot? notificationSlotOf(DecodedPush decoded) {
  final machineUuid = decoded.machineUuid;
  final projectId = decoded.projectId;
  if (machineUuid == null || projectId == null) return null;
  final groupKey = '$machineUuid|$projectId';
  final terminalId = decoded.terminalId;
  final thread = terminalId == null ? groupKey : '$groupKey|$terminalId';
  if (decoded.kind != 'handler') return (tag: thread, groupKey: groupKey);
  final escalationId = decoded.sourceMessageId;
  return (
    tag: escalationId == null
        ? '$thread|handler'
        : '$thread|handler|$escalationId',
    groupKey: groupKey,
  );
}

/// The bridge's `sentAt` (epoch milliseconds) as a time, or null for anything
/// that is not a plausible one. Non-positive counts as malformed: an epoch-zero
/// stamp would make every push from that bridge stale, and like the ids, a bad
/// field must cost that field rather than the alert.
DateTime? _sentAtOrNull(Object? raw) {
  // DateTime's own range; past it `fromMillisecondsSinceEpoch` throws.
  const maxMs = 8640000000000000;
  if (raw is! num || !raw.isFinite || raw <= 0 || raw > maxMs) return null;
  return DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true);
}

/// Stable dedup key for a decoded push. The bridge always stamps
/// `sourceMessageId` (`push-dispatcher.ts`), and it is stable across delivery
/// surfaces — foreground onMessage vs background. When absent, returns null so
/// the caller shows the push rather than silently deduping it away.
///
/// There is no envelope-level fallback: `push`'s RemoteMessage exposes only
/// `notification` and `data`, so neither FCM's messageId nor an APNs equivalent
/// is reachable from Dart.
String? pushDedupKey(DecodedPush decoded) {
  final src = decoded.sourceMessageId;
  if (src != null && src.isNotEmpty) return src;
  return null;
}

/// What tapping this push should open, or null when it names nothing this app
/// could address.
///
/// Null rather than a route with only a title: the payload rides in an OS
/// notification's launch slot, and a route that cannot resolve buys a chip the
/// user can only ever press to no effect. The structural test mirrors
/// [resolveNotificationRoute]'s own preconditions — a machine AND a project, or
/// a session id to look up — and deliberately not its data, which does not
/// exist yet in the isolate that seals the payload.
///
/// No `registrationId`: that is the in-app paths' pre-resolved id, and a push
/// arrives from a machine this install has to name for itself.
NotificationRoute? routeOfPush(DecodedPush decoded) {
  final machineUuid = decoded.machineUuid;
  final projectId = decoded.projectId;
  final terminalId = decoded.terminalId;
  final addressable =
      (machineUuid != null && projectId != null) || terminalId != null;
  if (!addressable) return null;
  return NotificationRoute(
    machineUuid: machineUuid,
    projectId: projectId,
    terminalId: terminalId,
    sourceMessageId: decoded.sourceMessageId,
    kind: decoded.kind,
  );
}

/// Pure decrypt+parse of a push data payload. Testable without the plugin.
Future<DecodedPush?> decodePush(
  Map<String, String> data, {
  required PushIdentity pushIdentity,
}) async {
  final epk = data['epk'];
  final box = data['box'];
  if (epk == null || box == null) return null;
  final kp = await pushIdentity.ensureKeypair();
  final json = await openPushBlob(
    epkB64: epk,
    boxB64: box,
    pushPrivSeed: kp.privSeed,
  );
  if (json == null) return null;
  try {
    final m = jsonDecode(json) as Map<String, dynamic>;
    // [namedOrNull], not a cast: a throw anywhere in this `try` drops the WHOLE
    // notification, so a newer bridge sending one id in an unexpected shape
    // must cost that id, never the alert. Shared with the route decoder rather
    // than restated, because the route this feeds is re-tested by that same
    // predicate — an id only one of them accepts is an id that survives
    // decoding to address nothing.
    return (
      // The strings go through it too, and that is the point of the rule above
      // rather than an extension of it: the cast these two used to be is the
      // only thing in this `try` that can throw on the payload's own content,
      // and a throw here costs the WHOLE alert instead of one field. Blank
      // collapses into the fallback for the same reason an id does —
      // `composePush` never sends an empty title, so one could only come from a
      // bridge that meant nothing by it, and a blank heading is not an
      // improvement on 'Agent'.
      title: namedOrNull(m['title']) ?? 'Agent',
      body: namedOrNull(m['body']) ?? '',
      kind: namedOrNull(m['kind']),
      projectId: namedOrNull(m['projectId']),
      machineUuid: namedOrNull(m['machineUuid']),
      terminalId: namedOrNull(m['terminalId']),
      sourceMessageId: namedOrNull(m['sourceMessageId']),
      sentAt: _sentAtOrNull(m['sentAt']),
    );
  } catch (_) {
    return null;
  }
}

/// Narrow a pigeon-typed data payload to the plain map [decodePush] takes.
/// `push` types it `Map<String?, Object?>?` because that is pigeon's lowest
/// common denominator; the sealed-blob fields are always non-null strings.
/// Narrowing here keeps [decodePush] testable without the plugin.
///
/// Takes the bare map, not a [RemoteMessage]: the notification-tap APIs hand
/// one directly and never build a message. On iOS the map they hand is the FULL
/// APNs userInfo, with `epk`/`box` at top level beside a nested `aps` — which
/// this drops as a non-String value, harmlessly.
Map<String, String> pushDataMap(Map<String?, Object?>? raw) => <String, String>{
  for (final e in (raw ?? const <String?, Object?>{}).entries)
    if (e.key != null && e.value is String) e.key!: e.value! as String,
};

/// [pushDataMap] over the data of a delivered message.
Map<String, String> pushDataOf(RemoteMessage message) =>
    pushDataMap(message.data);

/// Background message handler, registered via [Push.addOnBackgroundMessage]
/// from both `main` and `pushBackgroundMain`.
///
/// MUST NOT throw. `push` only invokes its `remoteMessageProcessingComplete`
/// callback when this future completes successfully
/// (PushHostHandlers.backgroundFlutterApplicationReady); on a rejection the
/// headless engine is never destroyed and the receiver stays pending until its
/// 30s goAsync budget expires.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  try {
    final decoded = await decodePush(
      pushDataOf(message),
      pushIdentity: PushIdentity.secure(),
    );
    if (decoded == null) return;
    final now = DateTime.now();
    if (isStalePush(decoded, now)) {
      // warn, and with the age: the age is measured across two machines'
      // clocks, so a phone running [kPushMaxAge] or more ahead of the bridge
      // drops EVERY push from it, and this line is the only trace of that.
      AbLog.warn(
        'PushBackgroundHandler',
        'dropped stale push',
        fields: {'ageSeconds': now.difference(decoded.sentAt!).inSeconds},
      );
      return;
    }
    final notifications = LocalNotificationService();
    await notifications.init();
    // The FCM message is data-only (`relay/src/push/fcm.ts`), so on Android this
    // is the ONLY thing that renders a background push — every one of them is
    // tappable-to-route or none is. Null, never an encoded empty route: on
    // Windows a payload is what classifies a body tap as
    // `selectedNotificationAction`, so an empty one buys a tap that resolves to
    // nothing in place of the plain launch.
    final route = routeOfPush(decoded);
    final slot = notificationSlotOf(decoded);
    await notifications.show(
      title: decoded.title,
      body: decoded.body,
      payload: route == null ? null : encodeNotificationRoute(route),
      tag: slot?.tag,
      groupKey: slot?.groupKey,
      silent: !await claimPushAlert(decoded, now),
    );
  } catch (e) {
    AbLog.error(
      'PushBackgroundHandler',
      'pushBackgroundHandler failed',
      fields: {'error': '$e'},
    );
  } finally {
    // The headless engine is destroyed once this returns, so the lines above
    // reach disk only if the log file is attached and drained first. No file
    // name here: AbLog keeps the one pushBackgroundMain named (app-push.log)
    // even for a retry, and in the main isolate a retry belongs on app.log.
    try {
      await AbLog.initLogDirectory();
      await AbLog.flush();
    } catch (_) {}
  }
}
