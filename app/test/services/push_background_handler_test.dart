import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/notification_route.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/services/push_background_handler.dart';
import 'package:push/push.dart';

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

  test('decodePush carries machineUuid and terminalId through', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {
      'title': 'Task complete',
      'body': 'done',
      'projectId': 'proj-42',
      'machineUuid': 'machine-1',
      'terminalId': 'sess-7',
    });
    final decoded = await decodePush(box, pushIdentity: identity);
    expect(decoded!.machineUuid, 'machine-1');
    expect(decoded.terminalId, 'sess-7');
  });

  test('decodePush maps absent routing ids to null', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {'title': 'x', 'body': 'y'});
    final decoded = await decodePush(box, pushIdentity: identity);
    expect(decoded!.machineUuid, isNull);
    expect(decoded.terminalId, isNull);
    expect(decoded.projectId, isNull);
  });

  test('decodePush maps blank routing ids to null', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {
      'title': 'x',
      'body': 'y',
      'projectId': '',
      'machineUuid': '',
      'terminalId': '',
    });
    final decoded = await decodePush(box, pushIdentity: identity);
    // '' would satisfy a `!= null` test and address a project nobody has.
    expect(decoded!.projectId, isNull);
    expect(decoded.machineUuid, isNull);
    expect(decoded.terminalId, isNull);
  });

  test('decodePush survives a routing id of the wrong type', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {
      'title': 'Task complete',
      'body': 'done',
      'machineUuid': 7,
      'projectId': 'proj-42',
    });
    final decoded = await decodePush(box, pushIdentity: identity);
    // A cast would throw into decodePush's catch and drop the whole alert.
    expect(decoded, isNotNull);
    expect(decoded!.title, 'Task complete');
    expect(decoded.machineUuid, isNull);
    expect(decoded.projectId, 'proj-42');
  });

  group('routeOfPush', () {
    test('addresses a project by machine + project', () {
      const decoded = (
        title: 't',
        body: 'b',
        kind: 'handler',
        projectId: 'proj-42',
        machineUuid: 'machine-1',
        terminalId: 'sess-7',
        sourceMessageId: 'm9',
      );
      expect(
        routeOfPush(decoded),
        const NotificationRoute(
          machineUuid: 'machine-1',
          projectId: 'proj-42',
          terminalId: 'sess-7',
          sourceMessageId: 'm9',
          kind: 'handler',
        ),
      );
    });

    test('a session alone is still addressable', () {
      const decoded = (
        title: 't',
        body: 'b',
        kind: null,
        projectId: null,
        machineUuid: null,
        terminalId: 'sess-7',
        sourceMessageId: null,
      );
      expect(routeOfPush(decoded)?.terminalId, 'sess-7');
    });

    test('a project without its machine names nothing', () {
      const decoded = (
        title: 't',
        body: 'b',
        kind: null,
        projectId: 'proj-42',
        machineUuid: null,
        terminalId: null,
        sourceMessageId: 'm9',
      );
      // The same repo at the same path on two machines mints one projectId.
      expect(routeOfPush(decoded), isNull);
    });

    test('a pre-W1 bridge payload names nothing', () {
      const decoded = (
        title: 't',
        body: 'b',
        kind: 'agent',
        projectId: null,
        machineUuid: null,
        terminalId: null,
        sourceMessageId: 'm9',
      );
      expect(routeOfPush(decoded), isNull);
    });

    // The step `pushBackgroundHandler` performs before handing the payload to
    // the OS. FCM is data-only, so that handler renders EVERY Android
    // background push — if what it seals does not survive the round trip, no
    // Android notification is tappable-to-route at all, and nothing else in
    // this suite would notice.
    test('the sealed payload survives the round trip a tap makes', () async {
      final identity = PushIdentity.inMemory();
      final kp = await identity.ensureKeypair();
      final decoded = await decodePush(
        await _sealTo(kp.pubkeyB64, {
          'title': 'Handler needs you',
          'body': 'Deploy?',
          'kind': 'handler',
          'projectId': 'proj-42',
          'machineUuid': 'machine-1',
          'terminalId': 'sess-7',
          'sourceMessageId': 'e1',
        }),
        pushIdentity: identity,
      );
      final route = routeOfPush(decoded!);
      expect(
        decodeNotificationRoute(encodeNotificationRoute(route!)),
        route,
      );
    });
  });

  // Blank and whitespace collapse to absent the way `_named` does on the route
  // side: an id only one of the two predicates accepts survives decoding and
  // then addresses nothing.
  test('decodePush drops a whitespace-only routing id', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final decoded = await decodePush(
      await _sealTo(kp.pubkeyB64, {
        'title': 't',
        'body': 'b',
        'machineUuid': '  ',
        'projectId': 'proj-42',
      }),
      pushIdentity: identity,
    );
    expect(decoded!.machineUuid, isNull);
    expect(routeOfPush(decoded), isNull);
  });

  test('decodePush maps a missing/empty sourceMessageId to null', () async {
    final identity = PushIdentity.inMemory();
    final kp = await identity.ensureKeypair();
    final box = await _sealTo(kp.pubkeyB64, {'title': 'x', 'body': 'y'});
    final decoded = await decodePush(box, pushIdentity: identity);
    expect(decoded!.sourceMessageId, isNull);
  });

  test('pushDedupKey returns sourceMessageId, else null', () {
    const withSrc = (
      title: 't',
      body: 'b',
      kind: null,
      projectId: null,
      machineUuid: null,
      terminalId: null,
      sourceMessageId: 'src1',
    );
    expect(pushDedupKey(withSrc), 'src1');

    const noSrc = (
      title: 't',
      body: 'b',
      kind: null,
      projectId: null,
      machineUuid: null,
      terminalId: null,
      sourceMessageId: null,
    );
    // No id → null so the caller shows the push rather than deduping it away.
    expect(pushDedupKey(noSrc), isNull);
  });

  group('pushDataOf', () {
    test('keeps string entries', () {
      final m = RemoteMessage(data: <String?, Object?>{'epk': 'A', 'box': 'B'});
      expect(pushDataOf(m), <String, String>{'epk': 'A', 'box': 'B'});
    });

    test('drops null keys and non-string values rather than throwing', () {
      final m = RemoteMessage(
        data: <String?, Object?>{'epk': 'A', null: 'orphan', 'n': 3},
      );
      expect(pushDataOf(m), <String, String>{'epk': 'A'});
    });

    test('a null data payload is an empty map, not a crash', () {
      expect(pushDataOf(RemoteMessage()), isEmpty);
    });
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
