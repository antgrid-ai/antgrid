import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/storage_scope.dart';

/// Pluggable seam for tests.
abstract class DeviceSecretStorage {
  Future<String?> read();
  Future<void> write(String v);
  Future<void> delete();
}

/// Keychain key of this machine's account device record. On desktop that record
/// is the LOCAL bridge's relay identity (`kind:"agent"`).
const kDeviceRecordStorageKey = 'antgrid.device.v1';

/// Keychain key of the desktop CONTROLLER record — a second, `kind:"app"`
/// device used only for outbound remote-control connections. It must be a
/// distinct device: dialing the relay as the main record would put two live
/// connections on one deviceId, and epoch arbitration would evict our own
/// bridge.
const kControllerDeviceRecordStorageKey = 'antgrid.device.v1.controller';

class SecureDeviceSecretStorage implements DeviceSecretStorage {
  final String _key;
  final FlutterSecureStorage _s;
  SecureDeviceSecretStorage({FlutterSecureStorage? storage, String? key})
    : _s = storage ?? const FlutterSecureStorage(),
      _key = scopedStorageKey(key ?? kDeviceRecordStorageKey);
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

/// Two independent slots: the machine's account device record, and the desktop
/// controller record (see [kControllerDeviceRecordStorageKey]). Same JSON
/// round-trip, separate lifetimes — clearing one never touches the other.
class KeychainDeviceStore {
  KeychainDeviceStore({
    DeviceSecretStorage? storage,
    DeviceSecretStorage? controllerStorage,
  }) : _storage = storage ?? SecureDeviceSecretStorage(),
       _controllerStorage =
           controllerStorage ??
           SecureDeviceSecretStorage(key: kControllerDeviceRecordStorageKey);
  final DeviceSecretStorage _storage;
  final DeviceSecretStorage _controllerStorage;

  Future<DeviceRecord?> read() => _readFrom(_storage);

  /// Read iff the stored record's userId matches the current session's.
  Future<DeviceRecord?> readIfMatchesUser(String userId) =>
      _readIfMatchesUser(_storage, userId);

  Future<void> write(DeviceRecord rec) async {
    await _storage.write(jsonEncode(rec.toJson()));
  }

  Future<void> clear() => _storage.delete();

  Future<DeviceRecord?> readController() => _readFrom(_controllerStorage);

  Future<DeviceRecord?> readControllerIfMatchesUser(String userId) =>
      _readIfMatchesUser(_controllerStorage, userId);

  Future<void> writeController(DeviceRecord rec) async {
    await _controllerStorage.write(jsonEncode(rec.toJson()));
  }

  Future<void> clearController() => _controllerStorage.delete();

  static Future<DeviceRecord?> _readFrom(DeviceSecretStorage storage) async {
    final raw = await storage.read();
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return DeviceRecord.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  static Future<DeviceRecord?> _readIfMatchesUser(
    DeviceSecretStorage storage,
    String userId,
  ) async {
    final rec = await _readFrom(storage);
    if (rec == null || rec.userId != userId) return null;
    return rec;
  }
}
