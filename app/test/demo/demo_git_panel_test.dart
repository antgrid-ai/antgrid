import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

/// The sample project's Git panel as App Review meets it: an iPad, the
/// sidebar docked, the context pane at its narrowest.
Future<void> openGitOnIpad(WidgetTester tester) async {
  tester.view.physicalSize = const Size(820, 1180);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = await pumpDemoApp(
    tester,
    enterDemo: true,
    size: const Size(820, 1180),
  );
  await settle(tester);
  reveal(container, WorkspaceView.git);
  await settle(tester);
}

/// The demo never goes idle (its agent keeps scripting), so frames are pumped
/// for a bounded while instead of with pumpAndSettle.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void reveal(ProviderContainer container, WorkspaceView view) {
  container.read(workspaceMenuOpenProvider.notifier).set(false);
  container.read(revealWorkspaceViewControlProvider)!.call(view);
}

/// Pull carries how far the branch is behind (`Pull 2`) once there is any.
final _pull = find.textContaining(RegExp(r'^Pull\b'));

void main() {
  testWidgets('the Git panel fits the iPad context pane', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await openGitOnIpad(tester);
      // An overflowing Row reports itself as a test failure on its own; what
      // is left to check is that the labels got a line each to be read on.
      expect(
        tester.getTopLeft(_pull).dy,
        greaterThan(tester.getBottomLeft(find.text('Commit (1)')).dy),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a refused pull explains itself without a failure strip', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await openGitOnIpad(tester);
      await tester.tap(_pull);
      await settle(tester);
      expect(find.textContaining(kDemoRefusalText), findsOneWidget);
      expect(find.textContaining('Pull failed'), findsNothing);
      expect(find.text('Ask agent to fix'), findsNothing);
      // Let the toast expire.
      await tester.pump(const Duration(seconds: 10));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
