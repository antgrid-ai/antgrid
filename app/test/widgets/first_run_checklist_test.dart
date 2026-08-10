import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/new_session/first_run_checklist.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_tab.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

List<FirstRunStep> _desktopSteps({
  bool signIn = false,
  bool openProject = false,
  bool startSession = false,
  bool connectPhone = false,
}) => [
  (id: FirstRunStepIds.signIn, label: 'Sign in', done: signIn),
  (id: FirstRunStepIds.openProject, label: 'Open a project', done: openProject),
  (
    id: FirstRunStepIds.startSession,
    label: 'Start a session',
    done: startSession,
  ),
  (
    id: FirstRunStepIds.connectPhone,
    label: 'Connect your phone',
    done: connectPhone,
  ),
];

void main() {
  testWidgets('desktop card shows checked/unchecked markers from the steps '
      'and latches the done ones', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const FirstRunChecklistCard(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          desktopFirstRunStepsProvider.overrideWith(
            (_) => _desktopSteps(signIn: true),
          ),
        ],
      ),
    );
    await tester.pump(); // latch microtask

    expect(find.text('SETUP · 1/4'), findsOneWidget);
    expect(find.text('[x]'), findsOneWidget);
    expect(find.text('[ ]'), findsNWidgets(3));
    // First unchecked step's contextual hint.
    expect(find.text('Open a folder from the composer below.'), findsOneWidget);

    // The done step is latched into the persisted state.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FirstRunChecklistCard)),
    );
    expect(container.read(firstRunProvider).completedSteps, {
      FirstRunStepIds.signIn,
    });
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('dismiss hides the card and persists across a restart', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    final overrides = [
      firstRunStoreProvider.overrideWithValue(store),
      desktopFirstRunStepsProvider.overrideWith((_) => _desktopSteps()),
    ];
    await tester.pumpWidget(
      _wrap(const FirstRunChecklistCard(), overrides: overrides),
    );
    await tester.pump();
    expect(find.text('SETUP · 0/4'), findsOneWidget);

    await tester.tap(find.byTooltip("Dismiss — won't show again"));
    await tester.pump();
    expect(find.text('SETUP · 0/4'), findsNothing);
    expect(store.read().checklistDismissed, isTrue);

    // Fresh scope over the same prefs — an app restart — stays hidden.
    await tester.pumpWidget(
      _wrap(
        const FirstRunChecklistCard(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(await FirstRunStore.open()),
          desktopFirstRunStepsProvider.overrideWith((_) => _desktopSteps()),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('SETUP · 0/4'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('all steps done marks completion, unmounts the card, and never '
      're-shows', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const FirstRunChecklistCard(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          desktopFirstRunStepsProvider.overrideWith(
            (_) => _desktopSteps(
              signIn: true,
              openProject: true,
              startSession: true,
              connectPhone: true,
            ),
          ),
        ],
      ),
    );
    // First frame renders; the microtask then writes checklistCompleted and
    // the card unmounts on the next pump.
    await tester.pump();
    expect(find.text('SETUP · 4/4'), findsNothing);
    expect(store.read().checklistCompleted, isTrue);

    // Restart with every live signal regressed (steps unchecked): completion
    // is latched, so the card must not come back.
    await tester.pumpWidget(
      _wrap(
        const FirstRunChecklistCard(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(await FirstRunStore.open()),
          desktopFirstRunStepsProvider.overrideWith((_) => _desktopSteps()),
        ],
      ),
    );
    await tester.pump();
    expect(find.textContaining('SETUP'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop card renders nothing on mobile', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const FirstRunChecklistCard(),
        overrides: [firstRunStoreProvider.overrideWithValue(store)],
      ),
    );
    await tester.pump();
    expect(find.textContaining('SETUP'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile checklist renders in the empty Recent slot for a '
      'no-machine account', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const RecentSessionsTab(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          recentSessionsProvider.overrideWith((_) => const []),
          pickerSourcesProvider.overrideWithValue(const <PickerSource>[]),
          // No machines on the account → step 1 unchecked, no network.
          accountAgentsProvider.overrideWith((_) async => const []),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Connect a machine'), findsOneWidget);
    expect(
      find.text('Install Antgrid on your computer and sign in there'),
      findsOneWidget,
    );
    expect(
      find.text("Turn on Remote in that computer's title bar"),
      findsOneWidget,
    );
    expect(find.text('[ ]'), findsNWidgets(3));
    expect(
      find.text("Pull down to refresh once you've done a step."),
      findsOneWidget,
    );
    expect(find.textContaining('No recent sessions'), findsNothing);

    // Dismissing swaps to the plain empty state and persists.
    await tester.tap(find.byTooltip("Dismiss — won't show again"));
    await tester.pump();
    expect(find.text('Connect a machine'), findsNothing);
    expect(find.textContaining('No recent sessions'), findsOneWidget);
    expect(store.read().checklistDismissed, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });
}
