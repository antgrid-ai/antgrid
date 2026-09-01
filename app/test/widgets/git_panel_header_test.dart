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
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/git_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
  Map<String, dynamic> dir(String name, String path, List<Object> children) => {
    'name': name,
    'path': path,
    'type': 'directory',
    'children': children,
  };
  Map<String, dynamic> file(String name, String path) => {
    'name': name,
    'path': path,
    'type': 'file',
  };

  /// The tree the fold tests need. Most tests here leave it out: without a
  /// `tree:full` the panel falls back to flat full-path rows (its documented
  /// unhydrated behaviour), which is enough to exercise the header but has no
  /// folder rows to fold.
  Map<String, dynamic> nestedTree() => dir('p', 'p', [
    dir('app', 'app', [
      dir('lib', 'app/lib', [file('a.dart', 'app/lib/a.dart')]),
    ]),
    dir('bridge', 'bridge', [
      dir('src', 'bridge/src', [file('b.ts', 'bridge/src/b.ts')]),
    ]),
    file('README.md', 'README.md'),
  ]);

  Future<void> pumpWithStatus(
    WidgetTester tester,
    List<Map<String, dynamic>> files, {
    double width = 800,
    Map<String, dynamic>? tree,
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
    if (tree != null) {
      transport.emit('tree:full', {'projectId': 'p', 'root': tree});
    }
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

  /// Brings a tree row's action buttons under the pointer — they are mounted
  /// at full size but `Visibility(visible: hovered)`, so they are findable
  /// without this and untappable until it runs.
  Future<void> hoverRow(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(target));
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

    // Scoped to the header's own title row: a.dart's own row carries the
    // same -4 badge, and the sub-tab strip above the header repeats the word
    // "Changes" too — neither must be mistaken for the header's totals.
    final header = find.byKey(gitChangesHeaderTitleKey);
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

    final header = find.byKey(gitChangesHeaderTitleKey);
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

    final titleRow = tester.getRect(find.byKey(gitChangesHeaderTitleKey));
    final commit = tester.getRect(find.byType(AbButton).last);
    expect(
      commit.top,
      greaterThanOrEqualTo(titleRow.bottom),
      reason: 'the actions belong on their own row, below the title',
    );

    // The title row spans the header (it sits in an Expanded), so its
    // trailing edge is where a right-aligned action has to end.
    expect(commit.right, closeTo(titleRow.right, 8));
  });

  testWidgets('a pane with room keeps the header on one line', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': 'M', 'staged': true},
    ]);

    final titleRow = tester.getRect(find.byKey(gitChangesHeaderTitleKey));
    final commit = tester.getRect(find.byType(AbButton).last);
    expect(commit.top, lessThan(titleRow.bottom));
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
    await tester.tap(find.text('Commit (1)'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
  });

  // Staging IS how git resolves a conflict, so Stage All has to reach one —
  // Revert All does not, because restoring an unmerged path to HEAD is not
  // what "revert" means anywhere else in this header.
  testWidgets('a conflict-only tree can be staged but not reverted', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'a.dart', 'status': '!', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Revert All Changes'));
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

  // The narrowest header there is: a touch tablet's quarter-width context pane,
  // stacked, with the diff viewer's back button taking part of the one line the
  // title shares with its totals and the conflict chip. Everything after the
  // title is fixed-width, so this is where a merge overflows the row — and a
  // RenderFlex overflow fails this test on its own.
  testWidgets('a narrow header survives a merge with the back button up', (
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

    // Opening a diff is what brings the back button into this same row.
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back to changed files'), findsOneWidget);
    expect(find.text('12 CONFLICTS'), findsOneWidget);
  });

  testWidgets('Collapse All folds every folder the changes nest under', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'app/lib/a.dart', 'status': 'M', 'staged': false},
      {'path': 'bridge/src/b.ts', 'status': 'M', 'staged': false},
      // Root-level: contributes no folder row at all.
      {'path': 'README.md', 'status': 'M', 'staged': false},
    ], tree: nestedTree());

    await tester.tap(find.byTooltip('Collapse All Folders'));
    await tester.pumpAndSettle();

    // Every ancestor, not just the leaf directories — folding only the deepest
    // level leaves the tree looking barely changed.
    expect(find.text('app'), findsOneWidget);
    expect(find.text('bridge'), findsOneWidget);
    expect(find.text('lib'), findsNothing);
    expect(find.text('src'), findsNothing);
    expect(find.text('a.dart'), findsNothing);
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('the fold control flips to Expand All once everything is shut', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'app/lib/a.dart', 'status': 'M', 'staged': false},
    ], tree: nestedTree());

    await tester.tap(find.byTooltip('Collapse All Folders'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse All Folders'), findsNothing);

    await tester.tap(find.byTooltip('Expand All Folders'));
    await tester.pumpAndSettle();
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.byTooltip('Collapse All Folders'), findsOneWidget);
  });

  testWidgets('a flat change set offers no fold control', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'README.md', 'status': 'M', 'staged': false},
    ]);

    expect(find.byTooltip('Collapse All Folders'), findsNothing);
    expect(find.byTooltip('Expand All Folders'), findsNothing);
  });

  // git reports an untracked directory it did not walk into with a trailing
  // slash, and the tree renders that path verbatim as a LEAF — so the name
  // before the slash is not a folder row, and counting it as one puts a fold
  // control on a tree with nothing to fold.
  testWidgets('an untracked directory contributes no foldable folder', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'build/', 'status': 'U', 'staged': false},
    ]);

    expect(find.byTooltip('Collapse All Folders'), findsNothing);
    expect(find.byTooltip('Expand All Folders'), findsNothing);
  });

  testWidgets('a conflict-only tree still offers the fold control', (
    tester,
  ) async {
    // Gated on its own, not on the write group beside it (where only Stage All
    // has anything to do on this tree) — a long conflict list is exactly when
    // folding is wanted, and a conflict nests like anything else.
    await pumpWithStatus(tester, [
      {'path': 'app/lib/a.dart', 'status': '!', 'staged': false},
    ]);

    expect(find.byTooltip('Collapse All Folders'), findsOneWidget);
  });

  testWidgets('a conflict folder is foldable like any other', (tester) async {
    await pumpWithStatus(tester, [
      {'path': 'app/lib/a.dart', 'status': '!', 'staged': false},
      {'path': 'bridge/src/b.ts', 'status': 'M', 'staged': false},
    ], tree: nestedTree());

    await tester.tap(find.byTooltip('Collapse All Folders'));
    await tester.pumpAndSettle();
    // Nothing is left unfolded, so the toggle can flip.
    expect(find.byTooltip('Expand All Folders'), findsOneWidget);
    expect(find.text('a.dart'), findsNothing);
    // The conflict-bearing branch still leads.
    expect(
      tester.getRect(find.text('app')).top,
      lessThan(tester.getRect(find.text('bridge')).top),
    );
  });

  testWidgets('folding a folder does not disturb the Files tab', (
    tester,
  ) async {
    await pumpWithStatus(tester, [
      {'path': 'app/lib/a.dart', 'status': 'M', 'staged': false},
    ]);

    await tester.tap(find.byTooltip('Collapse All Folders'));
    await tester.pumpAndSettle();

    // The two tabs keep separate fold state; a Git fold writing into
    // `expandedPaths` would close the folder the Explorer is sitting in.
    expect(
      session.fileService.currentState.expandedPaths,
      isEmpty,
      reason: 'the Git tab must not write the Files tab expansion set',
    );
    expect(
      session.fileService.currentState.git.collapsedPaths,
      contains('app/lib'),
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
