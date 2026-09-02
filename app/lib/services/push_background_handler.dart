import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show openPushBlob;
import 'package:push/push.dart';

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
typedef DecodedPush = ({
  String title,
  String body,
  String? kind,
  String? projectId,
  String? machineUuid,
  String? terminalId,
  String? sourceMessageId,
});

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
    return (
      title: (m['title'] as String?) ?? 'Agent',
      body: (m['body'] as String?) ?? '',
      kind: m['kind'] as String?,
      projectId: _presentOrNull(m['projectId']),
      machineUuid: _presentOrNull(m['machineUuid']),
      terminalId: _presentOrNull(m['terminalId']),
      sourceMessageId: _presentOrNull(m['sourceMessageId']),
    );
  } catch (_) {
    return null;
  }
}

/// The value of a routing field that actually names something, or null.
///
/// Type-tests rather than casts, because a throw anywhere in [decodePush]'s
/// `try` drops the WHOLE notification: a newer bridge sending one id in an
/// unexpected shape must cost that id, never the alert. Blank collapses to
/// absent exactly as `_named` does in `notification_route.dart` — whitespace
/// included, since the route this feeds is re-tested by that same predicate and
/// an id only one of them accepts is an id that survives to address nothing.
String? _presentOrNull(Object? value) =>
    (value is String && value.trim().isNotEmpty) ? value : null;

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
    final notifications = LocalNotificationService();
    await notifications.init();
    // The FCM message is data-only (`relay/src/push/fcm.ts`), so on Android this
    // is the ONLY thing that renders a background push — every one of them is
    // tappable-to-route or none is. Null, never an encoded empty route: on
    // Windows a payload is what classifies a body tap as
    // `selectedNotificationAction`, so an empty one buys a tap that resolves to
    // nothing in place of the plain launch.
    final route = routeOfPush(decoded);
    await notifications.show(
      title: decoded.title,
      body: decoded.body,
      payload: route == null ? null : encodeNotificationRoute(route),
    );
  } catch (e) {
    AbLog.error(
      'PushBackgroundHandler',
      'pushBackgroundHandler failed',
      fields: {'error': '$e'},
    );
  }
}
