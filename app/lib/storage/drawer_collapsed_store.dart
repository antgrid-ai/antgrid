import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// SharedPreferences-backed persistence for the set of drawer entries the user
/// has explicitly collapsed. The drawer expands every project by default, so we
/// store the *exceptions* (collapses) rather than the expansions — that way a
/// newly opened project is expanded out of the box without the store needing to
/// know the full id list. Ids share one namespace (local project ids + remote
/// agent device ids); stale ids never match a live entry and are harmless.
class DrawerCollapsedStore {
  static final _key = scopedStorageKey('antgrid.drawer_collapsed.v1');
  final SharedPreferencesWithCache _prefs;

  DrawerCollapsedStore._(this._prefs);

  static Future<DrawerCollapsedStore> open() async =>
      DrawerCollapsedStore._(await openScopedPrefs({_key}));

  Set<String> read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const <String>{};
    final arr = jsonDecode(raw) as List;
    return arr.map((e) => e as String).toSet();
  }

  Future<void> write(Set<String> ids) async {
    await _prefs.setString(_key, jsonEncode(ids.toList()));
  }
}
