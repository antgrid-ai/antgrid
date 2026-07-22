import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// A stable, anonymous per-install identifier. NOT the account id or device uuid;
/// used only to compute retention over first-party events. The id persists in
/// secure storage across sessions; when telemetry is disabled it is simply never
/// transmitted (opt-out does NOT clear it). [SecureInstallIdStore.reset] is
/// available API for a future explicit reset (e.g. on app-data clear or
/// reinstall) but is not currently wired to the opt-out toggle.
abstract class InstallIdStore {
  Future<String> ensure();
}

class SecureInstallIdStore implements InstallIdStore {
  SecureInstallIdStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'antgrid.analytics.install_id.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String> ensure() async {
    // Secure storage can throw (Android Keystore decryption failure, missing
    // keyring backend on Linux/Windows). This runs awaited in main(), so an
    // uncaught throw would hard-crash startup. Telemetry is non-essential —
    // fall back to an ephemeral id rather than block the app from launching.
    try {
      final existing = await _storage.read(key: _key);
      if (existing != null && existing.isNotEmpty) return existing;
      final id = const Uuid().v4();
      await _storage.write(key: _key, value: id);
      return id;
    } catch (_) {
      return const Uuid().v4();
    }
  }

  Future<void> reset() => _storage.delete(key: _key);
}

class InMemoryInstallIdStore implements InstallIdStore {
  String? _id;
  @override
  Future<String> ensure() async => _id ??= const Uuid().v4();
}
