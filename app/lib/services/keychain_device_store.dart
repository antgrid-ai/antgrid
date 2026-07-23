import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/storage_scope.dart';

/// Pluggable seam for tests.
abstract class DeviceSecretStorage {
  Future<String?> read();
  Future<void> write(String v);
  Future<void> delete();
}

class SecureDeviceSecretStorage implements DeviceSecretStorage {
  static final _key = scopedStorageKey('antgrid.device.v1');
  final FlutterSecureStorage _s;
  SecureDeviceSecretStorage({FlutterSecureStorage? storage})
    : _s = storage ?? const FlutterSecureStorage();
  @override
  Future<String?> read() => _s.read(key: _key);
  @override
  Future<void> write(String v) => _s.write(key: _key, value: v);
  @override
  Future<void> delete() => _s.delete(key: _key);
}

class DeviceRecord {
  DeviceRecord({
    required this.userId,
    required this.deviceUuid,
    required this.clientId,
    required this.clientSecret,
    required this.ed25519Pub,
    required this.ed25519Priv,
    required this.x25519Pub,
    required this.x25519Priv,
  });

  final String userId;
  final String deviceUuid;
  final String clientId;
  final String clientSecret;
  final String ed25519Pub;
  final String ed25519Priv;
  final String x25519Pub;
  final String x25519Priv;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'deviceUuid': deviceUuid,
    'clientId': clientId,
    'clientSecret': clientSecret,
    'ed25519Pub': ed25519Pub,
    'ed25519Priv': ed25519Priv,
    'x25519Pub': x25519Pub,
    'x25519Priv': x25519Priv,
  };

  static DeviceRecord fromJson(Map<String, dynamic> j) => DeviceRecord(
    userId: j['userId'] as String,
    deviceUuid: j['deviceUuid'] as String,
    clientId: j['clientId'] as String,
    clientSecret: j['clientSecret'] as String,
    ed25519Pub: j['ed25519Pub'] as String,
    ed25519Priv: j['ed25519Priv'] as String,
    x25519Pub: j['x25519Pub'] as String,
    x25519Priv: j['x25519Priv'] as String,
  );
}

class KeychainDeviceStore {
  KeychainDeviceStore({DeviceSecretStorage? storage})
    : _storage = storage ?? SecureDeviceSecretStorage();
  final DeviceSecretStorage _storage;

  Future<DeviceRecord?> read() async {
    final raw = await _storage.read();
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return DeviceRecord.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Read iff the stored record's userId matches the current session's.
  Future<DeviceRecord?> readIfMatchesUser(String userId) async {
    final rec = await read();
    if (rec == null || rec.userId != userId) return null;
    return rec;
  }

  Future<void> write(DeviceRecord rec) async {
    await _storage.write(jsonEncode(rec.toJson()));
  }

  Future<void> clear() => _storage.delete();
}
