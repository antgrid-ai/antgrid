import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'window_capabilities.dart';

/// Never `setAsFrameless()`: on macOS it hides the whole title bar view, which
/// destroys the traffic lights along with it.
TitleBarStyle desktopTitleBarStyle() =>
    appOwnsWindowChrome ? TitleBarStyle.hidden : TitleBarStyle.normal;

/// Applies window chrome before the first frame. No-op off desktop.
///
/// The width floor exists because `isMobile` in workspace_shell keys off
/// window width: narrower than [kCompactBreakpoint] (600) the desktop layout
/// swaps to the mobile one, which would leave a chrome-less window with no
/// close button. 640 rather than exactly 600 so fractional-DPI logical widths
/// can never dip below the breakpoint.
Future<void> initDesktopWindowChrome() async {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.linux) {
    return;
  }
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(
    desktopTitleBarStyle(),
    windowButtonVisibility: true,
  );
  await windowManager.setMinimumSize(const Size(640, 400));
}

/// Window actions, behind an interface so widget tests never touch `dart:io`.
abstract class WindowChrome {
  Future<void> startDragging();
  Future<void> startResizingTop();
  Future<void> toggleMaximize();
  Future<void> minimize();
  Future<void> close();
  Future<void> popUpWindowMenu();
}

class _RealWindowChrome implements WindowChrome {
  const _RealWindowChrome();

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> startResizingTop() =>
      windowManager.startResizing(ResizeEdge.top);

  @override
  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> popUpWindowMenu() => windowManager.popUpWindowMenu();
}

@visibleForTesting
class FakeWindowChrome implements WindowChrome {
  final List<String> calls = [];

  @override
  Future<void> startDragging() async => calls.add('startDragging');

  @override
  Future<void> startResizingTop() async => calls.add('startResizingTop');

  @override
  Future<void> toggleMaximize() async => calls.add('toggleMaximize');

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> popUpWindowMenu() async => calls.add('popUpWindowMenu');
}

final windowChromeProvider = Provider<WindowChrome>(
  (ref) => const _RealWindowChrome(),
);

/// Drives the maximize/restore icon. The notifier registers its own
/// [WindowListener] the first time anything watches it — no separate wiring
/// step in main(), so the glyph can never silently go stale because a
/// registration call was forgotten.
final windowMaximizedProvider = NotifierProvider<WindowMaximizedNotifier, bool>(
  WindowMaximizedNotifier.new,
);

class WindowMaximizedNotifier extends Notifier<bool> {
  @override
  bool build() {
    // addListener is pure Dart (no platform channel), so this is safe in
    // widget tests that don't override the provider. Guarded anyway: only the
    // platforms that draw our controls ever need the state.
    if (!kIsWeb && appOwnsWindowChrome) {
      final listener = _WindowMaximizedListener(this);
      windowManager.addListener(listener);
      ref.onDispose(() => windowManager.removeListener(listener));
    }
    return false;
  }

  // `state` is protected to Notifier subclasses, so the listener (which isn't
  // one) goes through this method rather than assigning `notifier.state`
  // directly.
  void _setMaximized(bool maximized) => state = maximized;
}

/// Keeps [windowMaximizedProvider] truthful without polling.
class _WindowMaximizedListener extends WindowListener {
  _WindowMaximizedListener(this._notifier);

  final WindowMaximizedNotifier _notifier;

  @override
  void onWindowMaximize() => _notifier._setMaximized(true);

  @override
  void onWindowUnmaximize() => _notifier._setMaximized(false);
}

/// Test override: `windowMaximizedProvider.overrideWith(() =>
/// FixedWindowMaximized(true))`. Skips listener registration entirely.
@visibleForTesting
class FixedWindowMaximized extends WindowMaximizedNotifier {
  FixedWindowMaximized(this._fixed);

  final bool _fixed;

  @override
  bool build() => _fixed;
}
