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

/// Sized off the search field it centres, not the shared dense-row token: the
/// field ([AbTokens.rowHeightXs], the floor its own clear button needs) gets a
/// symmetric [AbTokens.space6] margin top and bottom — deliberately more than
/// the bar's icon buttons sit at, because a 4px margin here read as no margin
/// at all once the field's own border and fill were in the picture. VS Code's
/// command box floats with visibly dark bar showing above and below it; this
/// is what makes that margin actually read at a glance instead of only
/// measuring correctly.
double get titleBarHeight => AbTokens.rowHeightXs + AbTokens.space6 * 2;
