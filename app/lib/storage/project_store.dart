import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'scoped_prefs.dart';

import '../config/storage_scope.dart';
import '../demo/demo_identity.dart';
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

  /// Returns false when the write was refused, so a caller that would re-read
  /// the list afterwards can skip a decode that cannot have changed anything.
  Future<bool> upsert(AbProject p) async {
    // The sample project reaches every path a real one does — opening its
    // drawer row records a focus, and that records an open. Persisted, it
    // outlives the demo as a row that names no folder and can never be opened
    // again. Refused here rather than at each caller: this is the one write.
    if (isDemoProjectId(p.projectId)) return false;
    final all = list();
    final i = all.indexWhere((x) => x.projectId == p.projectId);
    if (i >= 0) {
      all[i] = p;
    } else {
      all.add(p);
    }
    await _write(all);
    return true;
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
