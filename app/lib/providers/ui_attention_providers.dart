import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/agent_focus_coordinator.dart';
import 'providers.dart';
import 'value_controller.dart';

/// Current app lifecycle, mirrored from `workspace_shell`'s
/// `didChangeAppLifecycleState`. Defaults to resumed.
final appLifecycleStateProvider =
    NotifierProvider<ValueController<AppLifecycleState>, AppLifecycleState>(
      () => ValueController(AppLifecycleState.resumed),
    );

/// Whether the agent terminal surface is currently on screen. Always true on
/// desktop (the agent panel is part of the persistent 3-zone layout); on mobile
/// it tracks the PageView (true only while the agent page is showing). Mirrored
/// from `workspace_shell`.
final agentSurfaceVisibleProvider =
    NotifierProvider<ValueController<bool>, bool>(() => ValueController(true));

enum WorkbenchSurface { workspace, newSession, appSettings, remoteDevices }

/// The top-level workbench surface rendered beside the project drawer.
final workbenchSurfaceProvider =
    NotifierProvider<ValueController<WorkbenchSurface>, WorkbenchSurface>(
      () => ValueController(WorkbenchSurface.workspace),
    );

/// Holds the single [AgentFocusCoordinator] instance. Kept in its own provider
/// so it survives every rebuild of [agentFocusBinderProvider] — the coordinator
/// is stateful (dedups repeat views and blurs the previously-viewed terminal),
/// so it must NOT be reconstructed each time a dependency changes.
final _agentFocusCoordinatorProvider = Provider<AgentFocusCoordinator>(
  (ref) => AgentFocusCoordinator(),
);

/// Keep-alive binder: watches lifecycle + surface visibility + the focused
/// agent terminal and drives [AgentFocusCoordinator]. The viewed terminal is
/// the focused project's running agent terminal, but only while the app is
/// resumed AND the agent surface is on screen.
///
/// Watched from `AppShell`, which outlives the New Session ↔ workspace route
/// swap. A listener that unmounts leaves this keep-alive binder stale, and the
/// remount's first `watch` then flushes it — and its terminal dependencies —
/// from inside build(), which crashes; see the comment at the watch site.
///
/// Uses `watch`, not `listen` + imperative `read`: a `read` of a dependency
/// that is dirty mid-frame (e.g. `agentTerminalProvider` during a project
/// switch) would force a nested synchronous rebuild if it fired inside a
/// `listen` callback triggered by a synchronous `Notifier.set` (lifecycle /
/// surface change) — Riverpod rejects that with "rebuilt multiple times in the
/// same frame". Watching lets the scheduler batch this recompute instead.
final agentFocusBinderProvider = Provider<void>((ref) {
  final coordinator = ref.watch(_agentFocusCoordinatorProvider);
  final resumed =
      ref.watch(appLifecycleStateProvider) == AppLifecycleState.resumed;
  final onScreen = ref.watch(agentSurfaceVisibleProvider);
  final tab = ref.watch(agentTerminalProvider);
  final active = resumed && onScreen && tab != null;
  coordinator.setViewed(
    active ? tab.ghostty : null,
    active ? tab.ghostty.setFocused : null,
  );
});
