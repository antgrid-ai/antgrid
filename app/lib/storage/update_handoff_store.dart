import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// The write half of [UpdateHandoffStore], which is all the install sequence is
/// given: consuming the mark belongs to the launch path alone, and a sequence
/// able to consume it could swallow the announcement it exists to arm.
abstract interface class UpdateHandoffSink {
  /// Records [version] as the build about to be replaced. Written BEFORE the
  /// platform is handed the update: on Windows the call may not return.
  Future<void> markHandoff(String version);

  /// Drops the mark for an install that did not happen, so a later crash
  /// relaunch cannot find it and read it as an update.
  Future<void> clear();
}

/// The app version that was running when an update was handed to the platform.
///
/// `RegisterApplicationRestart` is registered with flags `0`, deliberately:
/// every `RESTART_NO_*` bit subtracts a case Windows would otherwise relaunch
/// us for, and which bit governs an MSIX servicing restart is not something we
/// can establish short of shipping one. Keeping all of them means a crash, a
/// hang and a reboot-to-patch each relaunch with the same `--after-update`
/// argument, so that argument alone is not evidence an update happened —
/// announcing one on it would tell a user who had just crashed that they were
/// updated.
///
/// A version written at hand-off and compared against the running build on the
/// next launch IS evidence: only a package replacement can change it. That
/// holds whichever restart reason fired, which is what makes it preferable to
/// narrowing the flags and hoping the update case survives.
class UpdateHandoffStore implements UpdateHandoffSink {
  static final _key = scopedStorageKey('antgrid.update_handoff_version.v1');
  final SharedPreferencesWithCache _prefs;

  UpdateHandoffStore._(this._prefs);

  static Future<UpdateHandoffStore> open() async =>
      UpdateHandoffStore._(await openScopedPrefs({_key}));

  @override
  Future<void> markHandoff(String version) => _prefs.setString(_key, version);

  @override
  Future<void> clear() => _prefs.remove(_key);

  /// Returns the replaced version when [current] differs from the mark, else
  /// null. Always clears, so an announcement can fire at most once.
  ///
  /// A mark NEWER than the running build is a rollback, not an update — easy
  /// to reach on Linux, where installing an older AppImage is a file copy —
  /// and announcing an update to the older build would be plainly wrong.
  Future<String?> consume(String current) async {
    final previous = _prefs.getString(_key);
    if (previous == null) return null;
    await clear();
    if (previous == current) return null;
    if (isRollback(from: previous, to: current)) return null;
    return previous;
  }
}

/// Whether moving [from] → [to] went backwards.
///
/// Versions are CalVer (`<major>.<days since epoch>.<run>`), so a field-wise
/// numeric compare orders them. Anything unparseable — a local `dev` build,
/// a format that outlives this function — is not provably anything and answers
/// false: swallowing a real update's announcement is the worse of the two
/// mistakes, and the caller has already established the versions differ.
@visibleForTesting
bool isRollback({required String from, required String to}) {
  final a = _calverFields(from);
  final b = _calverFields(to);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

List<int>? _calverFields(String version) {
  final parts = version.split('.');
  if (parts.length < 3) return null;
  final fields = <int>[];
  for (final part in parts.take(3)) {
    final value = int.tryParse(part.trim());
    if (value == null) return null;
    fields.add(value);
  }
  return fields;
}
