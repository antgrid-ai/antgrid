import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// Persists the machines the user unchecked from the scope. A machine never
/// touched is absent and follows the default rule (see
/// `MachineScope.includes`), so a machine added to the account later needs no
/// migration here.
class MachineScopeStore {
  static final _key = scopedStorageKey('antgrid.machine_scope.v1');
  final SharedPreferencesWithCache _prefs;

  MachineScopeStore._(this._prefs);

  static Future<MachineScopeStore> open() async =>
      MachineScopeStore._(await openScopedPrefs({_key}));

  /// The excluded machine ids. Fields other builds wrote under the same key
  /// (`included`, `hideOffline`) are ignored.
  Set<String> read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final v = decoded['excluded'];
      return v is List ? {for (final e in v) if (e is String) e} : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> write({required Set<String> excluded}) => _prefs.setString(
    _key,
    jsonEncode({'excluded': excluded.toList()..sort()}),
  );
}
