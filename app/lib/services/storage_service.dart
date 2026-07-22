import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

class StorageService {
  final FlutterSecureStorage _storage;

  StorageService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<DeviceIdentity?> loadIdentity() async {
    final deviceId = await _storage.read(key: 'device_id');
    if (deviceId == null) return null;

    final name = await _storage.read(key: 'device_name') ?? 'Antgrid App';
    final ed25519Priv = await _readBytes('ed25519_private_key');
    final ed25519Pub = await _readBytes('ed25519_public_key');
    final x25519Priv = await _readBytes('x25519_private_key');
    final x25519Pub = await _readBytes('x25519_public_key');

    if (ed25519Priv == null ||
        ed25519Pub == null ||
        x25519Priv == null ||
        x25519Pub == null) {
      return null;
    }

    return DeviceIdentity(
      deviceId: deviceId,
      name: name,
      ed25519PrivateKey: ed25519Priv,
      ed25519PublicKey: ed25519Pub,
      x25519PrivateKey: x25519Priv,
      x25519PublicKey: x25519Pub,
    );
  }

  Future<void> saveIdentity(DeviceIdentity identity) async {
    await _storage.write(key: 'device_id', value: identity.deviceId);
    await _storage.write(key: 'device_name', value: identity.name);
    await _writeBytes('ed25519_private_key', identity.ed25519PrivateKey);
    await _writeBytes('ed25519_public_key', identity.ed25519PublicKey);
    await _writeBytes('x25519_private_key', identity.x25519PrivateKey);
    await _writeBytes('x25519_public_key', identity.x25519PublicKey);
  }

  Future<List<PairedAgent>> loadPairedAgents() async {
    final raw = await _storage.read(key: 'paired_agents');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => PairedAgent(
              relayUrl: e['relayUrl'] as String,
              agentDeviceId: e['agentDeviceId'] as String,
              agentName: e['agentName'] as String,
              // Session keys are per-connection and never persisted (v2).
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> savePairedAgents(List<PairedAgent> agents) async {
    final list = agents
        .map(
          (a) => {
            'relayUrl': a.relayUrl,
            'agentDeviceId': a.agentDeviceId,
            'agentName': a.agentName,
            // Session keys are per-connection and never persisted (v2).
          },
        )
        .toList();
    await _storage.write(key: 'paired_agents', value: jsonEncode(list));
  }

  Future<void> clearPairedAgents() async {
    await _storage.delete(key: 'paired_agents');
  }

  Future<Uint8List?> _readBytes(String key) async {
    final value = await _storage.read(key: key);
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  Future<void> _writeBytes(String key, Uint8List bytes) async {
    await _storage.write(key: key, value: base64.encode(bytes));
  }
}
