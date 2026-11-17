// The workspace tab strip is a Carbon surface: nothing under its scope may
// build an Ab widget, in either density or brightness, and its height is the
// one the agent bar copies to sit flush across the resizable divider.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Map<WorkspaceView, int> badges = const {},
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      visibleWorkspaceViewsProvider.overrideWithBuild(
        (_, _) => WorkspaceView.values,
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 640,
            child: WorkspaceTabBar(
              selected: WorkspaceView.git,
              onSelected: (_) {},
              badges: badges,
              onToggleExpand: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      testWidgets('builds no Ab widget under its scope '
          '(${platform.name}, ${brightness.name})', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await _pump(
            tester,
            brightness: brightness,
            badges: const {WorkspaceView.handler: 3},
          );

          expect(find.byType(AbCarbonScope), findsOneWidget);
          expect(abWidgetsInScope(tester), isEmpty);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  // 40 on desktop and the 44 finger target on touch, plus the hairline: the
  // agent bar reads the same number, so the two tops and bottoms line up.
  for (final (platform, expected) in [
    (TargetPlatform.windows, 41.0),
    (TargetPlatform.android, 45.0),
  ]) {
    testWidgets('the strip is $expected tall on ${platform.name}', (
      tester,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = platform;
        await _pump(tester);

        expect(workspaceStripHeight, expected);
        expect(tester.getSize(find.byType(WorkspaceTabBar)).height, expected);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
