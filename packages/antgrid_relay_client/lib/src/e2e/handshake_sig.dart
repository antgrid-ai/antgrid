// packages/antgrid_relay_client/lib/src/e2e/handshake_sig.dart
// Spec: docs/protocol/e2e-handshake.md §"Message flow" (sig_p / sig_a).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ed25519 over the raw canonical transcript bytes (NOT prehashed).
Future<String> signTranscriptV2({
  required Uint8List transcript,
  required List<int> ed25519Seed,
}) async {
  if (ed25519Seed.length != 32) {
    throw ArgumentError(
      'ed25519Seed must be 32 bytes, got ${ed25519Seed.length}',
    );
  }
  final kp = await Ed25519().newKeyPairFromSeed(ed25519Seed);
  final sig = await Ed25519().sign(transcript, keyPair: kp);
  return base64.encode(sig.bytes);
}

Future<bool> verifyTranscriptSigV2({
  required Uint8List transcript,
  required String ed25519PubB64,
  required String sigB64,
}) async {
  final Uint8List pub;
  final Uint8List sig;
  try {
    pub = base64.decode(ed25519PubB64);
    sig = base64.decode(sigB64);
  } catch (_) {
    return false;
  }
  if (pub.length != 32) return false;
  try {
    return await Ed25519().verify(
      transcript,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}
