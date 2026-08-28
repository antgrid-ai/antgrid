import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import 'host_controller.dart';
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
  /// [host] and [budget] are test seams; production uses the shared host and
  /// the real ceiling.
  HostTeardownObserver({HostController? host, Duration? budget})
    : _host = host ?? LocalAgentLauncher.sharedHost,
      _budget = budget ?? _defaultBudget;

  final HostController _host;
  final Duration _budget;

  /// Backstops `shutdownOwnedHost`'s own internal budget (a 2s control-plane
  /// call, a 3s wait for a graceful exit, then a bounded force-kill), leaving
  /// headroom without doubling it.
  ///
  /// The bound is not decoration. On macOS this observer is the WHOLE update
  /// story: Sparkle installs by quitting the app — `[NSApp terminate:]`, which
  /// `FlutterAppDelegate.applicationShouldTerminate` turns into this callback —
  /// and then waits on the process before swapping the bundle. Without a
  /// ceiling a wedged host doesn't just delay the quit, it stalls the update
  /// standing behind it. Nothing else on that platform gets a look in: the one
  /// pre-quit hook the Sparkle plugin exposes (`onUpdaterBeforeQuitForUpdate`)
  /// fires only for silent install-on-quit after an automatic background
  /// download, which `SUEnableAutomaticChecks` turns off.
  static const _defaultBudget = Duration(seconds: 10);

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // Best-effort and owned-only; never block exit on a teardown failure.
    try {
      await _host.shutdownOwnedHost().timeout(_budget);
    } catch (_) {
      // ignore — exiting regardless
    }
    return AppExitResponse.exit;
  }
}
