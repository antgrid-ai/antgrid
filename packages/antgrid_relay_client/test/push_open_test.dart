import 'dart:convert';
import 'dart:io';

import 'package:antgrid_relay_client/src/e2e/push_open.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

Future<Map<String, String>> _sealLikeBridge(
  String plaintext,
  SimplePublicKey recipientPub,
) async {
  final x = X25519();
  final eph = await x.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final shared = await x.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: recipientPub,
  );
  final sharedBytes = await shared.extractBytes();
  final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKeyData(sharedBytes),
    nonce: ephPub.bytes, // salt = epk bytes (matches bridge)
    info: utf8.encode('antgrid-push-v1'),
  );
  final aes = AesGcm.with256bits();
  final secretBox = await aes.encrypt(utf8.encode(plaintext), secretKey: key);
  final box = <int>[
    ...secretBox.nonce,
    ...secretBox.cipherText,
    ...secretBox.mac.bytes,
  ];
  return {'epk': base64Encode(ephPub.bytes), 'box': base64Encode(box)};
}

void main() {
  test('openPushBlob decrypts a sealed payload', () async {
    final x = X25519();
    final recipient = await x.newKeyPair();
    final recipientPub = await recipient.extractPublicKey();
    final recipientPriv = await recipient.extractPrivateKeyBytes();

    const plaintext = '{"title":"Task complete","body":"done"}';
    final blob = await _sealLikeBridge(plaintext, recipientPub);

    final opened = await openPushBlob(
      epkB64: blob['epk']!,
      boxB64: blob['box']!,
      pushPrivSeed: recipientPriv,
    );
    expect(opened, plaintext);
  });

  test('a tampered box returns null', () async {
    final x = X25519();
    final recipient = await x.newKeyPair();
    final recipientPub = await recipient.extractPublicKey();
    final recipientPriv = await recipient.extractPrivateKeyBytes();
    final blob = await _sealLikeBridge('secret', recipientPub);
    final raw = base64Decode(blob['box']!);
    raw[raw.length - 1] ^= 0xff;
    final opened = await openPushBlob(
      epkB64: blob['epk']!,
      boxB64: base64Encode(raw),
      pushPrivSeed: recipientPriv,
    );
    expect(opened, isNull);
  });

  // Cross-language vector: this blob was produced by the Node bridge sealPush
  // (Task 4 Step 5, committed at test/fixtures/push_vector.json). Opening it here
  // proves the KDF + framing match byte-for-byte across Node and Dart — the one
  // thing the same-language round-trips above cannot catch. If this fails, the
  // Node/Dart HKDF salt/info, the X25519 seed handling, or the nonce‖ct‖tag frame
  // has drifted between bridge/src/push/seal.ts and push_open.dart.
  test('opens a fixed vector sealed by the Node bridge', () async {
    final vector =
        jsonDecode(await File('test/fixtures/push_vector.json').readAsString())
            as Map<String, dynamic>;
    final opened = await openPushBlob(
      epkB64: vector['epk'] as String,
      boxB64: vector['box'] as String,
      pushPrivSeed: base64Decode(vector['recipientPrivSeed'] as String),
    );
    expect(opened, vector['plaintext'] as String);
  });
}
