import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class CryptoService {
  /// Generate an Ed25519 keypair for relay authentication.
  /// Returns (privateKeyBytes, publicKeyBytes).
  Future<(Uint8List, Uint8List)> generateEd25519KeyPair() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return (
      Uint8List.fromList(privateBytes),
      Uint8List.fromList(publicKey.bytes),
    );
  }

  /// Sign data with an Ed25519 private key.
  Future<Uint8List> ed25519Sign(
    Uint8List data,
    Uint8List privateKeyBytes,
    Uint8List publicKeyBytes,
  ) async {
    final algorithm = Ed25519();
    final keyPair = SimpleKeyPairData(
      privateKeyBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    final signature = await algorithm.sign(data, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  /// Generate an X25519 keypair for ECDH key exchange.
  /// Returns (privateKeyBytes, publicKeyBytes).
  Future<(Uint8List, Uint8List)> generateX25519KeyPair() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return (
      Uint8List.fromList(privateBytes),
      Uint8List.fromList(publicKey.bytes),
    );
  }
}
