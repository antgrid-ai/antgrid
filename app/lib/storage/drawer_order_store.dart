import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// SharedPreferences-backed persistence for the user's drawer ordering. The
/// order is a flat list of [DrawerEntry.id]s — local project ids and remote
/// agent device ids share the same namespace because the drawer is a single
/// reorderable list. Stale ids (rows the user removed) are ignored on read;
/// new ids (newly opened projects, newly paired agents) are appended at the
/// end of the displayed list and only persisted when the user actually drags.
class DrawerOrderStore {
  static final _key = scopedStorageKey('antgrid.drawer_order.v1');
  final SharedPreferencesWithCache _prefs;

  DrawerOrderStore._(this._prefs);

  static Future<DrawerOrderStore> open() async =>
      DrawerOrderStore._(await openScopedPrefs({_key}));

  List<String> list() {
    final raw = _prefs.getString(_key);
    if (raw == null) return List.unmodifiable(const <String>[]);
    final arr = jsonDecode(raw) as List;
    return List.unmodifiable(arr.map((e) => e as String));
  }

  Future<void> write(List<String> ids) async {
    await _prefs.setString(_key, jsonEncode(ids));
  }
}
