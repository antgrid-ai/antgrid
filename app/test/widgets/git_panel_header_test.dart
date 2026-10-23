// The header's bulk actions are the only way to stage or revert the whole tree
// without walking it file by file, and two of the three are unrecoverable —
// these pin what each one actually sends, including the revert-to-HEAD flag a
// per-file Discard cannot express on its own.
//
// The conflict cases at the bottom pin the other half of that contract: what
// the header refuses while a merge is unresolved, and the one action that
// clears it.
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/git_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  late FakeAgentTransport transport;
  late ProjectSession session;

  /// Pumps the panel with [files] as the project's git status. Entries are the
  /// raw `git:status` shape, so a path with both a staged and an unstaged
  /// change is expressed the way the bridge sends it: twice.
  ///
  /// No file tree is fed in, and the fold tests below do not need one: the
  /// changes list builds its folder rows from the changed-file PATHS alone
  /// (`_ChangesDir.build`), never from the synced tree.
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
    // The panel eagerly claims (and, one post-frame callback later, sends)
    // its first `git:log` the moment its FileService is ready — see
    // GitPanel._maybeLoadHistory. Answering it is what keeps that send's
    // 15s reply-timeout timer from outliving the test; waiting for it to
    // actually appear in `sent` (rather than a fixed pump count) is what
    // keeps this robust against exactly how many frames that takes.
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
    transport.emit('git:status', {'projectId': 'p', 'files': files});
    await tester.pump();
    await tester.pump();
  }

  /// The tree's per-row buttons are a desktop affordance (touch gets the swipe
  /// tray instead), and a widget test runs as Android unless told otherwise.
  /// The override has to be cleared before the body returns — a tearDown runs
  /// too late for the framework's debug-variable assert.
  Future<void> withRowButtons(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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

  testWidgets('Discard All discards working-tree changes, each named once', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      // Staged then edited again: two entries, one path.
      {'path': 'a.dart', 'status': 'M', 'staged': true},
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      // Only staged: not this group's to discard.
      {'path': 'b.dart', 'status': 'A', 'staged': true},
      {'path': 'n.dart', 'status': 'U', 'staged': false},
      // A conflict is not a safe restore — it must stay out of scope.
      {'path': 'c.dart', 'status': '!', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Discard All Changes'));
    await tester.pumpAndSettle();
    // The dialog's confirm button, which is the only 'Discard All' TEXT on
    // screen — the header affordance itself is an icon.
    await tester.tap(find.text('Discard All'));
    await tester.pumpAndSettle();

    final msg = sentOfType('git:discard');
    expect(msg?['files'], ['a.dart', 'n.dart']);
    // Restored from the index, as VS Code's Discard All does: staged
    // content survives.
    expect(msg?['includeStaged'], isNull);
  });

  testWidgets('Discard All sends nothing when the confirm is cancelled', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Discard All Changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sentOfType('git:discard'), isNull);
  });

  testWidgets('Unstage All unstages every staged path, each named once', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': 'A', 'staged': true},
      {'path': 'c.dart', 'status': 'M', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Unstage All Changes'));
    await tester.pump();

    expect(sentOfType('git:unstage')?['files'], ['a.dart', 'b.dart']);
  });

  testWidgets('each group carries only its own bulk actions', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    // Nothing unstaged: no Changes group, so no Stage All or Discard All.
    expect(find.byTooltip('Unstage All Changes'), findsOneWidget);
    expect(find.byTooltip('Stage All Changes'), findsNothing);
    expect(find.byTooltip('Discard All Changes'), findsNothing);
  });

  testWidgets('both group headers fit a narrow column', (tester) async {
    // A RenderFlex overflow, which fails this test on its own, is what happens
    // if a header ever stops fitting. The width is in test-font units, where
    // every glyph is a full em square.
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': 'M', 'staged': true},
    ], width: 300);

    expect(find.byTooltip('Stage All Changes'), findsOneWidget);
    expect(find.byTooltip('Unstage All Changes'), findsOneWidget);
    expect(find.text('Commit (1)'), findsOneWidget);
  });

  testWidgets('a clean tree drops the commit box and the change groups', (
    tester,
  ) async {
    await pumpWithStatus(tester, const []);

    expect(find.byTooltip('Stage All Changes'), findsNothing);
    expect(find.byTooltip('Discard All Changes'), findsNothing);
    expect(find.text('Commit'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('CHANGES'), findsNothing);
    expect(find.text('STAGED CHANGES'), findsNothing);
    expect(find.text('HISTORY'), findsOneWidget);
  });

  // The commit box is inline, above the button that sends it — no dialog sits
  // between the message and the commit any more.
  testWidgets('Commit sends the inline message and clears the box', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    final field = tester.getRect(find.byType(TextField));
    final commit = tester.getRect(find.widgetWithText(AbButton, 'Commit (1)'));
    expect(commit.top, greaterThanOrEqualTo(field.bottom));

    await tester.enterText(find.byType(TextField), '  fix: the thing  ');
    await tester.tap(find.text('Commit (1)'));
    await tester.pump();

    expect(sentOfType('git:commit')?['message'], 'fix: the thing');
    expect(find.text('Committing…'), findsOneWidget);
    transport.emit('git:commit-result', {'projectId': 'p', 'success': true});
    await tester.pump();
    expect(find.text('Committing…'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('a refused commit keeps its message for the retry', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    await tester.enterText(find.byType(TextField), 'fix: the thing');
    await tester.tap(find.text('Commit (1)'));
    await tester.pump();
    transport.emit('git:commit-result', {
      'projectId': 'p',
      'success': false,
      'error': 'pre-commit: lint failed',
    });
    await tester.pump();

    expect(find.text('Committing…'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'fix: the thing',
    );
  });

  testWidgets('a message typed while committing survives the success', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    await tester.enterText(find.byType(TextField), 'fix: the thing');
    await tester.tap(find.text('Commit (1)'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'feat: the next thing');
    transport.emit('git:commit-result', {'projectId': 'p', 'success': true});
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'feat: the next thing',
    );
  });

  testWidgets('Commit with an empty message sends nothing', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    await tester.tap(find.text('Commit (1)'));
    await tester.pump();

    expect(sentOfType('git:commit'), isNull);
  });

  testWidgets('Ctrl+Enter in the commit box commits', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    await tester.enterText(find.byType(TextField), 'feat: shortcut');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(sentOfType('git:commit')?['message'], 'feat: shortcut');
    transport.emit('git:commit-result', {'projectId': 'p', 'success': true});
    await tester.pump();
  });

  testWidgets('nothing staged leaves Commit dead', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
    ]);

    await tester.enterText(find.byType(TextField), 'msg');
    await tester.tap(find.text('Commit'), warnIfMissed: false);
    await tester.pump();

    expect(sentOfType('git:commit'), isNull);
  });

  testWidgets('folding a group hides its rows but keeps its actions', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': 'M', 'staged': true},
    ]);

    await tester.tap(find.text('CHANGES'));
    await tester.pumpAndSettle();

    expect(find.text('a.dart'), findsNothing);
    expect(find.byTooltip('Stage All Changes'), findsOneWidget);
    // The other group is untouched by the fold.
    expect(find.text('b.dart'), findsOneWidget);

    await tester.tap(find.text('STAGED CHANGES'));
    await tester.pumpAndSettle();
    expect(find.text('b.dart'), findsNothing);
    expect(find.byTooltip('Unstage All Changes'), findsOneWidget);
  });

  testWidgets('phone width switches between Changes and History', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
    ], width: 400);

    // AbSegmented uppercases; with no commits loaded the History segment
    // reads the same as the section header, so count them.
    expect(find.text('CHANGES · 1'), findsOneWidget);
    expect(find.text('CHANGES'), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.byTooltip('Stage All Changes'), findsOneWidget);
    expect(find.text('HISTORY'), findsOneWidget);

    await tester.tap(find.text('HISTORY'));
    await tester.pump();

    expect(find.text('a.dart'), findsNothing);
    expect(find.byTooltip('Stage All Changes'), findsNothing);
    expect(find.text('HISTORY'), findsNWidgets(2));
    // The commit box stays above the switch on either tab.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('staged changes and changes are listed apart', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
      {'path': 'b.dart', 'status': 'M', 'staged': true},
      {'path': 'b.dart', 'status': 'M', 'staged': false},
      {'path': 'c.dart', 'status': 'U', 'staged': false},
    ]);

    // VS Code's order: Staged Changes above Changes.
    expect(
      tester.getRect(find.text('STAGED CHANGES')).top,
      lessThan(tester.getRect(find.text('CHANGES')).top),
    );
    expect(find.text('a.dart'), findsOneWidget);
    // Partially staged: one row in each group.
    expect(find.text('b.dart'), findsNWidgets(2));
    expect(find.text('c.dart'), findsOneWidget);
  });

  testWidgets('only the group that has changes is shown', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    expect(find.text('STAGED CHANGES'), findsOneWidget);
    expect(find.text('CHANGES'), findsNothing);
  });

  testWidgets('desktop lists the two groups apart too', (tester) async {
    await withRowButtons(tester, () async {
      await pumpWithStatus(tester, [
        {'path': 'b.dart', 'status': 'M', 'staged': true},
        {'path': 'b.dart', 'status': 'M', 'staged': false},
      ]);

      expect(find.text('STAGED CHANGES'), findsOneWidget);
      expect(find.text('CHANGES'), findsOneWidget);
      expect(find.text('b.dart'), findsNWidgets(2));
    });
  });

  testWidgets('phone width with a clean tree shows History alone', (
    tester,
  ) async {
    await pumpWithStatus(tester, const [], width: 400);

    expect(find.textContaining('CHANGES'), findsNothing);
    expect(find.text('HISTORY'), findsOneWidget);
  });

  // The state the panel used to render as an anonymous red dot on one row: git
  // refuses the commit, so the header has to say why BEFORE a message is typed
  // into a sheet whose work is about to be thrown away.
  testWidgets('an unresolved conflict is counted in the header', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': '!', 'staged': false},
      {'path': 'b.dart', 'status': '!', 'staged': false},
      {'path': 'c.dart', 'status': 'A', 'staged': true},
    ]);

    expect(find.text('2 CONFLICTS'), findsOneWidget);
  });

  testWidgets('one conflict is counted in the singular', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': '!', 'staged': false},
      {'path': 'c.dart', 'status': 'A', 'staged': true},
    ]);

    expect(find.text('1 CONFLICT'), findsOneWidget);
  });

  testWidgets('Commit is refused while anything is unmerged', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': '!', 'staged': false},
      // Staged and committable on its own — which is exactly the case git
      // refuses, and the case that used to open the sheet.
      {'path': 'c.dart', 'status': 'A', 'staged': true},
    ]);

    expect(find.text('Commit (1)'), findsOneWidget);
    await tester.tap(find.text('Commit (1)'));
    await tester.pumpAndSettle();

    // No sheet, and nothing on the wire.
    expect(find.text('Commit changes'), findsNothing);
    expect(sentOfType('git:commit'), isNull);
  });

  testWidgets('Commit comes back once the conflict is resolved', (
    tester,
  ) async {
    // What `git add` on a conflicted path leaves behind: the "!" is gone and
    // an ordinary staged modification is what remains.
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    expect(find.textContaining('CONFLICT'), findsNothing);
    await tester.enterText(find.byType(TextField), 'merge');
    await tester.tap(find.text('Commit (1)'));
    await tester.pump();
    expect(sentOfType('git:commit')?['message'], 'merge');
    transport.emit('git:commit-result', {'projectId': 'p', 'success': true});
    await tester.pump();
  });

  // Staging IS how git resolves a conflict, so Stage All has to reach one —
  // Discard All does not, because restoring an unmerged path is not what
  // "discard" means anywhere else in this header.
  testWidgets('a conflict-only tree can be staged but not discarded', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': '!', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Discard All Changes'));
    await tester.pumpAndSettle();
    expect(sentOfType('git:discard'), isNull);

    await tester.tap(find.byTooltip('Stage All Changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stage All'));
    await tester.pumpAndSettle();
    expect(sentOfType('git:stage')?['files'], ['a.dart']);
  });

  // VS Code's own rule, and the reason the old "conflicts are simply excluded"
  // was wrong in both directions: it silently under-staged a Stage All the user
  // had asked for, and it left no bulk way out of a merge at all.
  testWidgets('Stage All confirms an unresolved conflict, then stages it all', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': '!', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Stage All Changes'));
    await tester.pumpAndSettle();
    // Nothing goes out until the question is answered.
    expect(sentOfType('git:stage'), isNull);
    expect(find.textContaining('b.dart'), findsWidgets);

    await tester.tap(find.text('Stage All'));
    await tester.pumpAndSettle();
    expect(sentOfType('git:stage')?['files'], ['a.dart', 'b.dart']);
  });

  testWidgets('Stage All stages nothing when the conflict confirm is refused', (
    tester,
  ) async {
    // Not even the clean half: the action pressed was "stage all of it", and
    // staging most of it is a different action nobody asked for.
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
      {'path': 'b.dart', 'status': '!', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Stage All Changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sentOfType('git:stage'), isNull);
  });

  testWidgets('Stage All never asks about a conflict with no markers left', (
    tester,
  ) async {
    // The bridge scanned the file and found it clean, so the user has already
    // done the work — asking again is a dialog on the everyday path.
    await pumpWithStatus(tester, [
      {
        'path': 'a.dart',
        'status': '!',
        'staged': false,
        'conflictKind': 'bothModified',
        'conflictResolved': true,
      },
    ]);

    await tester.tap(find.byTooltip('Stage All Changes'));
    await tester.pumpAndSettle();

    expect(find.text('Stage merge conflicts'), findsNothing);
    expect(sentOfType('git:stage')?['files'], ['a.dart']);
  });

  testWidgets('Mark Resolved stages a marker-free conflict without asking', (
    tester,
  ) async {
    await withRowButtons(tester, () async {
      await pumpWithStatus(tester, [
        {
          'path': 'a.dart',
          'status': '!',
          'staged': false,
          'conflictKind': 'bothModified',
          'conflictResolved': true,
        },
      ], width: 500);

      await hoverRow(tester, find.text('a.dart'));
      await tester.tap(find.byTooltip('Mark Resolved'));
      await tester.pumpAndSettle();

      expect(find.text('Mark resolved'), findsNothing);
      expect(sentOfType('git:stage')?['files'], ['a.dart']);
    });
  });

  testWidgets('a deletion conflict is asked about in its own terms', (
    tester,
  ) async {
    // There is no marker block in a delete-vs-edit conflict, so telling the
    // user to go looking for one is telling them to look for nothing.
    await withRowButtons(tester, () async {
      await pumpWithStatus(tester, [
        {
          'path': 'a.dart',
          'status': '!',
          'staged': false,
          'conflictKind': 'deletedByThem',
        },
      ], width: 500);

      await hoverRow(tester, find.text('a.dart'));
      await tester.tap(find.byTooltip('Mark Resolved'));
      await tester.pumpAndSettle();

      expect(find.textContaining('deleted'), findsWidgets);
      expect(find.textContaining('<<<<<<<'), findsNothing);
    });
  });

  testWidgets('Mark Resolved confirms, then stages the conflicted path', (
    tester,
  ) async {
    await withRowButtons(tester, () async {
      await pumpWithStatus(tester, [
        {'path': 'a.dart', 'status': '!', 'staged': false},
      ], width: 500);

      await hoverRow(tester, find.text('a.dart'));
      await tester.tap(find.byTooltip('Mark Resolved'));
      await tester.pumpAndSettle();
      // The dialog's confirm button — the row affordance itself is an icon.
      await tester.tap(find.text('Mark Resolved'));
      await tester.pumpAndSettle();

      // `git add` IS the resolution; there is no separate resolve verb on the
      // wire, and inventing one would need a bridge that speaks it.
      expect(sentOfType('git:stage')?['files'], ['a.dart']);
    });
  });

  // The narrowest column there is: a touch tablet's quarter-width context pane
  // during a merge, where the conflict notice, the diff totals and every
  // fixed-width control compete for one row. A RenderFlex overflow fails this
  // test on its own, both before and after the viewer replaces the column.
  testWidgets('a narrow column survives a merge, then offers the way back', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {
        'path': 'a.dart',
        'status': 'M',
        'staged': false,
        'additions': 2000,
        'deletions': 1000,
      },
      for (var i = 0; i < 12; i++)
        {'path': 'c$i.dart', 'status': '!', 'staged': false},
    ], width: 260);

    expect(find.text('12 CONFLICTS'), findsOneWidget);

    // Conflicts lead the tree, so a.dart is below the fold of this short list.
    await tester.tap(find.text('c0.dart'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back to changed files'), findsOneWidget);
  });

  testWidgets('changes are a flat list, each file beside its folder', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'app/lib/a.dart', 'status': 'M', 'staged': false},
      {'path': 'bridge/src/b.ts', 'status': 'M', 'staged': false},
      {'path': 'README.md', 'status': 'M', 'staged': false},
    ]);

    // No folder rows, and nothing to fold.
    expect(find.text('app'), findsNothing);
    expect(find.text('lib'), findsNothing);
    expect(find.text('a.dart  app/lib'), findsOneWidget);
    expect(find.text('b.ts  bridge/src'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.byTooltip('Collapse All Folders'), findsNothing);
  });

  testWidgets('a conflict leads the flat list', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a/first.dart', 'status': 'M', 'staged': false},
      {'path': 'z/conflict.dart', 'status': '!', 'staged': false},
    ]);

    expect(
      tester.getRect(find.text('conflict.dart  z')).top,
      lessThan(tester.getRect(find.text('first.dart  a')).top),
    );
  });

  // git reports an untracked directory it did not walk into with a trailing
  // slash; the row keeps that path verbatim, since every action hands it
  // straight back to git.
  testWidgets('an untracked directory is one row under its own name', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'build/', 'status': 'U', 'staged': false},
    ]);

    expect(find.text('build'), findsOneWidget);
  });

  Finder changesHeader() => find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_UnstagedGroupHeader',
  );

  testWidgets('a new git status re-derives the header', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': false},
    ]);
    expect(find.text('Commit'), findsOneWidget);

    // a.dart is partially staged: two entries, one changed path.
    transport.emit('git:status', {
      'projectId': 'p',
      'files': [
        {'path': 'a.dart', 'status': 'M', 'staged': true},
        {'path': 'a.dart', 'status': 'M', 'staged': false},
        {'path': 'b.dart', 'status': 'M', 'staged': false},
      ],
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Commit (1)'), findsOneWidget);
    expect(
      find.descendant(of: changesHeader(), matching: find.text('2')),
      findsOneWidget,
    );
  });

  testWidgets('a cancelled Mark Resolved stages nothing', (tester) async {
    await withRowButtons(tester, () async {
      await pumpWithStatus(tester, [
        {'path': 'a.dart', 'status': '!', 'staged': false},
      ], width: 500);

      await hoverRow(tester, find.text('a.dart'));
      await tester.tap(find.byTooltip('Mark Resolved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(sentOfType('git:stage'), isNull);
    });
  });
}
