import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show openPushBlob;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

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

/// Stable dedup key for a decoded push, given the FCM envelope's own id as a
/// fallback. Prefers the bridge's `sourceMessageId` (stable across delivery
/// surfaces — foreground onMessage vs background). When absent, falls back to
/// the FCM messageId so two id-less pushes don't collide on a shared key; if
/// even that is missing, returns null so the caller shows the push rather than
/// silently deduping it away.
String? pushDedupKey(DecodedPush decoded, {String? fcmMessageId}) {
  final src = decoded.sourceMessageId;
  if (src != null && src.isNotEmpty) return src;
  if (fcmMessageId != null && fcmMessageId.isNotEmpty) return fcmMessageId;
  return null;
}

/// Pure decrypt+parse of an FCM data payload. Testable without Firebase.
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

/// Background isolate entrypoint, registered via
/// `FirebaseMessaging.onBackgroundMessage`. Runs in a separate Dart isolate
/// when the app is backgrounded or killed (not force-stopped), so it must
/// initialize Firebase itself — plugin state from the foreground isolate is
/// not visible here.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  // Runs in its own isolate: an uncaught throw (Firebase.initializeApp on an
  // unconfigured build, secure-storage/decrypt failure) would crash it silently
  // rather than degrade. Swallow so a bad push just goes unshown.
  try {
    await Firebase.initializeApp();
    final decoded = await decodePush(
      message.data.cast<String, String>(),
      pushIdentity: PushIdentity.secure(),
    );
    if (decoded == null) return;
    final notifications = LocalNotificationService();
    await notifications.init();
    await notifications.show(title: decoded.title, body: decoded.body);
  } catch (e) {
    debugPrint('pushBackgroundHandler failed: $e');
  }
}
