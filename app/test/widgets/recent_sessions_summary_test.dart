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
              const Expanded(child: RecentSessionsSummaryLine()),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  // The badges are a Wrap, which a Row hands unbounded main-axis constraints:
  // without a cap it lays out on one infinite line, overflows the phone by
  // ~150px, and leaves the title nothing. Every state at once on the narrowest
  // phone is the worst case, so that is what this pins.
  testWidgets('summary line fits a 360dp phone with all four states', (
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
}
