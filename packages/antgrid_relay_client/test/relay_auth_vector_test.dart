import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

Uint8List _hexDecode(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexEncode(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // Fixture path resolved the same way as e2e_vectors_test.dart.
  final v =
      jsonDecode(
            File(
              '../../evals/fixtures/relay-hello-vector.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final fields = v['fields'] as Map<String, dynamic>;
  final ed = v['ed25519'] as Map<String, dynamic>;

  Uint8List sigBody() => buildHelloSigBody(
    relayHost: fields['relayHost'] as String,
    deviceType: fields['deviceType'] as String,
    deviceId: fields['deviceId'] as String,
    publicKey: fields['publicKey'] as String,
    epoch: fields['epoch'] as int,
    licenseToken: fields['licenseToken'] as String,
    ts: fields['ts'] as String,
    nonce: fields['nonce'] as String,
  );

  test('buildHelloSigBody matches the golden vector bytes', () {
    expect(_hexEncode(sigBody()), v['sigBodyHex']);
  });

  test('normalizeRelayHost matches fields.relayHost', () {
    expect(normalizeRelayHost(v['relayUrl'] as String), fields['relayHost']);
  });

  test('fixture signature verifies under publicKeyB64', () async {
    final pub = base64.decode(ed['publicKeyB64'] as String);
    final sig = base64.decode(v['sigB64'] as String);
    final ok = await Ed25519().verify(
      sigBody(),
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519),
      ),
    );
    expect(ok, isTrue);
  });

  test(
    'signing the body with the seed reproduces sigB64 (deterministic)',
    () async {
      final kp = await Ed25519().newKeyPairFromSeed(
        _hexDecode(ed['seedHex'] as String),
      );
      final sig = await Ed25519().sign(sigBody(), keyPair: kp);
      expect(base64.encode(sig.bytes), v['sigB64']);
    },
  );

  group('normalizeRelayHost unit cases', () {
    test('drops default wss port', () {
      expect(
        normalizeRelayHost('wss://relay.antgrid.ai/ws'),
        'relay.antgrid.ai',
      );
    });
    test('keeps non-default ws port', () {
      expect(normalizeRelayHost('ws://localhost:3000'), 'localhost:3000');
    });
    test('drops default ws port (80)', () {
      expect(normalizeRelayHost('ws://localhost:80'), 'localhost');
    });
    test('lowercases host and keeps non-default port', () {
      expect(
        normalizeRelayHost('wss://Relay.Antgrid.ai:8443/ws'),
        'relay.antgrid.ai:8443',
      );
    });
  });
}
