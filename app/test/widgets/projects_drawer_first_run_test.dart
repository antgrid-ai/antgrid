// Pins the setup checklist's HOME. first_run_checklist_test.dart pumps
// FirstRunSetupSection on its own, and the other ProjectsDrawer tests run on
// flutter_test's android default where the section shrinks to nothing — so
// without this file, deleting the checklist from the drawer (or docking it
// below the account footer) breaks nothing in the suite.
//
// The drawer is the only desktop surface mounted on BOTH routes, which is the
// whole reason the checklist lives here rather than on the New Session canvas.
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/account_footer.dart';
import 'package:antgrid/widgets/first_run_checklist.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  Widget buildDrawer() => ProviderScope(
    overrides: [
      ...stores.overrides,
      accountAgentsProvider.overrideWith((_) async => <InventoryAgent>[]),
      currentUserProvider.overrideWith((_) async => null),
      desktopFirstRunStepsProvider.overrideWith(
        (_) => const [
          (id: FirstRunStepIds.signIn, label: 'Sign in', done: true),
          (id: FirstRunStepIds.openProject, label: 'Open a project', done: false),
        ],
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
  );

  testWidgets('the desktop drawer docks the setup checklist between the '
      'project list and the account footer', (tester) async {
    // Cleared before the body ends, not in tearDown: flutter_test asserts every
    // foundation debug var is unset the moment the body returns.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    expect(find.byType(FirstRunSetupSection), findsOneWidget);
    expect(find.text('SETUP · 1/2'), findsOneWidget);

    // Docked, not floating in the list: below the scrollable body, above the
    // account footer. UpdateRow sits between them but only renders while an
    // update is pending, so it is not part of the contract.
    final section = tester.getTopLeft(find.byType(FirstRunSetupSection)).dy;
    expect(section, greaterThan(tester.getTopLeft(find.byType(ListView)).dy));
    expect(
      section,
      lessThan(tester.getTopLeft(find.byType(AccountFooter)).dy),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a dismissed checklist leaves the drawer with no setup section', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip("Dismiss — won't show again"));
    await tester.pumpAndSettle();

    expect(find.byType(FirstRunSetupSection), findsOneWidget);
    expect(find.textContaining('SETUP'), findsNothing);
    expect(find.byType(AccountFooter), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
