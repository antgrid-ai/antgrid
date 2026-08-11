import 'package:antgrid/widgets/ab_banner.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:antgrid/window/window_capabilities.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  testWidgets('the title bar sits above AbBanner', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpWorkspaceShell(tester);

      final barY = tester.getTopLeft(find.byType(WindowTitleBar)).dy;
      final bannerY = tester.getTopLeft(find.byType(AbBanner)).dy;
      // AppKit positions the traffic lights in window coordinates, so nothing
      // may occupy vertical space above the bar or they strand over it.
      expect(barY, lessThan(bannerY));
      expect(barY, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the title bar survives the no-project route', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpWorkspaceShell(tester, withProject: false);

      // With no project focused AppShell routes to NewSessionScreen instead of
      // WorkspaceShell. The OS bar is hidden process-wide, so a route that
      // drops the bar leaves the window with no drag region and no close
      // button — the state a fresh install opens in.
      expect(find.byType(WindowTitleBar), findsOneWidget);
      expect(tester.getTopLeft(find.byType(WindowTitleBar)).dy, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // A touch device is >=600px wide too — an iPad always, a phone in landscape —
  // so it takes the same branch as a desktop window while having system insets
  // a window never has. Only a view padding exposes this: on the desktop
  // platforms the whole geometry collapses back to the dy == 0 cases above, so
  // nothing a developer runs locally can catch it. The left inset stands in for
  // a landscape cutout, which sits beside the bar's brand mark and back button.
  testWidgets('system insets clear the bar without gapping under it', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.physicalSize = const Size(1024, 1366);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(
        top: 24,
        left: 59,
        bottom: 20,
      );
      addTearDown(tester.view.reset);

      await pumpWorkspaceShell(tester);

      final bar = find.byType(WindowTitleBar);
      final barBottom = tester.getBottomLeft(bar).dy;

      // Below the status bar and clear of the cutout, not under either.
      expect(tester.getTopLeft(bar).dy, 24.0);
      expect(tester.getTopLeft(bar).dx, 59.0);
      expect(barBottom, 24.0 + titleBarHeight);
      // Flush against the bar. WorkspaceShell wraps itself in its own SafeArea,
      // so if the shell's inset stops being consumed from the MediaQuery it
      // hands down, this re-inserts the full top inset as a dead gap.
      expect(tester.getTopLeft(find.byType(AbBanner)).dy, barBottom);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
