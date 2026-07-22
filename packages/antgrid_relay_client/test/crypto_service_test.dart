import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

void main() {
  late CryptoService crypto;

  setUp(() {
    crypto = CryptoService();
  });

  group('Ed25519', () {
    test('generates keypair and signs data', () async {
      final (privateKey, publicKey) = await crypto.generateEd25519KeyPair();
      expect(privateKey.length, 32);
      expect(publicKey.length, 32);

      final data = Uint8List.fromList(utf8.encode('test-nonce'));
      final signature = await crypto.ed25519Sign(data, privateKey, publicKey);
      expect(signature.length, 64);
    });
  });

  group('X25519 keypair', () {
    test('generates x25519 keypair with correct lengths', () async {
      final (priv, pub) = await crypto.generateX25519KeyPair();
      expect(priv.length, 32);
      expect(pub.length, 32);
    });

    test('two calls produce distinct keypairs', () async {
      final (_, pubA) = await crypto.generateX25519KeyPair();
      final (_, pubB) = await crypto.generateX25519KeyPair();
      // Exceedingly unlikely to collide; confirms fresh random generation.
      expect(pubA, isNot(equals(pubB)));
    });
  });
}
