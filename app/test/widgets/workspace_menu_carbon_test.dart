// The workspace rail is a Carbon surface: nothing under its scope may build an
// Ab widget, in either density or brightness, while the trigger beside it stays
// Ab chrome outside any scope.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/widgets/workspace_menu_button.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(WidgetTester tester, {required Brightness brightness}) {
  final container = ProviderContainer(
    overrides: [
      workspaceMenuControlProvider.overrideWith(
        () => ValueController<WorkspaceMenuControl?>((
          active: WorkspaceView.git,
          reveal: (_) {},
        )),
      ),
      workspaceBadgesProvider.overrideWith(
        (ref) => const {WorkspaceView.handler: 3},
      ),
      visibleWorkspaceViewsProvider.overrideWithBuild(
        (_, _) => WorkspaceView.values,
      ),
      gitDiffTotalsProvider.overrideWith(
        (ref) => (additions: 12, deletions: 4),
      ),
      workspaceMenuOpenProvider.overrideWith(() => ValueController(true)),
    ],
  );
  addTearDown(container.dispose);
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        themeAnimationDuration: Duration.zero,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: WorkspaceMenuButton(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      testWidgets('builds no Ab widget under its scope '
          '(${platform.name}, ${brightness.name})', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await _pump(tester, brightness: brightness);
          await tester.pump();

          final scope = find.descendant(
            of: find.byType(WorkspaceMenuPanel),
            matching: find.byType(AbCarbonScope),
          );
          expect(scope, findsOneWidget);
          expect(abWidgetsInScope(tester, scope: scope), isEmpty);
          // The trigger is Ab chrome and sits outside the rail's scope.
          expect(
            find.descendant(of: scope, matching: find.byType(AbIconButton)),
            findsNothing,
          );
          expect(find.byType(AbIconButton), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}
