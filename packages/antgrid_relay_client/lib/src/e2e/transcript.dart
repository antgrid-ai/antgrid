// packages/antgrid_relay_client/lib/src/e2e/transcript.dart
// Spec: docs/protocol/e2e-handshake.md §"Canonical transcript".
// Byte-for-byte mirror of bridge/src/e2e/transcript.ts.
import 'dart:convert';
import 'dart:typed_data';

const domainV2 = 'antgrid.e2e-handshake.v2';
const versionByte = 0x02;

class TranscriptFields {
  final String registrationId;
  final String role; // 'agent' | 'phone'
  final String agentDeviceId;
  final String phoneDeviceId;

  /// Raw 32 bytes, or ZERO-LENGTH for the phone's client-hello signature.
  final Uint8List agentX25519Pub;
  final Uint8List phoneX25519Pub;
  final Uint8List nonce;

  const TranscriptFields({
    required this.registrationId,
    required this.role,
    required this.agentDeviceId,
    required this.phoneDeviceId,
    required this.agentX25519Pub,
    required this.phoneX25519Pub,
    required this.nonce,
  });
}

/// Fields joined with 0x00 separators, no trailing separator.
Uint8List buildTranscriptV2(TranscriptFields f) {
  final b = BytesBuilder();
  b.add(utf8.encode(domainV2));
  b.addByte(0);
  b.addByte(versionByte);
  b.addByte(0);
  b.add(utf8.encode(f.registrationId));
  b.addByte(0);
  b.add(utf8.encode(f.role));
  b.addByte(0);
  b.add(utf8.encode(f.agentDeviceId));
  b.addByte(0);
  b.add(utf8.encode(f.phoneDeviceId));
  b.addByte(0);
  b.add(f.agentX25519Pub);
  b.addByte(0);
  b.add(f.phoneX25519Pub);
  b.addByte(0);
  b.add(f.nonce);
  return b.toBytes();
}
