import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// Persists the phone's last-connected machine and whether to reconnect to it
/// at launch. Only the choice is stored: whether that machine is up is asked
/// fresh every launch.
class MobileMachineStore {
  static final _key = scopedStorageKey('antgrid.mobile_machine.v1');
  final SharedPreferencesWithCache _prefs;

  MobileMachineStore._(this._prefs);

  static Future<MobileMachineStore> open() async =>
      MobileMachineStore._(await openScopedPrefs({_key}));

  ({String? lastMachineId, bool reconnect}) read() {
    const empty = (lastMachineId: null, reconnect: true);
    final raw = _prefs.getString(_key);
    if (raw == null) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      final last = decoded['lastMachineId'];
      return (
        lastMachineId: last is String && last.isNotEmpty ? last : null,
        reconnect: decoded['reconnect'] != false,
      );
    } catch (_) {
      return empty;
    }
  }

  Future<void> write({
    required String? lastMachineId,
    required bool reconnect,
  }) => _prefs.setString(
    _key,
    jsonEncode({'lastMachineId': lastMachineId, 'reconnect': reconnect}),
  );
}
