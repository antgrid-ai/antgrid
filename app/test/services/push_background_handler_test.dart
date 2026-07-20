import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/services/push_background_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'decodePush decrypts the FCM data payload to title/body/sourceMessageId',
    () async {
      // Build an in-memory push identity and seal a payload to its pubkey.
      final identity = PushIdentity.inMemory();
      final kp = await identity.ensureKeypair();

      final x = X25519();
      final recipientPub = SimplePublicKey(
        base64Decode(kp.pubkeyB64),
        type: KeyPairType.x25519,
      );
      final eph = await x.newKeyPair();
      final ephPub = await eph.extractPublicKey();
      final shared = await x.sharedSecretKey(
        keyPair: eph,
        remotePublicKey: recipientPub,
      );
      final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
      final key = await hkdf.deriveKey(
        secretKey: SecretKeyData(await shared.extractBytes()),
        nonce: ephPub.bytes,
        info: utf8.encode('antgrid-push-v1'),
      );
      final payload = jsonEncode({
        'title': 'Handler needs you',
        'body': 'Deploy?',
        'kind': 'handler',
        'sourceMessageId': 'e1',
      });
      final sb = await AesGcm.with256bits().encrypt(
        utf8.encode(payload),
        secretKey: key,
      );
      final box = base64Encode([
        ...sb.nonce,
        ...sb.cipherText,
        ...sb.mac.bytes,
      ]);

      final decoded = await decodePush({
        'epk': base64Encode(ephPub.bytes),
        'box': box,
      }, pushIdentity: identity);
      expect(decoded, isNotNull);
      expect(decoded!.title, 'Handler needs you');
      expect(decoded.body, 'Deploy?');
      expect(decoded.sourceMessageId, 'e1');
      expect(decoded.kind, 'handler');
    },
  );

  test('decodePush carries kind and projectId through', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {
      'title': 'Task complete',
      'body': 'done',
      'kind': 'agent',
      'projectId': 'proj-42',
      'sourceMessageId': 'm9',
    });
    final decoded = await decodePush(box, pushIdentity: identity);
    expect(decoded, isNotNull);
    expect(decoded!.kind, 'agent');
    expect(decoded.projectId, 'proj-42');
    expect(decoded.sourceMessageId, 'm9');
  });

  test('decodePush maps a missing/empty sourceMessageId to null', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {'title': 'x', 'body': 'y'});
    final decoded = await decodePush(box, pushIdentity: identity);
    expect(decoded!.sourceMessageId, isNull);
  });

  test('pushDedupKey prefers sourceMessageId, falls back, then null', () {
    const withSrc = (
      title: 't',
      body: 'b',
      kind: null,
      projectId: null,
      sourceMessageId: 'src1',
    );
    expect(pushDedupKey(withSrc, fcmMessageId: 'fcm1'), 'src1');

    const noSrc = (
      title: 't',
      body: 'b',
      kind: null,
      projectId: null,
      sourceMessageId: null,
    );
    // Two id-less pushes must NOT collide: fall back to the distinct FCM id.
    expect(pushDedupKey(noSrc, fcmMessageId: 'fcm1'), 'fcm1');
    expect(pushDedupKey(noSrc, fcmMessageId: 'fcm2'), 'fcm2');
    // Neither present → null so the caller shows rather than dedups it away.
    expect(pushDedupKey(noSrc, fcmMessageId: null), isNull);
  });

  test('decodePush returns null on garbage data', () async {
    final decoded = await decodePush({
      'epk': 'AA',
      'box': 'AA',
    }, pushIdentity: PushIdentity.inMemory());
    expect(decoded, isNull);
  });
}

/// Seal [payload] to [recipientPubB64] the same way the bridge does, returning
/// the `{epk, box}` FCM data map decodePush expects.
Future<Map<String, String>> _sealTo(
  String recipientPubB64,
  Map<String, dynamic> payload,
) async {
  final x = X25519();
  final recipientPub = SimplePublicKey(
    base64Decode(recipientPubB64),
    type: KeyPairType.x25519,
  );
  final eph = await x.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final shared = await x.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: recipientPub,
  );
  final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKeyData(await shared.extractBytes()),
    nonce: ephPub.bytes,
    info: utf8.encode('antgrid-push-v1'),
  );
  final sb = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(payload)),
    secretKey: key,
  );
  final box = base64Encode([...sb.nonce, ...sb.cipherText, ...sb.mac.bytes]);
  return {'epk': base64Encode(ephPub.bytes), 'box': box};
}
