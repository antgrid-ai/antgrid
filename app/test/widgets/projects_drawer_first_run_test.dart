// Pins the setup checklist's HOME. first_run_checklist_test.dart pumps
// FirstRunSetupSection on its own, and the other ProjectsDrawer tests run on
// flutter_test's android default where the section shrinks to nothing — so
// without this file, deleting the checklist from the drawer (or docking it
// below the account footer) breaks nothing in the suite.
//
// The drawer is the only desktop surface mounted on BOTH routes, which is the
// whole reason the checklist lives here rather than on the New Session canvas.
import 'package:antgrid/design/widgets/ab_docked_column.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/account_footer.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
import 'package:antgrid/widgets/first_run_checklist.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

/// The two-step fixture most tests here want — short enough that the drawer
/// never has to compress anything.
const _shortSteps = [
  (id: FirstRunStepIds.signIn, label: 'Sign in', done: true),
  (id: FirstRunStepIds.openProject, label: 'Open a project', done: false),
];

/// The full desktop checklist: the tallest the dock ever gets, and the height
/// that overflowed the Column this layout replaced.
const _allSteps = [
  (id: FirstRunStepIds.signIn, label: 'Sign in', done: true),
  (id: FirstRunStepIds.openProject, label: 'Open a project', done: false),
  (id: FirstRunStepIds.startSession, label: 'Start a session', done: false),
  (id: FirstRunStepIds.connectPhone, label: 'Connect your phone', done: false),
  (id: FirstRunStepIds.armHandler, label: 'Arm Handler', done: false),
];

DrawerEntry _project(String id) => LocalProjectEntry(
  AbProject(
    projectId: id,
    folder: 'C:/repos/$id',
    displayName: id,
    hostDeviceUuid: null,
    hostMachineName: 'this-machine',
    lastOpenedAt: DateTime(2026, 1, 1),
  ),
);

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

  Widget buildDrawer({
    List<({String id, String label, bool done})> steps = _shortSteps,
    List<DrawerEntry> entries = const [],
    double uiScale = 1.0,
  }) => ProviderScope(
    overrides: [
      ...stores.overrides,
      accountAgentsProvider.overrideWith((_) async => <InventoryAgent>[]),
      currentUserProvider.overrideWith((_) async => null),
      drawerEntriesProvider.overrideWithValue(entries),
      desktopFirstRunStepsProvider.overrideWith((_) => steps),
    ],
    child: MaterialApp(
      home: const Scaffold(body: ProjectsDrawer()),
      // Desktop applies the UI-scale setting as a text scaler and nothing else
      // (main.dart:344), so this is the whole of what "Large" does to the
      // drawer's chrome.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(uiScale)),
        child: child!,
      ),
    ),
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
    expect(section, lessThan(tester.getTopLeft(find.byType(AccountFooter)).dy));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the worst case the app can actually reach — a 400px window at '
      'the largest UI scale, full checklist, projects listed — scrolls the '
      'checklist instead of overflowing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 400 is the app's own floor (window_chrome.dart calls setMinimumSize with
    // Size(640, 400)) and 1.30 is the largest UI-scale step that ships
    // (app_settings_screen.dart). Anything shorter than this is unreachable, so
    // this is the size the layout has to survive.
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildDrawer(
        steps: _allSteps,
        entries: [_project('alpha'), _project('beta')],
        uiScale: 1.30,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // Still docked: below the project rows, above the account footer — which is
    // pinned and therefore whole, not scrolled away with the checklist.
    final section = tester.getTopLeft(find.byType(FirstRunSetupSection)).dy;
    expect(
      section,
      greaterThan(tester.getTopLeft(find.byType(DrawerEntryRow).first).dy),
    );
    expect(section, lessThan(tester.getTopLeft(find.byType(AccountFooter)).dy));
    expect(tester.getSize(find.byType(AccountFooter)).height, 45);

    // The point of the dock: its viewport is shorter than the checklist inside
    // it, so the overflow became a scroll.
    final viewport = find.ancestor(
      of: find.byType(FirstRunSetupSection),
      matching: find.byType(SingleChildScrollView),
    );
    expect(
      tester.getSize(viewport).height,
      lessThan(tester.getSize(find.byType(FirstRunSetupSection)).height),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a panel too short for its own header is clipped rather than '
      'painted over the workspace', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(400, 60);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildDrawer(steps: _allSteps));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // AbDockedColumn never squeezes its header, so at this size the header is
    // what runs past the bottom edge; the drawer's Clip.hardEdge is the only
    // thing keeping it off the pane beside it.
    expect(
      find.ancestor(
        of: find.byType(AbDockedColumn),
        matching: find.byType(ClipPath),
      ),
      findsOneWidget,
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

    // Unmounted outright, not shrunk: the dock skips its scroll view too, so
    // no Scrollable outlives the checklist (see _SetupDock).
    expect(find.byType(FirstRunSetupSection), findsNothing);
    expect(find.textContaining('SETUP'), findsNothing);
    expect(find.byType(AccountFooter), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
