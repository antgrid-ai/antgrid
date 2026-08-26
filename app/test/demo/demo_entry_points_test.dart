// The demo exists because a reviewer with no account, and a tester whose
// desktop isn't set up yet, both land on a screen where nothing works. These
// tests pin the three doors into it and the one way back out; a door that
// stops rendering is the whole rejection again.
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/screens/demo_home.dart';
import 'package:antgrid/screens/sign_in_screen.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';
import '../helpers/prefs_test_mock.dart';

const String _kDemoLink = 'Explore a sample project';
const String _kDemoBanner =
    'Demo — sample data, not a real machine. Nothing is connected.';

/// The empty Recent list, pumped on its own: the two affordances there sit
/// behind provider state the full app would have to be talked into, and this
/// is the same harness `first_run_checklist_test.dart` uses for the surface.
Widget _wrapRecent(List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    home: const Scaffold(body: RecentSessionsTab()),
  ),
);

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(RecentSessionsTab)));

// No `debugDefaultTargetPlatformOverride` anywhere below, unlike the other
// mobile-shaped suites: under FLUTTER_TEST `defaultTargetPlatform` already
// reports android, and setting the override trips the binding's end-of-body
// invariant unless every test restores it by hand.
void main() {
  group('the sign-in screen', () {
    testWidgets('offers the sample project with no account', (tester) async {
      final container = await pumpDemoApp(tester);

      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.text(_kDemoLink), findsOneWidget);
      expect(container.read(demoModeProvider), isFalse);
    });

    testWidgets('tapping it opens the demo instead of the workspace', (
      tester,
    ) async {
      final container = await pumpDemoApp(tester);
      await tester.ensureVisible(find.text(_kDemoLink));
      await tester.tap(find.text(_kDemoLink));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(container.read(demoModeProvider), isTrue);
      expect(find.byType(DemoHome), findsOneWidget);
      expect(find.byType(SignInScreen), findsNothing);
      // The door the reviewer used must not have signed anybody in on the way.
      expect(container.read(currentUserProvider).value, isNull);
      expect(
        container.read(selectedTargetProvider),
        const LocalProject(kDemoProjectId),
      );
    });
  });

  group('the empty Recent list', () {
    testWidgets('offers the sample project from the first-run checklist', (
      tester,
    ) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();

      await tester.pumpWidget(
        _wrapRecent([
          firstRunStoreProvider.overrideWithValue(store),
          recentSessionsProvider.overrideWith((_) => const []),
          pickerSourcesProvider.overrideWithValue(const <PickerSource>[]),
          accountAgentsProvider.overrideWith((_) async => const []),
        ]),
      );
      await tester.pump();

      // Every other step on that checklist needs the desktop the tester
      // doesn't have in front of them.
      expect(find.text('Connect a machine'), findsOneWidget);
      expect(find.text(_kDemoLink), findsOneWidget);

      final container = _containerOf(tester);
      await tester.ensureVisible(find.text(_kDemoLink));
      await tester.tap(find.text(_kDemoLink));
      await tester.pump();

      expect(container.read(demoModeProvider), isTrue);
    });

    testWidgets(
      'offers it from the plain empty state while nothing is picked',
      (tester) async {
        useInMemoryPrefs();

        await tester.pumpWidget(
          _wrapRecent([
            recentSessionsProvider.overrideWith((_) => const []),
            firstRunChecklistVisibleProvider.overrideWithValue(false),
            newSessionHasValidTargetProvider.overrideWithValue(false),
          ]),
        );
        await tester.pump();

        expect(find.text('No recent sessions'), findsOneWidget);
        expect(find.text(_kDemoLink), findsOneWidget);

        final container = _containerOf(tester);
        await tester.ensureVisible(find.text(_kDemoLink));
        await tester.tap(find.text(_kDemoLink));
        await tester.pump();

        expect(container.read(demoModeProvider), isTrue);
      },
    );

    testWidgets('withholds it once a real project is picked', (tester) async {
      useInMemoryPrefs();

      await tester.pumpWidget(
        _wrapRecent([
          recentSessionsProvider.overrideWith((_) => const []),
          firstRunChecklistVisibleProvider.overrideWithValue(false),
          newSessionHasValidTargetProvider.overrideWithValue(true),
        ]),
      );
      await tester.pump();

      expect(find.text('No recent sessions'), findsOneWidget);
      expect(find.text(_kDemoLink), findsNothing);
    });
  });

  group('inside the demo', () {
    testWidgets('the sample data is labelled on every route', (tester) async {
      await pumpDemoApp(tester, enterDemo: true);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(DemoHome), findsOneWidget);
      expect(find.text(_kDemoBanner), findsOneWidget);
      expect(find.text('Exit demo'), findsOneWidget);
    });

    testWidgets('Exit demo hands the app back', (tester) async {
      final container = await pumpDemoApp(tester, enterDemo: true);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Exit demo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(container.read(demoModeProvider), isFalse);
      expect(find.byType(DemoHome), findsNothing);
      expect(find.text(_kDemoBanner), findsNothing);
      // Back to the reviewer's real starting point, with the door still open.
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.text(_kDemoLink), findsOneWidget);
      expect(container.read(selectedTargetProvider), isNull);
    });
  });
}
