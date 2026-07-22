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

  Future<Uint8List> seal(String plaintext, {Uint8List? fixedNonce}) async {
    final algorithm = AesGcm.with256bits();
    final box = await algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKeyData(sendKey),
      nonce: fixedNonce,
    );
    return Uint8List.fromList([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<String?> open(Uint8List data) async {
    try {
      if (data.length < 12 + 16) return null;
      final box = SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: Mac(data.sublist(data.length - 16)),
      );
      final plainBytes = await AesGcm.with256bits()
          .decrypt(box, secretKey: SecretKeyData(recvKey));
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
