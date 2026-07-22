// packages/antgrid_relay_client/lib/src/e2e/key_schedule.dart
// Spec: docs/protocol/e2e-handshake.md §"Key schedule".
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _hkdfInfoV2 = 'antgrid-e2e-v2';

class SessionKeys {
  final Uint8List a2p; // agent → phone
  final Uint8List p2a; // phone → agent
  final Uint8List confirm;
  SessionKeys({required this.a2p, required this.p2a, required this.confirm});

  /// Best-effort zeroization at session teardown (spec §"Key lifetime").
  void zeroize() {
    a2p.fillRange(0, a2p.length, 0);
    p2a.fillRange(0, p2a.length, 0);
    confirm.fillRange(0, confirm.length, 0);
  }
}

/// Raw X25519 ECDH (no KDF) — feeds [deriveSessionKeysV2].
Future<Uint8List> x25519SharedSecret({
  required List<int> privateKey,
  required List<int> peerPublicKey,
}) async {
  final algorithm = X25519();
  final keyPair = SimpleKeyPairData(
    privateKey,
    publicKey: SimplePublicKey(
      // Public key bytes are required by SimpleKeyPairData but unused for ECDH;
      // deriving from the private scalar keeps callers honest.
      (await (await algorithm.newKeyPairFromSeed(privateKey)).extractPublicKey()).bytes,
      type: KeyPairType.x25519,
    ),
    type: KeyPairType.x25519,
  );
  final shared = await algorithm.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await shared.extractBytes());
}

/// okm(96) = HKDF-SHA256(salt = SHA-256(full agent-role transcript), ikm = ss,
/// info = "antgrid-e2e-v2"). Zeroizes [sharedSecret] in place.
Future<SessionKeys> deriveSessionKeysV2(
  Uint8List sharedSecret,
  Uint8List fullAgentRoleTranscript,
) async {
  final context = (await Sha256().hash(fullAgentRoleTranscript)).bytes;
  final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 96);
  final okm = await hkdf.deriveKey(
    secretKey: SecretKeyData(sharedSecret),
    nonce: context,
    info: utf8.encode(_hkdfInfoV2),
  );
  final bytes = Uint8List.fromList(await okm.extractBytes());
  sharedSecret.fillRange(0, sharedSecret.length, 0);
  return SessionKeys(
    a2p: Uint8List.sublistView(bytes, 0, 32),
    p2a: Uint8List.sublistView(bytes, 32, 64),
    confirm: Uint8List.sublistView(bytes, 64, 96),
  );
}
