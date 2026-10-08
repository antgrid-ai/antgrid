// On the phone's workspace page a leftward swipe on a changed file opens its
// Stage/Revert tray, and a rightward one goes back to the agent — through the
// real shell, whose PageView and pane flings compete for the same drags.
import 'dart:ui' show GestureSettings;

import 'package:antgrid/widgets/agent_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/workspace_shell_harness.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    Future<void> on(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<void> openGitWithChange(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      // A device's own slop, not the framework default: Android reports its
      // ViewConfiguration value (~8dp) and the PageView's drag reads it.
      tester.view.gestureSettings = const GestureSettings(
        physicalTouchSlop: 8,
      );
      addTearDown(tester.view.reset);
      await pumpWorkspaceShell(
        tester,
        fileTreeStates: Stream.value(oneChangeTree()),
      );
      await settleShell(tester);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await settleShell(tester);
      await tester.tap(find.text('Git').last);
      await settleShell(tester);
      expect(find.text('a.dart'), findsOneWidget);
    }

    // A thumb, not a teleport: many small moves over a real duration.
    Future<void> swipeRow(WidgetTester tester, double dx) => tester.timedDrag(
      find.text('a.dart'),
      Offset(dx, 0),
      const Duration(milliseconds: 300),
    );

    testWidgets('${platform.name}: leftward row swipe opens the tray', (
      tester,
    ) async {
      await on(() async {
        await openGitWithChange(tester);

        await swipeRow(tester, -120);
        await settleShell(tester);

        expect(find.text('Stage'), findsOneWidget);
        expect(find.text('Revert'), findsOneWidget);
      });
    });

    testWidgets('${platform.name}: rightward row swipe goes to the agent', (
      tester,
    ) async {
      await on(() async {
        await openGitWithChange(tester);

        await swipeRow(tester, 250);
        await settleShell(tester);

        expect(find.byType(AgentPanel), findsOneWidget);
        expect(find.text('a.dart'), findsNothing);
      });
    });
  }
}
