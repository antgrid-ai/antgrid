import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/notification_route.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/services/local_notification_service.dart';
import 'package:antgrid/services/push_background_handler.dart';
import 'package:push/push.dart';

import '../helpers/prefs_test_mock.dart';

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
        sentAt: null,
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
        sentAt: null,
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
        sentAt: null,
      );
      // The same repo at the same path on two machines mints one projectId.
      expect(routeOfPush(decoded), isNull);
    });

    test('a payload with neither projectId nor machineUuid names nothing', () {
      const decoded = (
        title: 't',
        body: 'b',
        kind: 'agent',
        projectId: null,
        machineUuid: null,
        terminalId: null,
        sourceMessageId: 'm9',
        sentAt: null,
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
      expect(decodeNotificationRoute(encodeNotificationRoute(route!)), route);
    });
  });

  // Blank and whitespace collapse to absent the way `namedOrNull` does on the route
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
      sentAt: null,
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
      sentAt: null,
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

  group('sentAt', () {
    Future<DecodedPush?> decodeWith(Object? sentAt) async {
      final identity = PushIdentity.inMemory();
      final kp = await identity.ensureKeypair();
      return decodePush(
        await _sealTo(kp.pubkeyB64, {
          'title': 'Task complete',
          'body': 'done',
          'sentAt': ?sentAt,
        }),
        pushIdentity: identity,
      );
    }

    test('decodePush parses epoch milliseconds', () async {
      final decoded = await decodeWith(1767225600000);
      expect(
        decoded!.sentAt,
        DateTime.fromMillisecondsSinceEpoch(1767225600000, isUtc: true),
      );
    });

    // Like the ids, a sentAt the app cannot read costs that field, never the
    // alert, and it must never read as stale.
    for (final (label, raw) in <(String, Object?)>[
      ('missing', null),
      ('a string', '1767225600000'),
      ('a bool', true),
      ('zero', 0),
      ('negative', -5),
      ('beyond DateTime range', 1e300),
      ('a map', <String, Object?>{'ms': 1}),
    ]) {
      test(
        'decodePush maps $label sentAt to null and keeps the push',
        () async {
          final decoded = await decodeWith(raw);
          expect(decoded, isNotNull);
          expect(decoded!.title, 'Task complete');
          expect(decoded.sentAt, isNull);
        },
      );
    }
  });

  group('isStalePush', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    DecodedPush sentAt(DateTime? at) => (
      title: 't',
      body: 'b',
      kind: null,
      projectId: null,
      machineUuid: null,
      terminalId: null,
      sourceMessageId: null,
      sentAt: at,
    );

    test('exactly kPushMaxAge old is not stale', () {
      expect(isStalePush(sentAt(now.subtract(kPushMaxAge)), now), isFalse);
    });

    test('just over kPushMaxAge is stale', () {
      final at = now.subtract(kPushMaxAge + const Duration(milliseconds: 1));
      expect(isStalePush(sentAt(at), now), isTrue);
    });

    test('a fresh push is not stale', () {
      final at = now.subtract(const Duration(minutes: 5));
      expect(isStalePush(sentAt(at), now), isFalse);
    });

    test('a future sentAt (clock skew) is not stale', () {
      final at = now.add(const Duration(days: 2));
      expect(isStalePush(sentAt(at), now), isFalse);
    });

    test('a missing sentAt (older bridge) is not stale', () {
      expect(isStalePush(sentAt(null), now), isFalse);
    });

    test('kPushMaxAge matches the relay TTL of 43200s', () {
      expect(kPushMaxAge.inSeconds, 43200);
    });
  });

  group('pushShouldAlert', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    DecodedPush push({DateTime? sentAt, String? kind}) => (
      title: 't',
      body: 'b',
      kind: kind,
      projectId: null,
      machineUuid: null,
      terminalId: null,
      sourceMessageId: null,
      sentAt: sentAt,
    );

    test('the first push rings', () {
      expect(pushShouldAlert(push(sentAt: now), now, null), isTrue);
    });

    test('a push within kPushAlertGap of the last alert is silent', () {
      final last = now.subtract(kPushAlertGap - const Duration(seconds: 1));
      expect(pushShouldAlert(push(sentAt: now), now, last), isFalse);
    });

    test('a push kPushAlertGap after the last alert rings', () {
      expect(
        pushShouldAlert(push(sentAt: now), now, now.subtract(kPushAlertGap)),
        isTrue,
      );
    });

    test('a push arriving later than kPushLateAfter is silent', () {
      final sent = now.subtract(kPushLateAfter + const Duration(seconds: 1));
      expect(pushShouldAlert(push(sentAt: sent), now, null), isFalse);
    });

    test('exactly kPushLateAfter late still rings', () {
      final sent = now.subtract(kPushLateAfter);
      expect(pushShouldAlert(push(sentAt: sent), now, null), isTrue);
    });

    test('a missing sentAt (older bridge) is not late', () {
      expect(pushShouldAlert(push(), now, null), isTrue);
    });

    test('an on-time escalation rings inside the gap', () {
      final last = now.subtract(const Duration(seconds: 1));
      expect(
        pushShouldAlert(push(sentAt: now, kind: 'handler'), now, last),
        isTrue,
      );
    });

    test('a late escalation is silent', () {
      final sent = now.subtract(const Duration(hours: 1));
      expect(
        pushShouldAlert(push(sentAt: sent, kind: 'handler'), now, null),
        isFalse,
      );
    });

    test('a last alert in the future (clock moved back) does not mute', () {
      final last = now.add(const Duration(minutes: 10));
      expect(pushShouldAlert(push(sentAt: now), now, last), isTrue);
    });
  });

  group('claimPushAlert', () {
    setUp(useInMemoryPrefs);
    final now = DateTime.utc(2026, 1, 1, 12);
    final fresh = (
      title: 't',
      body: 'b',
      kind: null,
      projectId: null,
      machineUuid: null,
      terminalId: null,
      sourceMessageId: null,
      sentAt: now,
    );

    test('a backlog delivered at once rings exactly once', () async {
      final claims = await Future.wait([
        for (var i = 0; i < 10; i++) claimPushAlert(fresh, now),
      ]);
      expect(claims.where((c) => c), hasLength(1));
      expect(claims.first, isTrue);
    });

    test('a silent push does not restart the gap', () async {
      expect(await claimPushAlert(fresh, now), isTrue);
      final muted = now.add(const Duration(seconds: 20));
      expect(await claimPushAlert(fresh, muted), isFalse);
      // 30s after the ring, not after the muted one.
      final next = now.add(kPushAlertGap);
      expect(await claimPushAlert(fresh, next), isTrue);
    });
  });

  group('notificationSlotOf', () {
    DecodedPush push({
      String? machineUuid = 'machine-1',
      String? projectId = 'proj-42',
      String? terminalId,
      String? kind,
      String? sourceMessageId,
    }) => (
      title: 't',
      body: 'b',
      kind: kind,
      projectId: projectId,
      machineUuid: machineUuid,
      terminalId: terminalId,
      sourceMessageId: sourceMessageId,
      sentAt: null,
    );

    test('one session keeps one tag and one id across pushes', () {
      final a = notificationSlotOf(push(terminalId: 'sess-7'))!;
      final b = notificationSlotOf(push(terminalId: 'sess-7'))!;
      expect(a.tag, b.tag);
      expect(notificationIdForTag(a.tag), notificationIdForTag(b.tag));
    });

    test('different sessions get different tags in one project group', () {
      final a = notificationSlotOf(push(terminalId: 'sess-7'))!;
      final b = notificationSlotOf(push(terminalId: 'sess-8'))!;
      expect(a.tag, isNot(b.tag));
      expect(a.groupKey, b.groupKey);
      expect(a.groupKey, 'machine-1|proj-42');
    });

    test('a push with no session is the project thread', () {
      final slot = notificationSlotOf(push())!;
      expect(slot.tag, 'machine-1|proj-42');
      expect(slot.groupKey, 'machine-1|proj-42');
    });

    test('another project or machine is another group', () {
      final base = notificationSlotOf(push(terminalId: 'sess-7'))!;
      final otherProject = notificationSlotOf(
        push(projectId: 'proj-43', terminalId: 'sess-7'),
      )!;
      final otherMachine = notificationSlotOf(
        push(machineUuid: 'machine-2', terminalId: 'sess-7'),
      )!;
      expect(otherProject.groupKey, isNot(base.groupKey));
      expect(otherMachine.groupKey, isNot(base.groupKey));
      expect(otherMachine.tag, isNot(base.tag));
    });

    test('an escalation never shares a slot with its session', () {
      // The session keeps pushing after it escalates; a shared tag would let
      // the next agent push replace the question the user has to answer.
      final escalation = notificationSlotOf(
        push(terminalId: 'sess-7', kind: 'handler', sourceMessageId: 'esc-1'),
      )!;
      final later = notificationSlotOf(
        push(terminalId: 'sess-7', kind: 'agent', sourceMessageId: 'msg-2'),
      )!;
      final another = notificationSlotOf(
        push(terminalId: 'sess-7', kind: 'handler', sourceMessageId: 'esc-2'),
      )!;
      expect(escalation.tag, isNot(later.tag));
      expect(
        notificationIdForTag(escalation.tag),
        isNot(notificationIdForTag(later.tag)),
      );
      expect(escalation.tag, isNot(another.tag));
      expect(escalation.groupKey, later.groupKey);
      expect(
        notificationSlotOf(push(terminalId: 'sess-7', kind: 'handler'))!.tag,
        isNot(later.tag),
      );
    });

    test('no slot without both machineUuid and projectId', () {
      expect(notificationSlotOf(push(machineUuid: null)), isNull);
      expect(notificationSlotOf(push(projectId: null)), isNull);
      expect(
        notificationSlotOf(
          push(machineUuid: null, projectId: null, terminalId: 'sess-7'),
        ),
        isNull,
      );
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
