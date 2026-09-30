import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:test/test.dart';

/// Both branches are asserted against the constant this binary was compiled
/// with, so the suite gates the default build and still gates a dev build run
/// as `dart --define=ANTGRID_DEV_INSECURE_RELAY=true test`.
void main() {
  test('a TLS origin is approved and a malformed one never is', () {
    expect(isApprovedRelayOrigin('https://relay.example/'), isTrue);
    expect(isApprovedRelayOrigin('https://relay.example'), isTrue);
    for (final url in [
      'https://user:secret@relay.example/',
      'https://relay.example/?token=secret',
      'https://relay.example/#fragment',
      'https://relay.example/path',
      'https://',
      'wss://relay.example/',
      'relay.example',
      '',
    ]) {
      expect(isApprovedRelayOrigin(url), isFalse, reason: url);
    }
  });

  test('plaintext is approved only in a build that opted in', () {
    for (final url in [
      'http://127.0.0.1:3000/',
      'http://localhost:3000/',
      // A LAN address is the point: a phone or emulator has to reach the stack.
      'http://192.168.1.10:3000/',
      'http://10.0.2.2:3000/',
      'http://172.16.4.1:3000/',
      'http://[::1]:3000/',
    ]) {
      expect(isApprovedRelayOrigin(url), kDevInsecureRelay, reason: url);
    }
    // Opting in widens the scheme within a network the developer controls, and
    // nothing else — a public plaintext origin is refused by every build.
    for (final url in [
      'http://user:secret@127.0.0.1:3000/',
      'http://127.0.0.1:3000/?token=secret',
      'http://127.0.0.1:3000/path',
      'http://relay.example/',
      'http://8.8.8.8:3000/',
      'http://172.32.0.1:3000/',
      'http://999.0.0.1:3000/',
    ]) {
      expect(isApprovedRelayOrigin(url), isFalse, reason: url);
    }
  });

  test('an authorization snapshot cannot carry an origin this build refuses', () {
    Map<String, dynamic> snapshot(List<String> relayUrls) => {
      'accountId': 'account',
      'deviceId': '00000000-0000-4000-8000-000000000000',
      'enrollmentId': 'enrollment',
      'policyGeneration': '1',
      'registrationGeneration': '1',
      'allowed': true,
      'leaseMs': 60000,
      'endpoint': null,
      'peers': <Map<String, dynamic>>[],
      'relayUrls': relayUrls,
    };
    expect(AuthorizationSnapshot.fromJson(snapshot(const [])).relayUrls, isEmpty);
    expect(AuthorizationSnapshot.fromJson(snapshot(const ['https://relay.example/']))
        .relayUrls, ['https://relay.example/']);
    final plaintext = () => AuthorizationSnapshot.fromJson(snapshot(const ['http://127.0.0.1:3000/']));
    if (kDevInsecureRelay) {
      expect(plaintext().relayUrls, ['http://127.0.0.1:3000/']);
    } else {
      expect(plaintext, throwsA(isA<FormatException>()));
    }
  });
}
