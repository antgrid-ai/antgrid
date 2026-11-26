import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

// Mirrors the title/badges half of `_TopBar`'s Row (new_session_content.dart)
// and `_SessionsHeader`'s wide-desktop Row (recent_sessions_tab.dart): title
// takes an Expanded on the left, badges a Flexible on the right, so this pins
// the shared overflow hazard both those call sites now carry inline rather
// than through a single dedicated widget.
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
    expect(find.text('Sessions · 17 total'), findsOneWidget);
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
    final title = tester.getRect(find.text('Sessions · 3 total'));
    final badge = tester.getRect(find.text('3 done'));
    expect(badge.left, greaterThan(title.left));
    expect(badge.center.dy, closeTo(title.center.dy, 2));
  });

  // A Wrap only wraps BETWEEN children — it still hands each one its own
  // maxWidth, so a single badge wider than that has to shrink itself. That is
  // reachable from `_SessionsHeader` (recent_sessions_tab.dart), whose Row puts
  // the inflexible group-by chips between two Expandeds: the chips take their
  // full width first and leave the badges a few dozen pixels. The title already
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
            home: const Scaffold(body: RecentGroupByChips()),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('MACHINE'), findsNothing);
      expect(find.text('PROJECT'), findsNothing);
      expect(find.text('STATUS'), findsNothing);
    });

    // The chips write recentGroupByProvider directly — this is the whole
    // contract that lets RecentSessionsTab's grouping and a mount point
    // elsewhere in the tree (the canvas top bar) agree on the current axis
    // with no shared ancestor State between them.
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
            home: const Scaffold(body: RecentGroupByChips()),
          ),
        ),
      );
      await tester.pump();

      expect(container.read(recentGroupByProvider), RecentGroupBy.machine);

      await tester.tap(find.text('PROJECT'));
      await tester.pump();

      expect(container.read(recentGroupByProvider), RecentGroupBy.project);
    });
  });
}
