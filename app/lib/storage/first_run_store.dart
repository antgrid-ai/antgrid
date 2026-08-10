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
    this.handlerArmedOnce = false,
    this.handlerAwayHintDismissed = false,
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

  /// True once the user has ever armed Handler — any session, any platform.
  /// Cross-project app-install discovery state (shield label collapse,
  /// explainer/away-hint suppression, checklist step), NOT handler config —
  /// which is why it lives here and not in the bridge's HandlerState.
  final bool handlerArmedOnce;

  /// Global kill for the away-moment hint once the user closes it — it must
  /// never nag across sessions or projects.
  final bool handlerAwayHintDismissed;

  FirstRunState copyWith({
    bool? checklistDismissed,
    bool? checklistCompleted,
    Set<String>? completedSteps,
    bool? nudgeSoftDismissed,
    bool? nudgeDeviceDismissed,
    bool? handlerArmedOnce,
    bool? handlerAwayHintDismissed,
  }) => FirstRunState(
    checklistDismissed: checklistDismissed ?? this.checklistDismissed,
    checklistCompleted: checklistCompleted ?? this.checklistCompleted,
    completedSteps: completedSteps ?? this.completedSteps,
    nudgeSoftDismissed: nudgeSoftDismissed ?? this.nudgeSoftDismissed,
    nudgeDeviceDismissed: nudgeDeviceDismissed ?? this.nudgeDeviceDismissed,
    handlerArmedOnce: handlerArmedOnce ?? this.handlerArmedOnce,
    handlerAwayHintDismissed:
        handlerAwayHintDismissed ?? this.handlerAwayHintDismissed,
  );

  Map<String, dynamic> toJson() => {
    'checklistDismissed': checklistDismissed,
    'checklistCompleted': checklistCompleted,
    'completedSteps': completedSteps.toList(),
    'nudgeSoftDismissed': nudgeSoftDismissed,
    'nudgeDeviceDismissed': nudgeDeviceDismissed,
    'handlerArmedOnce': handlerArmedOnce,
    'handlerAwayHintDismissed': handlerAwayHintDismissed,
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
      handlerArmedOnce: flag(j['handlerArmedOnce']),
      handlerAwayHintDismissed: flag(j['handlerAwayHintDismissed']),
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
