import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import 'local_agent_launcher.dart';

/// Tears down the app-spawned bridge host when the app exits, so the
/// machine-level host daemon doesn't outlive the app window.
///
/// Hooks [WidgetsBindingObserver.didRequestAppExit] — the desktop exit signal
/// (window close, Cmd/Alt+F4, Quit). Mobile has no local host (ownedHostPid
/// stays null), so this is effectively desktop-only.
///
/// This is the FAST, graceful path only. It does NOT fire on a force-kill,
/// crash, power loss, or (observed) a window close under `flutter run --machine`
/// — for all of those the host's own owner-watchdog (it polls the `ownerPid`
/// we pass in the bootstrap and self-exits when we die; see
/// bridge/src/owner-watchdog.ts) is the backstop, plus the host's
/// prune-on-load self-heal on the next launch.
class HostTeardownObserver with WidgetsBindingObserver {
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // Best-effort and owned-only; never block exit on a teardown failure.
    try {
      await LocalAgentLauncher.sharedHost.shutdownOwnedHost();
    } catch (_) {
      // ignore — exiting regardless
    }
    return AppExitResponse.exit;
  }
}
