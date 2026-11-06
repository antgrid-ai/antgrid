import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// Persists the phone's last-picked machine and when the phone last had a
/// connection up to it, which is what decides whether a launch goes back to it.
class MobileMachineStore {
  static final _key = scopedStorageKey('antgrid.mobile_machine.v2');
  final SharedPreferencesWithCache _prefs;

  MobileMachineStore._(this._prefs);

  static Future<MobileMachineStore> open() async =>
      MobileMachineStore._(await openScopedPrefs({_key}));

  ({String? lastMachineId, DateTime? connectedAt}) read() {
    const empty = (lastMachineId: null, connectedAt: null);
    final raw = _prefs.getString(_key);
    if (raw == null) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      final last = decoded['lastMachineId'];
      final at = decoded['connectedAt'];
      return (
        lastMachineId: last is String && last.isNotEmpty ? last : null,
        connectedAt: at is int
            ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)
            : null,
      );
    } catch (_) {
      return empty;
    }
  }

  Future<void> clear() => _prefs.remove(_key);

  Future<void> write({
    required String? lastMachineId,
    required DateTime? connectedAt,
  }) => _prefs.setString(
    _key,
    jsonEncode({
      'lastMachineId': lastMachineId,
      'connectedAt': connectedAt?.millisecondsSinceEpoch,
    }),
  );
}
