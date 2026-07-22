import Foundation
import CryptoKit

/// Decrypt a push blob sealed by the bridge's sealPush (ephemeral-static X25519
/// + AES-256-GCM). Returns the plaintext JSON, or nil on any failure.
/// KDF MUST match bridge/src/push/seal.ts and push_open.dart:
///   shared = X25519(eph, static); key = HKDF-SHA256(shared, salt=epkBytes,
///   info="antgrid-push-v1", 32); box = nonce(12) ‖ ciphertext ‖ tag(16).
enum PushCrypto {
  static func open(epkB64: String, boxB64: String, seed: Data) -> String? {
    guard let epk = Data(base64Encoded: epkB64),
          let raw = Data(base64Encoded: boxB64),
          raw.count >= 12 + 16 else { return nil }
    do {
      let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
      let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk)
      let shared = try priv.sharedSecretFromKeyAgreement(with: pub)
      // hkdfDerivedSymmetricKey runs HKDF-SHA256 over the raw 32-byte shared
      // secret as IKM — identical to node's hkdfSync("sha256", shared, epk, info).
      let key = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: epk,
        sharedInfo: Data("antgrid-push-v1".utf8),
        outputByteCount: 32)
      let nonce = try AES.GCM.Nonce(data: raw.prefix(12))
      let tag = raw.suffix(16)
      let ct = raw.dropFirst(12).dropLast(16)
      let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
      let plain = try AES.GCM.open(sealed, using: key)
      return String(data: plain, encoding: .utf8)
    } catch {
      return nil
    }
  }
}
