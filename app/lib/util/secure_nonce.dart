import 'dart:convert';
import 'dart:math';

/// A fresh, base64-encoded 16-byte nonce. Used to bind pairing / handshake
/// transcript signatures to a single exchange.
///
/// [rng] defaults to a cryptographically secure RNG; tests may inject a seeded
/// [Random] for deterministic nonces.
String secureNonceB64({Random? rng}) {
  final r = rng ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return base64.encode(bytes);
}
