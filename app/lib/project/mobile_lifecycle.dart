import 'dart:async';

import 'package:flutter/widgets.dart';

import 'project_session_registry.dart';

/// Watches [AppLifecycleState] transitions and does two things: declares the
/// app's focus state to every open project's agent, and demotes non-focused warm
/// projects after the app has been backgrounded for [backgroundDemoteDelay].
///
/// Focus is declared via [setFocusPaused] the moment the state changes — the
/// agent gates both the heavy stream and the fallback push on it, so waiting for
/// the demote timer would drop the notification for any turn ending inside the
/// delay.
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

  /// Declares each open project's focus state to its agent. Optional so the
  /// eviction tests can omit it.
  final void Function(String projectId, {required bool paused})? setFocusPaused;

  Timer? _demoteTimer;

  MobileLifecycleObserver({
    required this.registry,
    required this.focusedProjectId,
    required this.backgroundDemoteDelay,
    this.setFocusPaused,
  });

  void handleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _setPausedAll(true);
        _scheduleDemote();
        break;
      case AppLifecycleState.resumed:
        _setPausedAll(false);
        _cancelDemote();
        break;
      case AppLifecycleState.inactive:
        // Transient (app switcher, notification shade) and it also precedes both
        // `paused` and `resumed` — so flipping focus here would flap. Only cancel
        // the demote; the terminal state that follows owns the focus flag.
        _cancelDemote();
        break;
    }
  }

  /// Every open project, not just the focused one: backgrounding makes the phone
  /// unable to render any of them, and a turn can end on a warm non-focused
  /// project before the demote timer closes it.
  void _setPausedAll(bool paused) {
    final send = setFocusPaused;
    if (send == null) return;
    for (final id in registry.openProjects.toList()) {
      send(id, paused: paused);
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
