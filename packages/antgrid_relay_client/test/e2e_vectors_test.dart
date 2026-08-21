// packages/antgrid_relay_client/test/e2e_vectors_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

Uint8List hexDecode(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hexEncode(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v =
      jsonDecode(
            File(
              '../../evals/fixtures/e2e-handshake-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final ids = v['ids'] as Map<String, dynamic>;
  final x = v['x25519'] as Map<String, dynamic>;
  final ed = v['ed25519'] as Map<String, dynamic>;
  final ks = v['keySchedule'] as Map<String, dynamic>;

  TranscriptFields phoneFields() => TranscriptFields(
    registrationId: ids['registrationId'] as String,
    role: 'phone',
    agentDeviceId: ids['agentDeviceId'] as String,
    phoneDeviceId: ids['phoneDeviceId'] as String,
    agentX25519Pub: Uint8List(0),
    phoneX25519Pub: base64.decode(x['phonePubB64'] as String),
    nonce: base64.decode(v['nonceB64'] as String),
  );
  TranscriptFields agentFields() => TranscriptFields(
    registrationId: ids['registrationId'] as String,
    role: 'agent',
    agentDeviceId: ids['agentDeviceId'] as String,
    phoneDeviceId: ids['phoneDeviceId'] as String,
    agentX25519Pub: base64.decode(x['agentPubB64'] as String),
    phoneX25519Pub: base64.decode(x['phonePubB64'] as String),
    nonce: base64.decode(v['nonceB64'] as String),
  );

  test('transcript bytes match golden vectors', () {
    final t = v['transcripts'] as Map<String, dynamic>;
    expect(hexEncode(buildTranscriptV2(phoneFields())), t['phoneSigBodyHex']);
    expect(hexEncode(buildTranscriptV2(agentFields())), t['agentSigBodyHex']);
  });

  test('signatures match and verify', () async {
    final sigs = v['signatures'] as Map<String, dynamic>;
    final phoneSig = await signTranscriptV2(
      transcript: buildTranscriptV2(phoneFields()),
      ed25519Seed: hexDecode(ed['phoneSeedHex'] as String),
    );
    expect(phoneSig, sigs['phoneSigB64']);
    final ok = await verifyTranscriptSigV2(
      transcript: buildTranscriptV2(agentFields()),
      ed25519PubB64: ed['agentPubB64'] as String,
      sigB64: sigs['agentSigB64'] as String,
    );
    expect(ok, isTrue);
  });

  test('key schedule matches from the phone side DH', () async {
    final ss = await x25519SharedSecret(
      privateKey: hexDecode(x['phonePrivHex'] as String),
      peerPublicKey: base64.decode(x['agentPubB64'] as String),
    );
    final keys = await deriveSessionKeysV2(
      ss,
      buildTranscriptV2(agentFields()),
    );
    expect(hexEncode(keys.a2p), ks['kA2pHex']);
    expect(hexEncode(keys.p2a), ks['kP2aHex']);
    expect(hexEncode(keys.confirm), ks['kConfirmHex']);
  });

  test('confirm tags match', () async {
    final c = v['confirm'] as Map<String, dynamic>;
    final ck = hexDecode(ks['kConfirmHex'] as String);
    expect(hexEncode(await agentConfirmTagV2(ck)), c['agentTagHex']);
    expect(hexEncode(await phoneConfirmTagV2(ck)), c['phoneTagHex']);
  });

  test('transport vectors seal and open (phone perspective)', () async {
    final phoneT = E2eTransportDart(
      sendKey: hexDecode(ks['kP2aHex'] as String),
      recvKey: hexDecode(ks['kA2pHex'] as String),
    );
    for (final t in (v['transport'] as List).cast<Map<String, dynamic>>()) {
      if (t['dir'] == 'a2p') {
        expect(
          await phoneT.open(hexDecode(t['sealedHex'] as String)),
          t['plaintext'],
        );
      } else {
        final sealed = await phoneT.seal(
          t['plaintext'] as String,
          fixedNonce: hexDecode(t['nonceHex'] as String),
        );
        expect(hexEncode(sealed), t['sealedHex']);
      }
    }
  });

  test('constant-time confirm verify rejects tamper', () {
    final a = hexDecode(
      (v['confirm'] as Map<String, dynamic>)['agentTagHex'] as String,
    );
    final bad = Uint8List.fromList(a)..[0] ^= 1;
    expect(verifyConfirmTagV2(a, a), isTrue);
    expect(verifyConfirmTagV2(a, bad), isFalse);
    expect(verifyConfirmTagV2(a, a.sublist(0, 31)), isFalse);
  });
}
