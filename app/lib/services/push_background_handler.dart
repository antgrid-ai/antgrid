import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show openPushBlob;
import 'package:push/push.dart';

import '../util/ab_log.dart';
import 'local_notification_service.dart';
import 'push_identity.dart';

/// Decoded push payload. `kind` distinguishes handler-escalation urgency from
/// ordinary agent notifications; `projectId` attributes the push to a project.
/// Both are sealed in by the bridge (`bridge/src/push/compose.ts`).
///
/// `sourceMessageId` is nullable: the bridge does not always stamp one, and two
/// distinct pushes that both lack it MUST NOT collapse to the same dedup key
/// (see [pushDedupKey]).
typedef DecodedPush = ({
  String title,
  String body,
  String? kind,
  String? projectId,
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
    final src = m['sourceMessageId'] as String?;
    return (
      title: (m['title'] as String?) ?? 'Agent',
      body: (m['body'] as String?) ?? '',
      kind: m['kind'] as String?,
      projectId: m['projectId'] as String?,
      // Preserve absence as null, not '' — an empty id must not dedup-collide.
      sourceMessageId: (src != null && src.isNotEmpty) ? src : null,
    );
  } catch (_) {
    return null;
  }
}

/// Narrow `push`'s pigeon-typed data payload to the plain map [decodePush]
/// takes. `push` types it `Map<String?, Object?>?` because that is pigeon's
/// lowest common denominator; the sealed-blob fields are always non-null
/// strings. Narrowing here keeps [decodePush] testable without the plugin.
Map<String, String> pushDataOf(RemoteMessage message) => <String, String>{
  for (final e in (message.data ?? const <String?, Object?>{}).entries)
    if (e.key != null && e.value is String) e.key!: e.value! as String,
};

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
    await notifications.show(title: decoded.title, body: decoded.body);
  } catch (e) {
    AbLog.error(
      'PushBackgroundHandler',
      'pushBackgroundHandler failed',
      fields: {'error': '$e'},
    );
  }
}
