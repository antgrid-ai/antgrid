// packages/antgrid_relay_client/lib/src/e2e/transport.dart
// Spec: docs/protocol/e2e-handshake.md §"Transport".
// Framing: nonce(12) || ciphertext || tag(16). [fixedNonce] is for golden
// vectors ONLY; production nonces are random (AesGcm default).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Intentionally stateless: holds only references to the directional keys, so
/// it is safe (and cheap) to construct per call. Key-material lifetime is owned
/// by [SessionKeys] — callers zeroize via [SessionKeys.zeroize], NOT per
/// transport instance.
class E2eTransportDart {
  final Uint8List sendKey;
  final Uint8List recvKey;
  E2eTransportDart({required this.sendKey, required this.recvKey});

  /// AES-256-GCM used by every [seal]/[open]. Lazy, so a host that calls
  /// [useAlgorithm] before the first frame never constructs the default.
  static AesGcm _algorithm = AesGcm.with256bits();

  /// Swap in a faster AES-256-GCM. `package:cryptography`'s default is a pure
  /// Dart cipher running at single-digit MB/s ON THE CALLING ISOLATE, and every
  /// sealed frame goes through it — including whole tunneled preview responses,
  /// where that is seconds of blocked UI per dev-server page load. Flutter hosts
  /// install a native-backed implementation at startup; taking it as an [AesGcm]
  /// is what keeps this package Flutter-free.
  ///
  /// [algorithm] MUST be wire-compatible with a 32-byte key and a 12-byte nonce:
  /// the bridge half is node:crypto's `aes-256-gcm` (bridge/src/e2e/transport.ts)
  /// and the framing here is nonce || ciphertext || tag. Deliberately scoped to
  /// the transport cipher — the handshake's Ed25519/X25519/HKDF stay on the Dart
  /// implementations that produce the transcript bytes the bridge verifies.
  static void useAlgorithm(AesGcm algorithm) => _algorithm = algorithm;

  Future<Uint8List> seal(String plaintext, {Uint8List? fixedNonce}) async {
    final box = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKeyData(sendKey),
      nonce: fixedNonce,
    );
    return Uint8List.fromList([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  Future<String?> open(Uint8List data) async {
    try {
      if (data.length < 12 + 16) return null;
      final box = SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: Mac(data.sublist(data.length - 16)),
      );
      final plainBytes = await _algorithm.decrypt(
        box,
        secretKey: SecretKeyData(recvKey),
      );
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }

  void zeroize() {
    sendKey.fillRange(0, sendKey.length, 0);
    recvKey.fillRange(0, recvKey.length, 0);
  }
}
