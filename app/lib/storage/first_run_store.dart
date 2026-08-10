import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/storage_scope.dart';
import 'scoped_prefs.dart';

/// One JSON blob under a single key: the WithCache allowList contract
/// (scoped_prefs.dart) wants one owner per key, and these flags always
/// change together from one surface.
///
/// Deliberately NOT part of `AppSettingsService`: its `reset()` would resurrect
/// onboarding chrome for a user who already dismissed or completed it.
class FirstRunState {
  const FirstRunState({
    this.checklistDismissed = false,
    this.checklistCompleted = false,
    this.completedSteps = const <String>{},
    this.nudgeSoftDismissed = false,
    this.nudgeDeviceDismissed = false,
  });

  final bool checklistDismissed;
  final bool checklistCompleted;

  /// Latched step ids (see FirstRunStepIds in providers/first_run.dart) — a
  /// live signal regressing (offline inventory, disconnected machine) never
  /// un-checks a step.
  final Set<String> completedSteps;

  /// Remote-access nudge flags: defined here (not in the nudge package) so the
  /// nudge never has to migrate this blob.
  final bool nudgeSoftDismissed;
  final bool nudgeDeviceDismissed;

  FirstRunState copyWith({
    bool? checklistDismissed,
    bool? checklistCompleted,
    Set<String>? completedSteps,
    bool? nudgeSoftDismissed,
    bool? nudgeDeviceDismissed,
  }) => FirstRunState(
    checklistDismissed: checklistDismissed ?? this.checklistDismissed,
    checklistCompleted: checklistCompleted ?? this.checklistCompleted,
    completedSteps: completedSteps ?? this.completedSteps,
    nudgeSoftDismissed: nudgeSoftDismissed ?? this.nudgeSoftDismissed,
    nudgeDeviceDismissed: nudgeDeviceDismissed ?? this.nudgeDeviceDismissed,
  );

  Map<String, dynamic> toJson() => {
    'checklistDismissed': checklistDismissed,
    'checklistCompleted': checklistCompleted,
    'completedSteps': completedSteps.toList(),
    'nudgeSoftDismissed': nudgeSoftDismissed,
    'nudgeDeviceDismissed': nudgeDeviceDismissed,
  };

  /// Defensive: any bad field degrades to its default rather than aborting the
  /// whole parse — onboarding chrome must never crash the app over a stale blob.
  static FirstRunState fromJson(Map<String, dynamic> j) {
    bool flag(Object? v) => v is bool && v;
    final steps = j['completedSteps'];
    return FirstRunState(
      checklistDismissed: flag(j['checklistDismissed']),
      checklistCompleted: flag(j['checklistCompleted']),
      completedSteps: steps is List
          ? steps.whereType<String>().toSet()
          : const <String>{},
      nudgeSoftDismissed: flag(j['nudgeSoftDismissed']),
      nudgeDeviceDismissed: flag(j['nudgeDeviceDismissed']),
    );
  }
}

/// SharedPreferences-backed persistence for first-run chrome (setup checklist
/// + remote-access nudge dismissals). Modeled on `DrawerCollapsedStore`:
/// opened eagerly in `main()`, injected via a throwing provider override.
class FirstRunStore {
  static final _key = scopedStorageKey('antgrid.first_run.v1');
  final SharedPreferencesWithCache _prefs;

  FirstRunStore._(this._prefs);

  static Future<FirstRunStore> open() async =>
      FirstRunStore._(await openScopedPrefs({_key}));

  FirstRunState read() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const FirstRunState();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const FirstRunState();
      return FirstRunState.fromJson(decoded);
    } catch (_) {
      return const FirstRunState();
    }
  }

  Future<void> write(FirstRunState s) async {
    await _prefs.setString(_key, jsonEncode(s.toJson()));
  }
}
