import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/design/widgets/ab_swipe_actions.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_tree_view.dart';

import '../helpers/hover.dart';

void main() {
  FileNode makeTree() {
    return const FileNode(
      name: 'project',
      path: 'project',
      type: FileNodeType.directory,
      children: [
        FileNode(
          name: 'lib',
          path: 'project/lib',
          type: FileNodeType.directory,
          children: [
            FileNode(
              name: 'main.dart',
              path: 'project/lib/main.dart',
              type: FileNodeType.file,
              extension: 'dart',
            ),
            FileNode(
              name: 'utils.dart',
              path: 'project/lib/utils.dart',
              type: FileNodeType.file,
              extension: 'dart',
            ),
          ],
        ),
        FileNode(
          name: 'README.md',
          path: 'project/README.md',
          type: FileNodeType.file,
          extension: 'md',
        ),
      ],
    );
  }

  Widget buildTestWidget({
    FileNode? root,
    Set<String> expandedPaths = const {},
    String? selectedFilePath,
    String? filterQuery,
    List<GitFileStatusEntry> gitFileEntries = const [],
    bool changesOnly = false,
    Set<String> collapsedPaths = const {},
    void Function(String)? onToggleExpanded,
    void Function(String)? onFileSelected,
    void Function(String)? onStage,
    void Function(String)? onUnstage,
    void Function(String)? onDiscard,
    void Function(String)? onResolveConflict,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          root: root,
          expandedPaths: expandedPaths,
          selectedFilePath: selectedFilePath,
          filterQuery: filterQuery,
          gitFileEntries: gitFileEntries,
          changesOnly: changesOnly,
          collapsedPaths: collapsedPaths,
          onToggleExpanded: onToggleExpanded ?? (_) {},
          onFileSelected: onFileSelected ?? (_) {},
          onStage: onStage,
          onUnstage: onUnstage,
          onDiscard: onDiscard,
          onResolveConflict: onResolveConflict,
        ),
      ),
    );
  }

  group('FileTreeView', () {
    testWidgets('shows empty state when root is null', (tester) async {
      await tester.pumpWidget(buildTestWidget(root: null));

      expect(find.byType(AbEmptyState), findsOneWidget);
      expect(find.text('No files available'), findsOneWidget);
    });

    testWidgets('renders directory and file names', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(buildTestWidget(root: tree));

      // Root children: lib directory and README.md
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('tapping a directory calls onToggleExpanded', (tester) async {
      final tree = makeTree();
      String? tappedPath;

      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          onToggleExpanded: (path) => tappedPath = path,
        ),
      );

      await tester.tap(find.text('lib'));
      expect(tappedPath, 'project/lib');
    });

    testWidgets('tapping a file calls onFileSelected', (tester) async {
      final tree = makeTree();
      String? selectedPath;

      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          onFileSelected: (path) => selectedPath = path,
        ),
      );

      await tester.tap(find.text('README.md'));
      expect(selectedPath, 'project/README.md');
    });

    testWidgets('collapsed directory hides its children', (tester) async {
      final tree = makeTree();
      // lib is NOT in expandedPaths, so children should be hidden
      await tester.pumpWidget(buildTestWidget(root: tree));

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing);
      expect(find.text('utils.dart'), findsNothing);
    });

    testWidgets('expanded directory shows its children', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(root: tree, expandedPaths: {'project/lib'}),
      );

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('utils.dart'), findsOneWidget);
    });

    testWidgets('filter shows matching files across all directories', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(buildTestWidget(root: tree, filterQuery: 'main'));

      expect(find.text('main.dart'), findsOneWidget);
      // Non-matching files should not appear
      expect(find.text('utils.dart'), findsNothing);
      expect(find.text('README.md'), findsNothing);
    });

    testWidgets('a filename wider than the panel does not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(220, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          FileNode(
            name:
                'a_very_long_filename_that_will_not_fit_in_a_narrow_panel.dart',
            path:
                'project/a_very_long_filename_that_will_not_fit_in_a_narrow_panel.dart',
            type: FileNodeType.file,
            extension: 'dart',
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(root: tree));

      expect(tester.takeException(), isNull);
    });

    testWidgets('undecorated when no git entries are passed (Files tab)', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(root: tree, expandedPaths: {'project/lib'}),
      );

      expect(find.textContaining('+'), findsNothing);
      expect(find.textContaining('-'), findsNothing);
    });

    testWidgets('a changed file shows a +added/-deleted badge', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 3,
              deletions: 1,
            ),
          ],
        ),
      );

      expect(find.text('+3'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
    });

    testWidgets('a directory carries no decoration of its own', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 1,
              deletions: 1,
            ),
          ],
        ),
      );

      expect(find.text('lib'), findsOneWidget);
      // main.dart's own badge is the only decoration — no dot on lib itself.
      expect(find.byType(AbStatusDot), findsNothing);
    });

    testWidgets('changesOnly prunes unchanged files and directories', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          changesOnly: true,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 1,
              deletions: 1,
            ),
          ],
        ),
      );

      // main.dart changed and lib is its ancestor — both show.
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      // utils.dart (unchanged sibling) and README.md (unchanged, no
      // ancestor relation to the change) are both hidden entirely.
      expect(find.text('utils.dart'), findsNothing);
      expect(find.text('README.md'), findsNothing);
    });

    testWidgets('a collapsed folder hides its files but keeps its own row', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          collapsedPaths: const {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 3,
              deletions: 1,
            ),
            GitFileStatusEntry(
              path: 'project/README.md',
              status: 'M',
              staged: false,
              additions: 2,
              deletions: 0,
            ),
          ],
        ),
      );

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing);
      // A sibling outside the folded folder is untouched by the fold.
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets(
      'a folded folder hides its files rather than relocating them',
      (tester) async {
        // A fold must not push a file anywhere else in the list: reappearing
        // at depth 0 under its full path is the fold undone, and the same file
        // listed twice the moment the folder reopens.
        await tester.pumpWidget(
          buildTestWidget(
            root: makeTree(),
            changesOnly: true,
            collapsedPaths: const {'project/lib'},
            gitFileEntries: const [
              GitFileStatusEntry(
                path: 'project/lib/main.dart',
                status: 'M',
                staged: false,
                additions: 3,
                deletions: 1,
              ),
            ],
          ),
        );

        expect(find.text('project/lib/main.dart'), findsNothing);
        expect(find.text('main.dart'), findsNothing);
      },
    );

    testWidgets('a folded folder totals what it is hiding', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          collapsedPaths: const {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 3,
              deletions: 1,
            ),
            // Twice, staged and unstaged, carrying the SAME combined counts —
            // summing entries instead of paths would report +14.
            GitFileStatusEntry(
              path: 'project/lib/utils.dart',
              status: 'M',
              staged: false,
              additions: 4,
              deletions: 2,
            ),
            GitFileStatusEntry(
              path: 'project/lib/utils.dart',
              status: 'M',
              staged: true,
              additions: 4,
              deletions: 2,
            ),
          ],
        ),
      );

      expect(find.text('+7'), findsOneWidget);
      expect(find.text('-3'), findsOneWidget);
    });

    testWidgets('a fold over a conflict says so on the folder row', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          collapsedPaths: const {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: '!',
              staged: false,
            ),
            GitFileStatusEntry(
              path: 'project/lib/utils.dart',
              status: 'M',
              staged: false,
              additions: 4,
              deletions: 2,
            ),
          ],
        ),
      );

      expect(find.text('main.dart'), findsNothing);
      expect(find.text('utils.dart'), findsNothing);
      // The conflict outranks the line counts it is folded in with, and takes
      // the same dot the file row would have.
      expect(find.byType(AbStatusDot), findsOneWidget);
      expect(find.text('+4'), findsNothing);
    });

    testWidgets('an open folder carries no rollup of its own', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 3,
              deletions: 1,
            ),
          ],
        ),
      );

      // The file's own +3/-1 and nothing else — no second copy on `lib`.
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
    });

    testWidgets('a changesOnly folder row toggles instead of doing nothing', (
      tester,
    ) async {
      String? toggled;
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          onToggleExpanded: (p) => toggled = p,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 1,
              deletions: 1,
            ),
          ],
        ),
      );

      await tester.tap(find.text('lib'));
      await tester.pump();
      expect(toggled, 'project/lib');
    });

    testWidgets('changesOnly nests a change the file tree has no node for', (
      tester,
    ) async {
      // A DELETED file is the everyday case: it is gone from disk, so the
      // tree — built from disk — can never carry a node for it. It gets the
      // same nested row as everything else because this list is built from the
      // change PATHS, not from that tree.
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          changesOnly: true,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/deleted.dart',
              status: 'D',
              staged: true,
              additions: 0,
              deletions: 7,
            ),
          ],
          onUnstage: (_) {},
        ),
      );

      // Nested under the folders it was deleted out of, not a flat full path.
      expect(find.text('project/lib/deleted.dart'), findsNothing);
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('deleted.dart'), findsOneWidget);
      // Still actionable — a staged deletion has to be unstageable. On this
      // (touch) platform that means the swipe tray, the row's only affordance.
      await tester.drag(find.text('deleted.dart'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(find.text('Unstage'), findsOneWidget);
    });

    testWidgets('an untracked directory keeps the path git reported', (
      tester,
    ) async {
      // `git status` reports a directory it did not walk into as `assets/`,
      // trailing slash and all. That exact string is what the row's entries are
      // keyed by and what every action hands back to git, so a path rebuilt
      // from its segments would decorate nothing and act on something nobody
      // reported.
      String? opened;
      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          onFileSelected: (p) => opened = p,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'assets/',
              status: 'U',
              staged: false,
              additions: 4,
            ),
          ],
        ),
      );

      expect(find.text('assets'), findsOneWidget);
      // Its own badge, which it only gets if the row found its entry.
      expect(find.text('+4'), findsOneWidget);

      await tester.tap(find.text('assets'));
      expect(opened, 'assets/');
    });

    testWidgets(
      'changesOnly shows the changed file without expanding its directory',
      (tester) async {
        final tree = makeTree();
        await tester.pumpWidget(
          buildTestWidget(
            root: tree,
            changesOnly: true,
            // expandedPaths deliberately empty — pruning must not depend on it.
            gitFileEntries: const [
              GitFileStatusEntry(
                path: 'project/lib/main.dart',
                status: 'M',
                staged: false,
              ),
            ],
          ),
        );

        expect(find.text('main.dart'), findsOneWidget);
      },
    );

    // `git:status` is a push while `root` waits on a lazy per-checkout tree
    // hydration, so the Git tab routinely builds with changes but no tree. The
    // list it renders then has to be the SAME list — same rows, same nesting —
    // or the whole tab visibly rearranges itself once the tree lands.
    testWidgets('changesOnly nests changes before the tree has loaded', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          root: null,
          changesOnly: true,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
            ),
            GitFileStatusEntry(
              path: 'project/README.md',
              status: 'M',
              staged: false,
            ),
          ],
        ),
      );

      expect(find.text('No files available'), findsNothing);
      expect(find.text('project/lib/main.dart'), findsNothing);
      expect(find.text('lib'), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
    });

    // The tree is what the file list is pruned FROM everywhere else, so the
    // one thing that proves the Git tab no longer depends on it is the same
    // change set rendering identically with and without it.
    testWidgets('changesOnly renders the same rows with or without the tree', (
      tester,
    ) async {
      const entries = [
        GitFileStatusEntry(
          path: 'project/lib/main.dart',
          status: 'M',
          staged: false,
        ),
        GitFileStatusEntry(
          path: 'project/README.md',
          status: 'M',
          staged: false,
        ),
      ];
      List<String> rowLabels() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();

      await tester.pumpWidget(
        buildTestWidget(root: null, changesOnly: true, gitFileEntries: entries),
      );
      final withoutTree = rowLabels();

      await tester.pumpWidget(
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          gitFileEntries: entries,
        ),
      );

      expect(rowLabels(), withoutTree);
    });

    testWidgets('a null root still shows the empty state outside changesOnly', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestWidget(root: null, changesOnly: false));

      expect(find.text('No files available'), findsOneWidget);
    });

    testWidgets('changesOnly with no changes shows the empty state', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(buildTestWidget(root: tree, changesOnly: true));

      expect(find.byType(AbEmptyState), findsOneWidget);
      expect(find.text('No changed files'), findsOneWidget);
    });

    // The row's icon buttons are a DESKTOP affordance: they live behind hover,
    // which a touch device has no way to produce — there the swipe tray is the
    // whole story (see the touch group below). The override has to be cleared
    // before the body returns; a tearDown runs too late for the framework's
    // debug-variable assert.
    Future<void> withDesktop(
      WidgetTester tester,
      Widget widget,
      Future<void> Function() body,
    ) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await tester.pumpWidget(widget);
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('an unstaged file exposes Stage and Discard, not Unstage', (
      tester,
    ) async {
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
            ),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) {},
        ),
        () async {
          await hoverRow(tester, find.text('main.dart'));

          expect(find.byTooltip('Stage Changes'), findsOneWidget);
          expect(find.byTooltip('Discard Changes'), findsOneWidget);
          expect(find.byTooltip('Unstage Changes'), findsNothing);
        },
      );
    });

    testWidgets('a staged file exposes Unstage and Discard, not Stage', (
      tester,
    ) async {
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: true,
            ),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) {},
        ),
        () async {
          await hoverRow(tester, find.text('main.dart'));

          expect(find.byTooltip('Unstage Changes'), findsOneWidget);
          expect(find.byTooltip('Stage Changes'), findsNothing);
          // Discard on a staged-only row is a revert to HEAD, not a no-op —
          // the bridge drops the index entry before restoring (git.ts,
          // includeStaged).
          expect(find.byTooltip('Discard Changes'), findsOneWidget);
        },
      );
    });

    testWidgets('a conflicted file exposes only Mark Resolved', (tester) async {
      var discarded = false;
      String? resolved;
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: '!',
              staged: false,
            ),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) => discarded = true,
          onResolveConflict: (p) => resolved = p,
        ),
        () async {
          // Revealed first: a conflicted row withholds the other three even
          // when everything it could offer is on screen, which is a claim an
          // unrevealed row cannot make.
          await hoverRow(tester, find.text('main.dart'));

          expect(find.byTooltip('Stage Changes'), findsNothing);
          expect(find.byTooltip('Unstage Changes'), findsNothing);
          expect(find.byTooltip('Discard Changes'), findsNothing);
          expect(discarded, isFalse);

          await tester.tap(find.byTooltip('Mark Resolved'));
          await tester.pump();
          expect(resolved, 'project/lib/main.dart');
        },
      );
    });

    testWidgets('a conflict sorts ahead of its siblings, still nested', (
      tester,
    ) async {
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          gitFileEntries: const [
            // main.dart comes first in the tree; the CONFLICT is what has to
            // put utils.dart above it.
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: 'M',
              staged: false,
              additions: 2,
              deletions: 0,
            ),
            GitFileStatusEntry(
              path: 'project/lib/utils.dart',
              status: '!',
              staged: false,
            ),
          ],
        ),
        () async {
          // Still under `lib`, still a basename — only the order moved.
          expect(find.text('lib'), findsOneWidget);
          expect(
            tester.getRect(find.text('utils.dart')).top,
            lessThan(tester.getRect(find.text('main.dart')).top),
          );
          expect(
            tester.getRect(find.text('lib')).top,
            lessThan(tester.getRect(find.text('utils.dart')).top),
          );
        },
      );
    });

    testWidgets(
      'a folder holding a conflict sorts ahead of one that does not',
      (tester) async {
        await withDesktop(
          tester,
          buildTestWidget(
            root: makeTree(),
            changesOnly: true,
            gitFileEntries: const [
              // README.md is a depth-0 sibling of `lib` and comes after it in
              // the tree; the conflict BELOW lib is what lifts the folder.
              GitFileStatusEntry(
                path: 'project/README.md',
                status: '!',
                staged: false,
              ),
              GitFileStatusEntry(
                path: 'project/lib/main.dart',
                status: 'M',
                staged: false,
                additions: 2,
                deletions: 0,
              ),
            ],
          ),
          () async {
            expect(
              tester.getRect(find.text('README.md')).top,
              lessThan(tester.getRect(find.text('lib')).top),
            );
          },
        );
      },
    );

    testWidgets('a conflict deep in a folder lifts every folder above it', (
      tester,
    ) async {
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/README.md',
              status: 'M',
              staged: false,
              additions: 1,
              deletions: 0,
            ),
            GitFileStatusEntry(
              path: 'project/lib/utils.dart',
              status: '!',
              staged: false,
            ),
          ],
        ),
        () async {
          // The conflict is two levels down; `lib` has to carry the priority
          // up to depth 0 or the row it leads to is still below README.md.
          expect(
            tester.getRect(find.text('lib')).top,
            lessThan(tester.getRect(find.text('README.md')).top),
          );
        },
      );
    });

    testWidgets('a conflict keeps the plain status dot', (tester) async {
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          changesOnly: true,
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: '!',
              staged: false,
            ),
          ],
        ),
        () async {
          expect(find.byType(AbStatusDot), findsOneWidget);
        },
      );
    });

    testWidgets('a resolve callback nobody passes offers nothing', (
      tester,
    ) async {
      await withDesktop(
        tester,
        buildTestWidget(
          root: makeTree(),
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(
              path: 'project/lib/main.dart',
              status: '!',
              staged: false,
            ),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) {},
        ),
        () async {
          await hoverRow(tester, find.text('main.dart'));

          expect(find.byTooltip('Mark Resolved'), findsNothing);
        },
      );
    });
  });

  // On touch the swipe tray is the ONLY per-file affordance, so these cover
  // both halves of that bargain: every action has to be reachable through it,
  // and no action may fire from a gesture the user did not mean.
  //
  // Leftward only: rightward dismisses a surface everywhere in this app (the
  // mobile drawer, the agent page's back fling, the touch tablet's sidebar),
  // so a row may not claim it — which is why all three actions share one tray.
  group('FileTreeView touch swipe tray', () {
    // The platform override has to be cleared before the test body returns —
    // the framework asserts every foundation debug variable is unset by then,
    // which a tearDown runs too late to satisfy.
    Future<void> withChangedFile(
      WidgetTester tester, {
      void Function(String)? onStage,
      void Function(String)? onUnstage,
      void Function(String)? onDiscard,
      void Function(String)? onResolveConflict,
      void Function(String)? onFileSelected,
      String status = 'M',
      bool staged = false,
      required Future<void> Function() body,
    }) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await tester.pumpWidget(
          buildTestWidget(
            root: makeTree(),
            expandedPaths: {'project/lib'},
            gitFileEntries: [
              GitFileStatusEntry(
                path: 'project/lib/main.dart',
                status: status,
                staged: staged,
              ),
            ],
            onFileSelected: onFileSelected,
            onStage: onStage ?? (_) {},
            onUnstage: onUnstage ?? (_) {},
            onDiscard: onDiscard ?? (_) {},
            onResolveConflict: onResolveConflict,
          ),
        );
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    // These render the PLAIN tree, not changesOnly, so every row — conflicts
    // included — keeps its basename; hoisting is a changesOnly behaviour.
    Finder row() => find.text('main.dart');

    /// Reveals the tray the way a finger does — a drag past the open
    /// threshold, well short of the full-swipe one.
    Future<void> openTray(WidgetTester tester) async {
      await tester.drag(row(), const Offset(-120, 0));
      await tester.pumpAndSettle();
    }

    // On a phone the tree is the second page of the shell's PageView, whose
    // own horizontal drag is how the user gets back to the agent. Nothing
    // arbitrates that for the row — the two meet in the gesture arena, where
    // the row wins by being the deeper recognizer — so this is what stands
    // between staging a file and being thrown back to the agent page.
    testWidgets('a row swipe beats the PageView the phone puts it in', (
      tester,
    ) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PageView(
                controller: controller,
                children: [
                  const SizedBox.expand(),
                  FileTreeView(
                    root: makeTree(),
                    expandedPaths: const {'project/lib'},
                    gitFileEntries: const [
                      GitFileStatusEntry(
                        path: 'project/lib/main.dart',
                        status: 'M',
                        staged: false,
                      ),
                    ],
                    onToggleExpanded: (_) {},
                    onFileSelected: (_) {},
                    onStage: (_) {},
                    onUnstage: (_) {},
                    onDiscard: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        controller.jumpToPage(1);
        await tester.pumpAndSettle();

        await openTray(tester);

        expect(find.text('Stage'), findsOneWidget);
        expect(
          controller.page,
          1,
          reason: 'the page must not slide back to the agent',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('touch rows carry no action buttons at all', (tester) async {
      await withChangedFile(
        tester,
        body: () async {
          expect(find.byTooltip('Stage Changes'), findsNothing);
          expect(find.byTooltip('Unstage Changes'), findsNothing);
          expect(find.byTooltip('Discard Changes'), findsNothing);
          // What the row is FOR still shows: the diff stat.
          expect(find.byType(AbSwipeActions), findsWidgets);
        },
      );
    });

    testWidgets('a swipe reveals both actions and Stage runs on tap', (
      tester,
    ) async {
      String? staged;
      await withChangedFile(
        tester,
        onStage: (path) => staged = path,
        body: () async {
          await openTray(tester);
          expect(find.text('Stage'), findsOneWidget);
          expect(find.text('Revert'), findsOneWidget);

          await tester.tap(find.text('Stage'));
          await tester.pumpAndSettle();
          expect(staged, 'project/lib/main.dart');
          // Tray closes behind the action it ran.
          expect(find.text('Stage'), findsNothing);
        },
      );
    });

    testWidgets('a staged row offers Unstage in the same slot', (tester) async {
      String? unstaged;
      await withChangedFile(
        tester,
        staged: true,
        onUnstage: (path) => unstaged = path,
        body: () async {
          await openTray(tester);
          expect(find.text('Stage'), findsNothing);

          await tester.tap(find.text('Unstage'));
          await tester.pumpAndSettle();
          expect(unstaged, 'project/lib/main.dart');
        },
      );
    });

    // Discard lost its button when touch rows lost theirs, so the tray is the
    // only way to reach it — that it is reachable at all is the point here.
    testWidgets('Revert runs from the tray', (tester) async {
      String? discarded;
      await withChangedFile(
        tester,
        onDiscard: (path) => discarded = path,
        body: () async {
          await openTray(tester);
          await tester.tap(find.text('Revert'));
          await tester.pumpAndSettle();
          expect(discarded, 'project/lib/main.dart');
        },
      );
    });

    testWidgets('a short swipe snaps back and runs nothing', (tester) async {
      var acted = false;
      await withChangedFile(
        tester,
        onStage: (_) => acted = true,
        onDiscard: (_) => acted = true,
        body: () async {
          await tester.drag(row(), const Offset(-20, 0));
          await tester.pumpAndSettle();

          expect(acted, isFalse);
          expect(find.text('Stage'), findsNothing);
        },
      );
    });

    // The full-swipe shortcut exists for the reversible action only. Past the
    // tray the row travels at half the finger, so this drag is deliberately
    // longer than the threshold it has to cross.
    testWidgets('a full swipe stages, and never reverts', (tester) async {
      String? staged;
      var discarded = false;
      await withChangedFile(
        tester,
        onStage: (path) => staged = path,
        onDiscard: (_) => discarded = true,
        body: () async {
          await tester.drag(row(), const Offset(-780, 0));
          await tester.pumpAndSettle();

          expect(staged, 'project/lib/main.dart');
          expect(discarded, isFalse);
        },
      );
    });

    // Rightward belongs to whatever surface the row sits on — the tablet's
    // context pane closes on it — so the row must not move, let alone act.
    testWidgets('a rightward swipe does nothing', (tester) async {
      var acted = false;
      await withChangedFile(
        tester,
        onStage: (_) => acted = true,
        body: () async {
          await tester.fling(row(), const Offset(500, 0), 1200);
          await tester.pumpAndSettle();

          expect(acted, isFalse);
          expect(find.text('Stage'), findsNothing);
        },
      );
    });

    testWidgets('an open tray takes the row tap instead of opening the file', (
      tester,
    ) async {
      String? opened;
      await withChangedFile(
        tester,
        onFileSelected: (path) => opened = path,
        body: () async {
          await openTray(tester);
          // Tapped by position, not by the label: an open tray has carried the
          // row's own content off the left edge, which is the point.
          final rect = tester.getRect(
            find.ancestor(of: row(), matching: find.byType(AbSwipeActions)),
          );
          await tester.tapAt(Offset(rect.left + 40, rect.center.dy));
          await tester.pumpAndSettle();

          expect(opened, isNull);
          expect(find.text('Stage'), findsNothing);
        },
      );
    });

    // The row that owns a tray absorbs its own tap to close it; every OTHER
    // row has to close it too, or a tray stays latched open on a row nobody is
    // touching — the same stale affordance a scroll would leave behind.
    testWidgets('a tap on another row closes the open tray', (tester) async {
      String? selected;
      await withChangedFile(
        tester,
        onFileSelected: (path) => selected = path,
        body: () async {
          await openTray(tester);
          expect(find.text('Stage'), findsOneWidget);

          await tester.tap(find.text('utils.dart'));
          await tester.pumpAndSettle();

          expect(find.text('Stage'), findsNothing);
          // …and still selects, rather than spending the tap on the dismissal.
          expect(selected, 'project/lib/utils.dart');
        },
      );
    });

    testWidgets('a conflicted file has no tray without a resolve handler', (
      tester,
    ) async {
      var acted = false;
      await withChangedFile(
        tester,
        status: '!',
        onStage: (_) => acted = true,
        onDiscard: (_) => acted = true,
        body: () async {
          await tester.drag(row(), const Offset(-780, 0));
          await tester.pumpAndSettle();

          expect(acted, isFalse);
          expect(find.text('Revert'), findsNothing);
        },
      );
    });

    testWidgets('a conflicted row trays Resolve, and only Resolve', (
      tester,
    ) async {
      var acted = false;
      String? resolved;
      await withChangedFile(
        tester,
        status: '!',
        onStage: (_) => acted = true,
        onDiscard: (_) => acted = true,
        onResolveConflict: (p) => resolved = p,
        body: () async {
          await openTray(tester);

          expect(find.text('Stage'), findsNothing);
          expect(find.text('Unstage'), findsNothing);
          expect(find.text('Revert'), findsNothing);

          await tester.tap(find.text('Resolve'));
          await tester.pumpAndSettle();
          expect(resolved, 'project/lib/main.dart');
          expect(acted, isFalse);
        },
      );
    });
  });
}
