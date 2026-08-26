import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/new_session_start.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_tab.dart';
import 'package:antgrid/widgets/recent_sessions/starting_session_row.dart';

/// The row renders nothing until a start is armed, and a zero-extent sliver
/// child is skipped by the default finders — so the container has to be built
/// here rather than looked up off an element that does not exist yet.
ProviderContainer _container(List<Override> overrides) {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  return container;
}

Widget _host(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void _begin(
  ProviderContainer container, {
  NewSessionStartPhase phase = NewSessionStartPhase.activating,
  String deviceName = 'mac-studio',
  String title = 'Fix the parser',
}) {
  container
      .read(newSessionStartProgressProvider.notifier)
      .begin(
        phase: phase,
        targetId: 'M.p1',
        targetName: 'antgrid',
        deviceName: deviceName,
        agentLabel: 'Claude Code',
        isolated: false,
        title: title,
      );
}

String _phaseText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(startingSessionPhaseKey)).data!;

RecentSessionRow _recentRow() => RecentSessionRow(
  session: const SessionEntry(
    id: 's1',
    name: 'Fix auth bug',
    createdAt: 0,
    lastUsedAt: 1,
    archived: false,
    running: false,
  ),
  origin: const RecentOrigin(
    isLocal: true,
    registrationId: 'p',
    projectId: 'p',
    machineUuid: null,
    projectName: 'antgrid',
    deviceName: 'This device',
  ),
);

void main() {
  testWidgets(
    'appears while a start runs, tracks the phase, and leaves on end',
    (tester) async {
      final container = _container(const []);
      await tester.pumpWidget(_host(container, const StartingSessionRow()));
      await tester.pump();

      expect(find.byKey(startingSessionRowKey), findsNothing);

      _begin(container);
      // Never pumpAndSettle: the row's AbLoadingDot animates forever.
      await tester.pump();

      expect(find.byKey(startingSessionRowKey), findsOneWidget);
      expect(find.text('STARTING'), findsOneWidget);
      expect(find.text('Fix the parser'), findsOneWidget);
      expect(find.text('mac-studio · antgrid'), findsOneWidget);
      expect(_phaseText(tester), 'Waking mac-studio...');

      container
          .read(newSessionStartProgressProvider.notifier)
          .advance(NewSessionStartPhase.preparing);
      await tester.pump();
      expect(_phaseText(tester), 'Preparing workspace...');

      container.read(newSessionStartProgressProvider.notifier).end();
      await tester.pump();
      expect(find.byKey(startingSessionRowKey), findsNothing);
    },
  );

  testWidgets('a local start names the project alone', (tester) async {
    final container = _container(const []);
    await tester.pumpWidget(_host(container, const StartingSessionRow()));
    // An empty deviceName is the local signal: there is no machine to wake, so
    // neither the subtitle nor the phase copy may invent one.
    _begin(container, deviceName: '');
    await tester.pump();

    expect(find.text('antgrid'), findsOneWidget);
    expect(_phaseText(tester), 'Opening antgrid...');
  });

  testWidgets('is not tappable', (tester) async {
    final container = _container(const []);
    await tester.pumpWidget(_host(container, const StartingSessionRow()));
    _begin(container);
    await tester.pump();

    // The composer owns the only Stop; a row for a session that does not exist
    // yet has nothing to open.
    final row = find.byKey(startingSessionRowKey);
    expect(
      find.descendant(of: row, matching: find.byType(GestureDetector)),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.byType(InkWell)),
      findsNothing,
    );

    await tester.tap(row, warnIfMissed: false);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(startingSessionRowKey), findsOneWidget);
  });

  testWidgets('mounts in the empty-recents branch', (tester) async {
    // The first session a user ever starts is started from an empty list — the
    // branch that returns before the groups ever render.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    // Torn down rather than reset at the end of the body: a failing `expect`
    // would otherwise leak the override into the next test AND surface as
    // flutter_test's "foundation debug variable was changed" instead of the
    // assertion that actually failed.
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = _container([
      recentSessionsProvider.overrideWithValue(const []),
    ]);
    await tester.pumpWidget(_host(container, const RecentSessionsTab()));
    await tester.pump();

    expect(find.textContaining('No recent sessions'), findsOneWidget);
    expect(find.byKey(startingSessionRowKey), findsNothing);

    _begin(container, phase: NewSessionStartPhase.creating);
    await tester.pump();

    expect(find.byKey(startingSessionRowKey), findsOneWidget);
    expect(_phaseText(tester), 'Creating session...');
    expect(find.textContaining('No recent sessions'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('sits above the first group when recents exist', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = _container([
      recentSessionsProvider.overrideWithValue([_recentRow()]),
    ]);
    await tester.pumpWidget(_host(container, const RecentSessionsTab()));
    await tester.pump();

    _begin(container);
    await tester.pump();

    expect(find.byKey(startingSessionRowKey), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(startingSessionRowKey)).dy,
      lessThan(tester.getTopLeft(find.text('Fix auth bug')).dy),
    );

    debugDefaultTargetPlatformOverride = null;
  });
}
