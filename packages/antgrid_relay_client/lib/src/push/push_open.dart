import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Decrypt a push blob sealed by the bridge's sealPush (ephemeral-static X25519 +
/// AES-256-GCM). Returns the plaintext JSON, or null if authentication fails.
/// KDF MUST match bridge/src/push/seal.ts: key = HKDF-SHA256(ECDH, salt=epkBytes,
/// info="antgrid-push-v1", 32); box = nonce(12) ‖ ciphertext ‖ tag(16).
Future<String?> openPushBlob({
  required String epkB64,
  required String boxB64,
  required List<int> pushPrivSeed,
}) async {
  try {
    final epk = base64Decode(epkB64);
    final raw = base64Decode(boxB64);
    if (raw.length < 12 + 16) return null;

    final x = X25519();
    final keyPair = await x.newKeyPairFromSeed(pushPrivSeed);
    final shared = await x.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final key = await hkdf.deriveKey(
      secretKey: SecretKeyData(sharedBytes),
      nonce: epk, // salt = epk bytes
      info: utf8.encode('antgrid-push-v1'),
    );

    final nonce = raw.sublist(0, 12);
    final mac = raw.sublist(raw.length - 16);
    final ct = raw.sublist(12, raw.length - 16);
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return utf8.decode(plain);
  } catch (_) {
    return null;
  }
}
