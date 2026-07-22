// packages/antgrid_relay_client/lib/src/relay_auth.dart
// Byte-for-byte mirror of packages/antgrid-wire/src/relay-auth.ts.
// Spec: docs/plans/2026-07-16-relay-v3-connection-redesign.md §4.1. The shared
// vector fixture (evals/fixtures/relay-hello-vector.json) pins both languages.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Domain-separation string for the v3 `hello` signature body.
const String relayAuthDomain = 'antgrid.relay-auth.v3';
const int _versionByte = 0x03;

/// Canonical byte string signed in `hello.sig`, fields joined with a single
/// 0x00 byte, no trailing separator. The licenseToken enters as its raw
/// SHA-256 digest (fixed 32 bytes) so the body stays small and the token —
/// which may contain 0x00-free but long base64url — cannot shift field
/// boundaries. Length-unambiguous because every field is either fixed-length
/// or excludes 0x00 (same argument as the E2E transcript builder).
///
/// Layout: `domain | 0x03 | relayHost | deviceType | deviceId | publicKey |
/// epoch(decimal) | SHA-256(licenseToken) raw 32 bytes | ts | nonce`.
Uint8List buildHelloSigBody({
  required String relayHost,
  required String deviceType,
  required String deviceId,
  required String publicKey,
  required int epoch,
  required String licenseToken,
  required String ts,
  required String nonce,
}) {
  final b = BytesBuilder();
  b.add(utf8.encode(relayAuthDomain));
  b.addByte(0);
  b.addByte(_versionByte);
  b.addByte(0);
  b.add(utf8.encode(relayHost));
  b.addByte(0);
  b.add(utf8.encode(deviceType));
  b.addByte(0);
  b.add(utf8.encode(deviceId));
  b.addByte(0);
  b.add(utf8.encode(publicKey));
  b.addByte(0);
  b.add(utf8.encode(epoch.toString()));
  b.addByte(0);
  b.add(crypto.sha256.convert(utf8.encode(licenseToken)).bytes);
  b.addByte(0);
  b.add(utf8.encode(ts));
  b.addByte(0);
  b.add(utf8.encode(nonce));
  return b.toBytes();
}

/// Normalizes a relay WS URL to the `relayHost` signed above: lowercase `host`
/// when the port is the scheme default (443 for wss/https, 80 for ws/http),
/// else lowercase `host:port`. The relay applies the SAME rules to the upgrade
/// request's Host header before comparing; mismatch = AUTH_FAILED.
///
/// Dart's [Uri] differs from WHATWG URL: [Uri.port] returns the scheme default
/// (443/80) for known schemes when omitted, and [Uri.parse] does not know the
/// ws/wss defaults. So compute the default explicitly and emit `host:port` only
/// when the parsed port is present and differs from that default.
String normalizeRelayHost(String relayUrl) {
  final uri = Uri.parse(relayUrl);
  final host = uri.host.toLowerCase();
  final scheme = uri.scheme.toLowerCase();
  final defaultPort = (scheme == 'wss' || scheme == 'https') ? 443 : 80;
  final port = uri.port;
  if (port == 0 || port == defaultPort) return host;
  return '$host:$port';
}
