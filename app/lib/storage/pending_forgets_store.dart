import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// SharedPreferences-backed set of local project ids whose delete has been
/// applied locally but not yet confirmed forgotten by the host.
///
/// `ProjectsNotifier.remove` asks the host to forget a project best-effort
/// (`_forgetOnHost`), swallowing a failure so a slow/unreachable host never
/// blocks the delete. Left at that, a project the host never actually forgot
/// resurrects: `backfillFromHost` merges the host's own seen-catalog back into
/// the local list, and on desktop that runs on a 2s poll — so a host that was
/// still mid-forget (or briefly unreachable) at delete time re-adds the row
/// within seconds, and a host that stayed unreachable resurrects it on every
/// later launch until a delete happens to coincide with a live host. This
/// store is the guard: an id here is skipped by every `backfillFromHost` merge
/// regardless of what the host reports, and the same call opportunistically
/// retries the forget and drops the id once the host confirms it.
class PendingForgetsStore {
  static final _key = scopedStorageKey('antgrid.pending_forgets.v1');
  final SharedPreferencesWithCache _prefs;

  PendingForgetsStore._(this._prefs);

  static Future<PendingForgetsStore> open() async =>
      PendingForgetsStore._(await openScopedPrefs({_key}));

  Set<String> read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const <String>{};
    final arr = jsonDecode(raw) as List;
    return arr.map((e) => e as String).toSet();
  }

  Future<void> add(String id) async {
    // `read()` can return the unmodifiable `const <String>{}` — copy into a
    // fresh mutable set rather than mutating it in place.
    final ids = {...read()};
    if (!ids.add(id)) return;
    await _write(ids);
  }

  Future<void> remove(String id) async {
    final ids = {...read()};
    if (!ids.remove(id)) return;
    await _write(ids);
  }

  Future<void> _write(Set<String> ids) =>
      _prefs.setString(_key, jsonEncode(ids.toList()));
}
