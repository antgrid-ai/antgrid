import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';

void main() {
  test('both enrollment keys sign the same bound challenge bytes', () async {
    final deviceSecret = Uint8List(32)..fillRange(0, 32, 1);
    final endpointSecret = Uint8List(32)..fillRange(0, 32, 2);
    final ed = Ed25519();
    final deviceKey = await ed.newKeyPairFromSeed(deviceSecret);
    final endpointKey = await ed.newKeyPairFromSeed(endpointSecret);
    final endpointPublic = await endpointKey.extractPublicKey();
    final endpointId = endpointPublic.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final challenge = <String, dynamic>{
      'challengeId': '00000000-0000-4000-8000-000000000001',
      'challenge': base64Encode(List.filled(32, 3)),
      'accountId': 'account',
      'deviceId': '00000000-0000-4000-8000-000000000002',
      'enrollmentId': 'credential',
      'endpointId': endpointId,
      'expectedGeneration': '9007199254740993',
    };
    final client = EndpointEnrollmentClient(
      accountId: 'account',
      deviceId: challenge['deviceId'] as String,
      enrollmentId: 'credential',
      request: (method, path, body) async {
        expect(method, 'POST');
        if (path.endsWith('endpoint-challenge')) {
          expect(body, {
            'endpointId': endpointId,
            'expectedGeneration': '9007199254740993',
          });
          return challenge;
        }
        expect(path, '/account/devices/me/endpoint-registration');
        final bytes = endpointChallengeBytes(challenge);
        expect(
          await ed.verify(
            bytes,
            signature: Signature(
              base64Decode(body!['deviceSignature'] as String),
              publicKey: await deviceKey.extractPublicKey(),
            ),
          ),
          isTrue,
        );
        expect(
          await ed.verify(
            bytes,
            signature: Signature(
              base64Decode(body['endpointSignature'] as String),
              publicKey: endpointPublic,
            ),
          ),
          isTrue,
        );
        return {'endpointId': endpointId, 'generation': '9007199254740994'};
      },
    );
    final result = await client.register(
      deviceSecret: deviceSecret,
      endpointSecret: endpointSecret,
      expectedGeneration: BigInt.parse('9007199254740993'),
    );
    expect(result.generation, BigInt.parse('9007199254740994'));
  });
  test(
    'cross-device challenge is rejected before sending registration',
    () async {
      var requests = 0;
      final client = EndpointEnrollmentClient(
        accountId: 'account',
        deviceId: '00000000-0000-4000-8000-000000000002',
        enrollmentId: 'credential',
        request: (method, path, body) async {
          requests++;
          return {
            'challengeId': '00000000-0000-4000-8000-000000000001',
            'challenge': base64Encode(List.filled(32, 3)),
            'accountId': 'other-account',
            'deviceId': '00000000-0000-4000-8000-000000000003',
            'enrollmentId': 'credential',
            'endpointId': body!['endpointId'],
            'expectedGeneration': '0',
          };
        },
      );
      await expectLater(
        client.register(
          deviceSecret: Uint8List(32),
          endpointSecret: Uint8List(32),
          expectedGeneration: BigInt.zero,
        ),
        throwsFormatException,
      );
      expect(requests, 1);
    },
  );
}
