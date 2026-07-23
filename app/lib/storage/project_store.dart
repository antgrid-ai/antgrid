import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'scoped_prefs.dart';

import '../config/storage_scope.dart';
import '../models/ab_project.dart';

/// SharedPreferences-backed persistence for the user's opened-project list.
///
/// Stored under a single JSON-encoded key so reads/writes are atomic per call.
/// Suitable for the small lists this App produces (tens of projects). Move to
/// a real DB if it grows.
class ProjectStore {
  static final _key = scopedStorageKey('antgrid.projects.v1');
  final SharedPreferencesWithCache _prefs;

  ProjectStore(this._prefs);

  static Future<ProjectStore> open() async =>
      ProjectStore(await openScopedPrefs({_key}));

  List<AbProject> list() {
    final raw = _prefs.getString(_key);
    if (raw == null) return [];
    final arr = jsonDecode(raw) as List;
    return arr
        .map((j) => AbProject.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> upsert(AbProject p) async {
    final all = list();
    final i = all.indexWhere((x) => x.projectId == p.projectId);
    if (i >= 0) {
      all[i] = p;
    } else {
      all.add(p);
    }
    await _write(all);
  }

  Future<void> remove(String projectId) async {
    final all = list().where((x) => x.projectId != projectId).toList();
    await _write(all);
  }

  Future<void> _write(List<AbProject> all) async {
    await _prefs.setString(
      _key,
      jsonEncode(all.map((x) => x.toJson()).toList()),
    );
  }
}
