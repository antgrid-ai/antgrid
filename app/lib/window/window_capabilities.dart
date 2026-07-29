import 'package:flutter/foundation.dart';

import '../design/ab_tokens.dart';

/// Whether the app draws its own title bar (the OS bar is hidden).
///
/// Linux is excluded deliberately: `gtk_window_set_decorated(false)` is inert in
/// GTK 3's Wayland backend, so hiding the OS bar there can leave two stacked
/// bars. Linux ships `TitleBarStyle.normal` until the custom path is verified on
/// real X11 and Wayland hardware — flip this predicate to change that.
bool get appOwnsWindowChrome {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.macOS => true,
    _ => false,
  };
}

/// Whether we paint minimize/maximize/close ourselves.
///
/// macOS keeps its real `NSWindow` traffic lights — hover glyphs, Option-click
/// zoom, and long-press tiling all come free and cannot be reproduced.
bool get paintsWindowControls {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

/// Left padding reserved so bar content clears the macOS traffic lights, which
/// AppKit positions in window coordinates and which float above Flutter content.
///
/// Empirical: `getTitleBarHeight()` returns height only, and there is no API for
/// the button group's width.
double get titleBarLeftInset {
  if (kIsWeb) return 0;
  return defaultTargetPlatform == TargetPlatform.macOS ? 78.0 : 0.0;
}

double get titleBarHeight => AbTokens.rowHeightSm;

/// Below this width the handler control and mobile/host chip are hidden
/// entirely. Neither has another entry point, so between the 640px window
/// minimum and this threshold Handler config and the mobile-access toggle are
/// unreachable — decide whether to drop the threshold or give them a drawer
/// home alongside the deferred 1000px icon-only tier.
const double kTitleBarTierIconOnly = 700;
