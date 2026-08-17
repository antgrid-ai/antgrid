import 'package:antgrid/widgets/ab_banner.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
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

  // A touch device (Android/iOS) never mounts the title bar, at ANY width —
  // even a large tablet in landscape, e.g. this 1024px iPad, which used to
  // take the same title-bar branch as a desktop window (that was the bug: a
  // wide Android tablet still showing the desktop chrome). Unlike a mouse
  // desktop window, which has no system insets to clear, a touch device's own
  // status bar/cutout still needs to be consumed by SOMETHING — with no title
  // bar to do it (app_shell.dart's `routed` branch skips straight past),
  // WorkspaceShell's own SafeArea is what's left holding that job. Only a view
  // padding exposes this: on desktop platforms every inset is already zero, so
  // nothing a developer runs locally can catch a regression here. The left
  // inset stands in for a landscape cutout — set here (exercising the layout
  // under it) even though only the top inset is asserted below.
  testWidgets(
    'a touch tablet gets no title bar, and its own SafeArea clears system insets',
    (tester) async {
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

        expect(find.byType(WindowTitleBar), findsNothing);
        // Below the status bar, not under it — WorkspaceShell's own SafeArea
        // is what consumes the top inset here; a regression would leave this
        // flush at 0.0 (under the status bar) instead.
        expect(tester.getTopLeft(find.byType(AbBanner)).dy, 24.0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
