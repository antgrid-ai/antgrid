import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/storage_scope.dart';

/// Purges the QR-era `paired_agents` blob.
///
/// Nothing writes that key any more — QR pairing is gone and admission is
/// account trust — but an install that predates the change still carries one,
/// and the account purge must evict it like any other account-scoped store.
class StorageService {
  final FlutterSecureStorage _storage;

  StorageService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<void> clearPairedAgents() async {
    await _storage.delete(key: scopedStorageKey('paired_agents'));
  }
}
