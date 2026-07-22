import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/agent_keys.dart';

void main() {
  test('generates Ed25519 + X25519 keypairs with 32-byte raw fields', () async {
    final k = await AgentKeys.generate();
    expect(k.ed25519Pub.length, 32);
    expect(k.ed25519Priv.length, 32);
    expect(k.x25519Pub.length, 32);
    expect(k.x25519Priv.length, 32);
  });

  test('base64 round-trips', () async {
    final k = await AgentKeys.generate();
    final restored = AgentKeys.fromBase64(
      ed25519Pub: k.ed25519PubBase64,
      ed25519Priv: k.ed25519PrivBase64,
      x25519Pub: k.x25519PubBase64,
      x25519Priv: k.x25519PrivBase64,
    );
    expect(restored.ed25519Pub, k.ed25519Pub);
    expect(restored.x25519Priv, k.x25519Priv);
  });
}
