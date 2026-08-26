import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/breakpoints.dart';
import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_window_controls.dart';
import '../providers/demo_mode.dart';
import '../utils/platform_utils.dart';
import '../window/window_capabilities.dart';
import 'window_title_bar.dart';

/// The strip that says "this is not your machine", wrapped around every route
/// while the demo is on.
///
/// Mounted from `MaterialApp.builder` rather than from a screen so it survives
/// every route the demo can reach (settings, new session, a pushed terminal) —
/// there is no surface where the sample data can be seen without it.
class DemoFrame extends ConsumerWidget {
  const DemoFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Toggling this REPARENTS the app's Navigator (the builder's `child`) under
    // the Column; it does not tear it down. `WidgetsApp` gives that Navigator a
    // GlobalKey, which is precisely what carries a subtree — routes and all —
    // across a move with its state intact. So nothing here unwinds a dialog
    // opened over the sample project: `enterDemoMode`/`exitDemoMode` pop the
    // stack on both edges, and that is the only thing standing between a demo
    // modal and the real app underneath it.
    if (!ref.watch(demoModeProvider)) return child;
    // The same three-way rule AppShell applies (`_buildRoot`), not a second one
    // that only happens to agree at phone width. The demo mounts WorkspaceShell
    // and NewSessionScreen, both of which publish their pane toggles through
    // `sidebarControlProvider`/`contextPanelControlProvider` for a bar mounted
    // ABOVE the route to render — and those toggles are the only way back from
    // a hidden drawer or a hidden/expanded context panel. A chrome-only bar at
    // desktop width therefore drops a reviewer whose `sidebarHidden` setting is
    // already on into a demo with no project drawer and nothing to restore it.
    final narrow = MediaQuery.sizeOf(context).width < kMediumBreakpoint;
    final showTitleBar = !isMobilePlatform && (appOwnsWindowChrome || !narrow);
    // Everything below is a SIBLING of the app's Navigator, which owns the only
    // Overlay in the tree — so the caption buttons' tooltips, which are
    // `OverlayPortal`s and throw at BUILD time rather than on hover, have none.
    // Wrapping the whole frame instead of just the bar: an Overlay sized to the
    // bar would clip the tooltip it exists to host, since a tooltip on a title
    // bar opens downward into the routes below.
    return Overlay.wrap(
      child: Column(
        children: [
          // The demo mounts WorkspaceShell alone, not AppShell, so nothing else
          // draws the bar the OS one was hidden for — without this the demo
          // window has no drag region and no close button. Above the strip, since
          // AppKit positions the macOS traffic lights in window coordinates and
          // they do not move with Flutter layout.
          if (showTitleBar)
            WindowTitleBar(
              child: narrow
                  ? const Row(children: [Spacer(), AbWindowControls()])
                  : const WindowTitleBarContents(),
            ),
          const SafeArea(bottom: false, child: _DemoBanner()),
          Expanded(
            // The strip already consumed the status-bar inset; each route's own
            // SafeArea would otherwise inset past it a second time.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _DemoBanner extends ConsumerWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.antgrid;
    return DefaultTextStyle(
      // Above every route the ambient style is WidgetsApp's red-on-yellow error
      // style, which `Text.style` merges with rather than replaces.
      style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
      child: AbInlineBanner(
        text: 'Demo — sample data, not a real machine. Nothing is connected.',
        color: colors.warning,
        trailing: AbButton(
          label: 'Exit demo',
          compact: true,
          leading: AbIcon(
            AbIcons.close,
            size: AbTokens.iconButtonGlyph,
            color: colors.textSecondary,
          ),
          onTap: () => exitDemoMode(ref.container),
        ),
      ),
    );
  }
}
