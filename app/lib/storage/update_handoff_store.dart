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
  Future<String?> consume(String current) async {
    final previous = _prefs.getString(_key);
    if (previous == null) return null;
    await clear();
    return previous == current ? null : previous;
  }
}
