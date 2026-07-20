import 'dart:async';

import 'package:flutter/widgets.dart';

import 'project_session_registry.dart';

/// Watches [AppLifecycleState] transitions and demotes non-focused warm
/// projects after the app has been backgrounded for [backgroundDemoteDelay].
///
/// On `paused` / `detached` / `hidden`, schedules a one-shot timer. On fire,
/// every project in [registry.openProjects] except the one returned by
/// [focusedProjectId] is force-evicted (which both removes it from the warm
/// set and fires the registry's eviction callback so the session is closed
/// and its status is flushed to disk). Resuming (or going `inactive`) before
/// the timer fires cancels the demote.
class MobileLifecycleObserver {
  final ProjectSessionRegistry registry;
  final String? Function() focusedProjectId;
  final Duration backgroundDemoteDelay;

  Timer? _demoteTimer;

  MobileLifecycleObserver({
    required this.registry,
    required this.focusedProjectId,
    required this.backgroundDemoteDelay,
  });

  void handleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _scheduleDemote();
        break;
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        _cancelDemote();
        break;
    }
  }

  void _scheduleDemote() {
    _demoteTimer?.cancel();
    _demoteTimer = Timer(backgroundDemoteDelay, _demoteAll);
  }

  void _cancelDemote() {
    _demoteTimer?.cancel();
    _demoteTimer = null;
  }

  void _demoteAll() {
    final focused = focusedProjectId();
    for (final id in registry.openProjects.toList()) {
      if (id == focused) continue;
      registry.forceEvict(id);
    }
  }

  void dispose() {
    _demoteTimer?.cancel();
    _demoteTimer = null;
  }
}
