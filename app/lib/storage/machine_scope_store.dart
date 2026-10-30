import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// Persists the machine scope's explicit choices. A machine the user never
/// touched is absent from both sets and follows the default rule (see
/// `MachineScope.includes`), so a machine added to the account later needs no
/// migration here.
class MachineScopeStore {
  static final _key = scopedStorageKey('antgrid.machine_scope.v1');
  final SharedPreferencesWithCache _prefs;

  MachineScopeStore._(this._prefs);

  static Future<MachineScopeStore> open() async =>
      MachineScopeStore._(await openScopedPrefs({_key}));

  ({Set<String> included, Set<String> excluded, bool hideOffline}) read() {
    final raw = _prefs.getString(_key);
    const empty = (
      included: <String>{},
      excluded: <String>{},
      hideOffline: false,
    );
    if (raw == null) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      Set<String> ids(Object? v) =>
          v is List ? {for (final e in v) if (e is String) e} : <String>{};
      return (
        included: ids(decoded['included']),
        excluded: ids(decoded['excluded']),
        hideOffline: decoded['hideOffline'] == true,
      );
    } catch (_) {
      return empty;
    }
  }

  Future<void> write({
    required Set<String> included,
    required Set<String> excluded,
    required bool hideOffline,
  }) => _prefs.setString(
    _key,
    jsonEncode({
      'included': included.toList()..sort(),
      'excluded': excluded.toList()..sort(),
      'hideOffline': hideOffline,
    }),
  );
}
