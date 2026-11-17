import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/recent_sessions/recent_sessions_summary.dart';

RecentSessionRow _row(String id) => RecentSessionRow(
  session: SessionEntry(
    id: id,
    name: 'Session $id',
    createdAt: 0,
    lastUsedAt: 0,
    archived: false,
    running: false,
  ),
  origin: const RecentOrigin(
    isLocal: true,
    registrationId: 'proj',
    projectId: 'proj',
    machineUuid: null,
    projectName: 'antgrid',
    deviceName: 'This device',
  ),
);

// Mirrors the title/badges half of `_TopBar`'s Row (new_session_content.dart):
// title takes an Expanded on the left, badges a Flexible on the right, so this
// pins the overflow hazard that call site carries inline.
Widget _wrap({
  required Map<AgentWorkStatus, int> counts,
  required int total,
  required double leading,
}) {
  return ProviderScope(
    overrides: [
      recentSessionsProvider.overrideWithValue([
        for (var i = 0; i < total; i++) _row('s$i'),
      ]),
      recentSessionStatusCountsProvider.overrideWithValue(counts),
    ],
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      builder: (context, child) => AbCarbonScope(child: child!),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Stands in for the mobile drawer button the line shares its row
              // with — the width it does NOT get is the whole hazard here.
              SizedBox(width: leading),
              const Expanded(child: RecentSessionsTitle()),
              const SizedBox(width: 10),
              // The badges are a Wrap, and a Wrap sitting directly in a Row is
              // handed UNBOUNDED main-axis constraints — so it never wraps,
              // and at four states on a phone it overruns the edge and
              // starves the title. Flexible bounds it to its share instead.
              const Flexible(child: RecentSessionsSummaryBadges()),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  // Every state at once on the narrowest phone is the worst case for the
  // Flexible-badges hazard documented on `_wrap` above, so that is what this
  // pins.
  testWidgets('title + badges fit a 360dp phone with all four states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        counts: const {
          AgentWorkStatus.attention: 2,
          AgentWorkStatus.error: 1,
          AgentWorkStatus.working: 3,
          AgentWorkStatus.done: 11,
        },
        total: 17,
        leading: 40,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('2 needs you'), findsOneWidget);
    expect(find.text('11 done'), findsOneWidget);
  });

  // The cap must not become a straitjacket: one badge has room to sit on the
  // title's line, and wrapping it there would be the fix overshooting.
  testWidgets('a single badge stays beside the title', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(counts: const {AgentWorkStatus.done: 3}, total: 3, leading: 40),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.text('Sessions'));
    final badge = tester.getRect(find.text('3 done'));
    expect(badge.left, greaterThan(title.left));
    expect(badge.center.dy, closeTo(title.center.dy, 2));
  });

  // A Wrap only wraps BETWEEN children — it still hands each one its own
  // maxWidth, so a single badge wider than that has to shrink itself. That is
  // reachable from `RecentListHeader`, whose Row puts the inflexible group-by
  // control beside the badges: it takes its full width first and leaves the
  // badges a few dozen pixels. The title already
  // ellipsizes there, and a badge has to degrade the same way rather than paint
  // past its edge.
  testWidgets('a badge too narrow for its label ellipsizes, not overflows', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recentSessionsProvider.overrideWithValue([_row('s0')]),
          // A live state, so the badge carries its dot and gap too — the
          // tightest of the four.
          recentSessionStatusCountsProvider.overrideWithValue(const {
            AgentWorkStatus.attention: 1,
          }),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
          ),
          builder: (context, child) => AbCarbonScope(child: child!),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 44, child: RecentSessionsSummaryBadges()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('1 needs you'), findsOneWidget);
  });

  group('RecentGroupByChips', () {
    // Nothing to group with no sessions — a live chip row would toggle a
    // grouping nothing on screen obeys.
    testWidgets('hides when there are no recent sessions', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [recentSessionsProvider.overrideWithValue(const [])],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            builder: (context, child) => AbCarbonScope(child: child!),
            home: const Scaffold(body: RecentGroupByChips()),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Machine'), findsNothing);
      expect(find.text('Project'), findsNothing);
      expect(find.text('Status'), findsNothing);
    });

    // The chips write recentGroupByProvider directly: that is the whole
    // contract that lets RecentSessionsTab's grouping and the header agree on
    // the current axis with no shared ancestor State between them.
    testWidgets('picking a chip updates recentGroupByProvider', (tester) async {
      final container = ProviderContainer(
        overrides: [
          recentSessionsProvider.overrideWithValue([_row('s1')]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            builder: (context, child) => AbCarbonScope(child: child!),
            home: const Scaffold(body: RecentGroupByChips()),
          ),
        ),
      );
      await tester.pump();

      expect(container.read(recentGroupByProvider), RecentGroupBy.project);

      await tester.tap(find.text('Machine'));
      await tester.pump();

      expect(container.read(recentGroupByProvider), RecentGroupBy.machine);
    });
  });

  group('RecentGroupByMenu', () {
    Widget host(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        builder: (context, child) => AbCarbonScope(child: child!),
        home: const Scaffold(body: Align(child: RecentGroupByMenu())),
      ),
    );

    testWidgets('names the current grouping and hides with no sessions', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [recentSessionsProvider.overrideWithValue(const [])],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(host(container));
      await tester.pump();
      expect(find.byType(CarbonMenuButton), findsNothing);
    });

    testWidgets('the trigger is announced with the grouping it changes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final container = ProviderContainer(
        overrides: [
          recentSessionsProvider.overrideWithValue([_row('s1')]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(host(container));
      await tester.pump();

      expect(find.bySemanticsLabel('Group by: Project'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('picking an entry updates recentGroupByProvider', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          recentSessionsProvider.overrideWithValue([_row('s1')]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(host(container));
      await tester.pump();

      expect(find.text('By project'), findsOneWidget);
      await tester.tap(find.text('By project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Status'));
      await tester.pumpAndSettle();

      expect(container.read(recentGroupByProvider), RecentGroupBy.status);
      expect(find.text('By status'), findsOneWidget);
    });
  });
}
