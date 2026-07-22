import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:antgrid_relay_client/src/pair_sign.dart';

void main() {
  test('Dart signPairRequest reproduces the TS fixture signature byte-for-byte',
      () async {
    final raw = await File(
      '../../evals/fixtures/pair-request-vectors.json',
    ).readAsString();
    final v = jsonDecode(raw) as Map<String, dynamic>;
    final args = v['args'] as Map<String, dynamic>;
    final seedHex = v['phoneSeedHex'] as String;

    // Decode the 32-byte phone seed.
    final seed = <int>[];
    for (var i = 0; i < seedHex.length; i += 2) {
      seed.add(int.parse(seedHex.substring(i, i + 2), radix: 16));
    }

    final sigB64 = await signPairRequest(
      agentDeviceId: args['agentDeviceId'] as String,
      phonePubkey: args['phonePubkey'] as String,
      phoneDeviceId: args['phoneDeviceId'] as String,
      nonce: args['nonce'] as String,
      requestedAt: args['requestedAt'] as String,
      privSeed: seed,
    );

    expect(sigB64, equals(v['signatureB64'] as String));
  });

  test('Dart signPairRequest output is verifiable with the recorded pubkey',
      () async {
    final raw = await File(
      '../../evals/fixtures/pair-request-vectors.json',
    ).readAsString();
    final v = jsonDecode(raw) as Map<String, dynamic>;
    final args = v['args'] as Map<String, dynamic>;
    final seedHex = v['phoneSeedHex'] as String;
    final seed = <int>[];
    for (var i = 0; i < seedHex.length; i += 2) {
      seed.add(int.parse(seedHex.substring(i, i + 2), radix: 16));
    }

    final sigB64 = await signPairRequest(
      agentDeviceId: args['agentDeviceId'] as String,
      phonePubkey: args['phonePubkey'] as String,
      phoneDeviceId: args['phoneDeviceId'] as String,
      nonce: args['nonce'] as String,
      requestedAt: args['requestedAt'] as String,
      privSeed: seed,
    );

    final body = buildPairRequestSigBody(
      agentDeviceId: args['agentDeviceId'] as String,
      phonePubkey: args['phonePubkey'] as String,
      phoneDeviceId: args['phoneDeviceId'] as String,
      nonce: args['nonce'] as String,
      requestedAt: args['requestedAt'] as String,
    );
    final pub = SimplePublicKey(
      base64.decode(v['phonePubkeyB64'] as String),
      type: KeyPairType.ed25519,
    );
    final sig = Signature(base64.decode(sigB64), publicKey: pub);
    final ok = await Ed25519().verify(body, signature: sig);
    expect(ok, isTrue);
  });
}
