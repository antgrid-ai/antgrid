// The Git panel is a Carbon surface: nothing under its scope may build an Ab
// widget, in any state, density or brightness. Each state below is the one
// most likely to have kept a stray Ab helper.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/widgets/carbon_diff_stat.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/widgets/git_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  late FakeAgentTransport transport;

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<Map<String, dynamic>>? files,
    Brightness brightness = Brightness.light,
  }) async {
    useInMemoryPrefs();
    transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => transport.dispose(),
    );
    final c = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('p'),
        projectSessionProvider('p').overrideWith((ref) => session),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(session.close);
    c.read(visibleWorkspaceViewProvider.notifier).set(WorkspaceView.git);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(body: SizedBox(width: 800, child: GitPanel())),
        ),
      ),
    );
    for (
      var i = 0;
      i < 5 && transport.sent.every((m) => m['type'] != 'git:log');
      i++
    ) {
      await tester.pump();
    }
    transport.emit('git:log-result', {
      'projectId': 'p',
      'commits': const <Object?>[],
      'skip': 0,
      'hasMore': false,
    });
    if (files != null) {
      transport.emit('git:status', {'projectId': 'p', 'files': files});
    }
    await tester.pump();
    await tester.pump();
  }

  const files = [
    {'path': 'a.dart', 'status': 'M', 'staged': false},
    {'path': 'lib/b.dart', 'status': 'A', 'staged': true},
    {'path': 'c.dart', 'status': '!', 'staged': false},
  ];

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final brightness in Brightness.values) {
      testWidgets('loaded panel builds no Ab widget (${platform.name}, '
          '${brightness.name})', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await pumpPanel(tester, files: files, brightness: brightness);

          expect(find.byType(AbCarbonScope), findsOneWidget);
          expect(abWidgetsInScope(tester), isEmpty);

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('a clean tree builds no Ab widget', (tester) async {
    await pumpPanel(tester, files: const []);

    expect(abWidgetsInScope(tester), isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the loading state builds no Ab widget', (tester) async {
    await pumpPanel(tester);

    expect(abWidgetsInScope(tester), isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a row with its hover actions revealed builds no Ab widget', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpPanel(tester, files: files);
      await hoverRow(tester, find.byKey(const ValueKey('a.dart')));

      expect(abWidgetsInScope(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('every row ends its status mark at the same inset, whatever '
      'hover actions it reserves', (tester) async {
    // A conflict offers one hidden action and the others two; hidden actions
    // keep their width, so a mark laid out before them moved row to row.
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpPanel(
        tester,
        files: const [
          ...files,
          {'path': 'd.dart', 'status': 'M', 'staged': false, 'additions': 12, 'deletions': 4},
        ],
      );
      final ends = <double>{
        for (final e in find.byType(CarbonStatusDot).evaluate())
          tester.getRect(find.byWidget(e.widget)).right,
        tester.getRect(find.byType(CarbonDiffStat)).right,
      };
      expect(find.byType(CarbonStatusDot), findsNWidgets(3));
      expect(ends, hasLength(1), reason: 'mark right edges: $ends');

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
