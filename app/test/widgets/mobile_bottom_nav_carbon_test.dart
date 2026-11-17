// The phone's bottom bar is a Carbon surface: nothing under its scope may
// build an Ab widget in either density or brightness, and every item keeps the
// finger target.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/mobile_bottom_nav.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  WorkspaceView selected = WorkspaceView.git,
  ValueChanged<WorkspaceView>? onSelected,
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
          alignment: Alignment.bottomCenter,
          child: MobileBottomNav(
            selected: selected,
            onSelected: onSelected ?? (_) {},
            badges: badges,
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

  for (final (platform, expected) in [
    (TargetPlatform.windows, 44.0),
    (TargetPlatform.android, 56.0),
  ]) {
    testWidgets('the bar is $expected tall and every item reaches 44 on '
        '${platform.name}', (tester) async {
      try {
        debugDefaultTargetPlatformOverride = platform;
        await _pump(tester);

        final bar = tester.getSize(find.byType(MobileBottomNav));
        expect(bar.height, expected);
        final target = tester.getSize(
          find
              .ancestor(
                of: find.text('Files'),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(target.width, greaterThanOrEqualTo(44));
        // The bar's 1 px top border is laid out outside the item.
        expect(target.height, inInclusiveRange(expected - 1, expected));
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a tap selects, and a re-tap on the open view still reports', (
    tester,
  ) async {
    final taps = <WorkspaceView>[];
    await _pump(tester, onSelected: taps.add);

    await tester.tap(find.text('Files'));
    await tester.tap(find.text('Git'));
    expect(taps, [WorkspaceView.files, WorkspaceView.git]);
  });
}
