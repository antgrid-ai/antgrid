// The header's bulk actions are the only way to stage or revert the whole tree
// without walking it file by file, and two of the three are unrecoverable —
// these pin what each one actually sends, including the revert-to-HEAD flag a
// per-file Discard cannot express on its own.
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/git_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  late FakeAgentTransport transport;
  late ProjectSession session;

  /// Pumps the panel with [files] as the project's git status. Entries are the
  /// raw `git:status` shape, so a path with both a staged and an unstaged
  /// change is expressed the way the bridge sends it: twice.
  Future<void> pumpWithStatus(
    WidgetTester tester,
    List<Map<String, dynamic>> files, {
    double width = 800,
  }) async {
    useInMemoryPrefs();
    transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    session = ProjectSession(
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
          home: Scaffold(
            body: SizedBox(width: width, child: const GitPanel()),
          ),
        ),
      ),
    );
    transport.emit('git:status', {'projectId': 'p', 'files': files});
    await tester.pump();
    await tester.pump();
  }

  Map<String, dynamic>? sentOfType(String type) {
    for (final m in transport.sent.reversed) {
      if (m['type'] == type) return m;
    }
    return null;
  }

  testWidgets('Stage All stages every unstaged path, leaving staged ones', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': 'M', 'staged': true},
      {'path': 'c.dart', 'status': 'U', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Stage All Changes'));
    await tester.pump();

    expect(sentOfType('git:stage')?['files'], ['a.dart', 'c.dart']);
  });

  testWidgets('Revert All reverts staged and unstaged paths, each named once', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      // Staged then edited again: two entries, one path.
      {'path': 'a.dart', 'status': 'M', 'staged': true},
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': 'A', 'staged': true},
      // A conflict is not a safe restore to HEAD — it must stay out of scope.
      {'path': 'c.dart', 'status': '!', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Revert All Changes'));
    await tester.pumpAndSettle();
    // The dialog's confirm button, which is the only 'Revert All' TEXT on
    // screen — the header affordance itself is an icon.
    await tester.tap(find.text('Revert All'));
    await tester.pumpAndSettle();

    final msg = sentOfType('git:discard');
    expect(msg?['files'], ['a.dart', 'b.dart']);
    expect(msg?['includeStaged'], isTrue);
  });

  testWidgets('Revert All sends nothing when the confirm is cancelled', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Revert All Changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sentOfType('git:discard'), isNull);
  });

  testWidgets('bulk actions stay mounted once everything is staged', (
    tester,
  ) async {
    // Stage All has nothing to do here, but it keeps its slot: dropping it
    // would slide Commit sideways under a finger already on its way there.
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    expect(find.byTooltip('Stage All Changes'), findsOneWidget);
    expect(find.byTooltip('Revert All Changes'), findsOneWidget);

    await tester.tap(find.byTooltip('Stage All Changes'));
    await tester.pump();
    expect(sentOfType('git:stage'), isNull);
  });

  testWidgets('the title yields before the actions do', (tester) async {
    // Narrow enough that title + actions no longer fit: the title is what
    // gives (Expanded + ellipsis), and a RenderFlex overflow — which fails this
    // test on its own — is what happens if it ever stops being able to. The
    // width is in test-font units, where every glyph is a full em square.
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': 'M', 'staged': true},
    ], width: 300);

    expect(find.byTooltip('Stage All Changes'), findsOneWidget);
    expect(find.byTooltip('Revert All Changes'), findsOneWidget);
    expect(find.text('Commit (1)'), findsOneWidget);
  });

  testWidgets('a clean tree shows neither bulk action', (tester) async {
    await pumpWithStatus(tester, const []);

    expect(find.byTooltip('Stage All Changes'), findsNothing);
    expect(find.byTooltip('Revert All Changes'), findsNothing);
    expect(find.text('Commit'), findsOneWidget);
  });

  testWidgets('the header totals each changed path once', (tester) async {
    // a.dart arrives twice — staged and unstaged — carrying the SAME
    // combined-vs-HEAD counts on both, so summing entries would report +32.
    await pumpWithStatus(tester, [
      {
        'path': 'a.dart',
        'status': 'M',
        'staged': false,
        'additions': 10,
        'deletions': 4,
      },
      {
        'path': 'a.dart',
        'status': 'M',
        'staged': true,
        'additions': 10,
        'deletions': 4,
      },
      {
        'path': 'b.dart',
        'status': 'A',
        'staged': false,
        'additions': 2000,
        'deletions': 0,
      },
    ]);

    // Scoped to the header: a.dart's own row carries the same -4 badge.
    final header = find
        .ancestor(of: find.text('Changes'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(of: header, matching: find.text('+2,010')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.text('-4')),
      findsOneWidget,
    );
  });

  testWidgets('a tree changed only by a rename shows no totals', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'R', 'staged': true, 'oldPath': 'z.dart'},
    ]);

    final header = find
        .ancestor(of: find.text('Changes'), matching: find.byType(Row))
        .first;
    expect(
      find.descendant(of: header, matching: find.textContaining('+')),
      findsNothing,
    );
  });

  // A touch tablet's context pane is a quarter of the window, and there the
  // one line could not hold both halves: the title ellipsised away and the
  // header showed counts for something it no longer named. Narrow panes stack
  // instead, actions right-aligned under the title. A phone is full-width and
  // keeps its one line, which is why this is measured on the PANE.
  testWidgets('a narrow pane stacks the actions under the title', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ], width: 300);

    final title = tester.getRect(find.text('Changes'));
    final commit = tester.getRect(find.byType(AbButton).last);
    expect(
      commit.top,
      greaterThanOrEqualTo(title.bottom),
      reason: 'the actions belong on their own row, below the title',
    );

    // The title row spans the header (its text sits in an Expanded), so its
    // trailing edge is where a right-aligned action has to end.
    final titleRow = tester.getRect(
      find.ancestor(of: find.text('Changes'), matching: find.byType(Row)).first,
    );
    expect(commit.right, closeTo(titleRow.right, 8));
  });

  testWidgets('a pane with room keeps the header on one line', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    final title = tester.getRect(find.text('Changes'));
    final commit = tester.getRect(find.byType(AbButton).last);
    expect(commit.top, lessThan(title.bottom));
  });
}
