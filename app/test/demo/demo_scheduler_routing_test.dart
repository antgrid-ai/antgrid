// The sample Scheduler is only reachable if three separate pieces of routing
// agree: the drawer row must be live, DemoHome must have a body for the
// scheduler surface, and entering must not be undone by enterDemoMode's own
// reset to the workspace surface. Each is pinned here on its own.
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/scheduler_timezone.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/screens/demo_home.dart';
import 'package:antgrid/screens/scheduler_screen.dart';
import 'package:antgrid/screens/workspace_shell.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

// The platform channel behind the real zone provider never answers inside
// FakeAsync, which would leave the sample's seed unresolved forever.
final List<Override> _zone = [
  schedulerLocalTimezoneProvider.overrideWith((_) async => null),
];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('entering lands on the Scheduler, not the workspace', (
    tester,
  ) async {
    final container = await pumpDemoApp(
      tester,
      enterDemo: true,
      extraOverrides: _zone,
    );
    await _settle(tester);
    expect(find.byType(WorkspaceShell), findsOneWidget);

    enterDemoScheduler(container);
    await _settle(tester);

    expect(find.byType(DemoHome), findsOneWidget);
    expect(find.byType(SchedulerScreen), findsOneWidget);
    expect(find.byType(WorkspaceShell), findsNothing);
  });

  testWidgets('Back returns to the workspace with the demo still on', (
    tester,
  ) async {
    final container = await pumpDemoApp(
      tester,
      enterDemo: true,
      extraOverrides: _zone,
    );
    enterDemoScheduler(container);
    await _settle(tester);
    expect(find.byType(SchedulerScreen), findsOneWidget);

    container.read(navControllerProvider.notifier).back();
    await _settle(tester);

    expect(container.read(demoModeProvider), isTrue);
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
    expect(find.byType(SchedulerScreen), findsNothing);
    expect(find.byType(WorkspaceShell), findsOneWidget);
  });

  testWidgets('the drawer row is live inside the sample project', (
    tester,
  ) async {
    final container = await demoContainer(extraOverrides: _zone);
    container.read(demoModeProvider.notifier).set(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const Scaffold(body: ProjectsDrawer()),
        ),
      ),
    );
    await tester.pump();

    final row = find.widgetWithText(AbListRow, 'Scheduler');
    expect(tester.widget<AbListRow>(row).enabled, isTrue);

    await tester.tap(row);
    await tester.pump();
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.scheduler,
    );
  });

  testWidgets('picking the sample machine leaves the real selection alone', (
    tester,
  ) async {
    final container = await pumpDemoApp(
      tester,
      enterDemo: true,
      extraOverrides: _zone,
    );
    enterDemoScheduler(container);
    await _settle(tester);
    expect(container.read(schedulerMachineProvider), isNull);

    await tester.tap(find.text('Sample machine').first);
    await _settle(tester);
    await tester.tap(find.text('Sample machine').last);
    await _settle(tester);

    // A 'local' write here would outlive the demo and null a phone's real
    // Scheduler target after exit.
    expect(container.read(schedulerMachineProvider), isNull);
  });
}
