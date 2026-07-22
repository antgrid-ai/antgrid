import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Per-device keypairs held by the app. Generated once on first remote-mode
/// provisioning and stored in the OS keychain; passed into spawned agents via
/// stdin and never written to disk in plaintext.
class AgentKeys {
  AgentKeys({
    required this.ed25519Pub,
    required this.ed25519Priv,
    required this.x25519Pub,
    required this.x25519Priv,
  });

  final Uint8List ed25519Pub;
  final Uint8List ed25519Priv;
  final Uint8List x25519Pub;
  final Uint8List x25519Priv;

  String get ed25519PubBase64 => base64Encode(ed25519Pub);
  String get ed25519PrivBase64 => base64Encode(ed25519Priv);
  String get x25519PubBase64 => base64Encode(x25519Pub);
  String get x25519PrivBase64 => base64Encode(x25519Priv);

  static Future<AgentKeys> generate() async {
    final ed = await Ed25519().newKeyPair();
    final edPub = await ed.extractPublicKey();
    final edPriv = await ed.extractPrivateKeyBytes();
    final x = await X25519().newKeyPair();
    final xPub = await x.extractPublicKey();
    final xPriv = await x.extractPrivateKeyBytes();
    return AgentKeys(
      ed25519Pub: Uint8List.fromList(edPub.bytes),
      ed25519Priv: Uint8List.fromList(edPriv),
      x25519Pub: Uint8List.fromList(xPub.bytes),
      x25519Priv: Uint8List.fromList(xPriv),
    );
  }

  static AgentKeys fromBase64({
    required String ed25519Pub,
    required String ed25519Priv,
    required String x25519Pub,
    required String x25519Priv,
  }) {
    return AgentKeys(
      ed25519Pub: base64Decode(ed25519Pub),
      ed25519Priv: base64Decode(ed25519Priv),
      x25519Pub: base64Decode(x25519Pub),
      x25519Priv: base64Decode(x25519Priv),
    );
  }
}
