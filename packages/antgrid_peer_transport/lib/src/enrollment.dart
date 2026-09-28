import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'authorization.dart';

typedef AuthenticatedPeerRequest =
    Future<Map<String, dynamic>> Function(
      String method,
      String path,
      Map<String, dynamic>? body,
    );

/// The caller supplies a strict device-authenticated HTTP client, never a session cookie.
class EndpointEnrollmentClient {
  EndpointEnrollmentClient({
    required this.request,
    required this.accountId,
    required this.deviceId,
    required this.enrollmentId,
  });
  final AuthenticatedPeerRequest request;
  final String accountId, deviceId, enrollmentId;

  Future<AuthorizationSnapshot> fetchSnapshot() async {
    final json = await request(
      'GET',
      '/account/devices/me/authorization',
      null,
    );
    try {
      return AuthorizationSnapshot.fromJson(json);
    } on TypeError {
      throw const FormatException('Malformed authorization snapshot');
    }
  }

  Future<PeerRegistration> register({
    required Uint8List deviceSecret,
    required Uint8List endpointSecret,
    required BigInt expectedGeneration,
  }) async {
    final algorithm = Ed25519();
    final endpointKey = await algorithm.newKeyPairFromSeed(endpointSecret);
    final deviceKey = await algorithm.newKeyPairFromSeed(deviceSecret);
    final public = await endpointKey.extractPublicKey();
    final endpointId = public.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final challenge =
        await request('POST', '/account/devices/me/endpoint-challenge', {
          'endpointId': endpointId,
          'expectedGeneration': expectedGeneration.toString(),
        });
    final bytes = endpointChallengeBytes(challenge);
    if (challenge['accountId'] != accountId ||
        challenge['deviceId'] != deviceId ||
        challenge['enrollmentId'] != enrollmentId ||
        challenge['endpointId'] != endpointId ||
        challenge['expectedGeneration'] != expectedGeneration.toString()) {
      throw const FormatException('Enrollment challenge identity mismatch');
    }
    final deviceSignature = await algorithm.sign(bytes, keyPair: deviceKey);
    final endpointSignature = await algorithm.sign(bytes, keyPair: endpointKey);
    final result = PeerRegistration.fromJson(
      await request('POST', '/account/devices/me/endpoint-registration', {
        'challengeId': challenge['challengeId'],
        'deviceSignature': base64Encode(deviceSignature.bytes),
        'endpointSignature': base64Encode(endpointSignature.bytes),
      }),
    );
    if (result.endpointId != endpointId ||
        result.generation != expectedGeneration + BigInt.one) {
      throw const FormatException('Enrollment registration mismatch');
    }
    return result;
  }
}
