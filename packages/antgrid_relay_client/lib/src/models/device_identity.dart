import 'dart:typed_data';

import '../e2e/key_schedule.dart';

class DeviceIdentity {
  final String deviceId;
  final String name;
  final Uint8List ed25519PrivateKey;
  final Uint8List ed25519PublicKey;
  final Uint8List x25519PrivateKey;
  final Uint8List x25519PublicKey;

  const DeviceIdentity({
    required this.deviceId,
    required this.name,
    required this.ed25519PrivateKey,
    required this.ed25519PublicKey,
    required this.x25519PrivateKey,
    required this.x25519PublicKey,
  });

  DeviceIdentity copyWith({String? deviceId}) {
    return DeviceIdentity(
      deviceId: deviceId ?? this.deviceId,
      name: name,
      ed25519PrivateKey: ed25519PrivateKey,
      ed25519PublicKey: ed25519PublicKey,
      x25519PrivateKey: x25519PrivateKey,
      x25519PublicKey: x25519PublicKey,
    );
  }
}

class PairedAgent {
  final String relayUrl;
  final String agentDeviceId;
  final String agentName;

  /// Per-connection session keys (phone perspective: send = p2a, recv = a2p).
  /// Null until the first v2 handshake completes on the current connection.
  /// NEVER persisted — spec §"Key lifetime".
  final SessionKeys? keys;

  const PairedAgent({
    required this.relayUrl,
    required this.agentDeviceId,
    required this.agentName,
    this.keys,
  });
}
