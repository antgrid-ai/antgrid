import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/design/widgets/ab_swipe_actions.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_tree_view.dart';

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
    void Function(String)? onToggleExpanded,
    void Function(String)? onFileSelected,
    void Function(String)? onStage,
    void Function(String)? onUnstage,
    void Function(String)? onDiscard,
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
          onToggleExpanded: onToggleExpanded ?? (_) {},
          onFileSelected: onFileSelected ?? (_) {},
          onStage: onStage,
          onUnstage: onUnstage,
          onDiscard: onDiscard,
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

    testWidgets('changesOnly still lists a change with no node in the tree', (
      tester,
    ) async {
      // A DELETED file is the everyday case: it is gone from disk, so the
      // tree — built from disk — can never carry a node for it. Without a
      // row it cannot be seen, staged, unstaged or diffed, while the header
      // still counts it once staged.
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

      // Full path as the label: there is no directory row above an orphan to
      // give a bare basename its context.
      expect(find.text('project/lib/deleted.dart'), findsOneWidget);
      // Still actionable — a staged deletion has to be unstageable. On this
      // (touch) platform that means the swipe tray, the row's only affordance.
      await tester.drag(
        find.text('project/lib/deleted.dart'),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unstage'), findsOneWidget);
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
    // hydration, so the Git tab routinely builds with changes but no tree.
    // Bailing on a null root there showed "No files available" beside a header
    // counting N changes; changesOnly can answer from the entries alone.
    testWidgets('changesOnly lists changes before the tree has loaded', (
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
      // Full paths, since there are no directory rows to give a bare name
      // its context — the same shape the orphan pass already uses.
      expect(find.text('project/lib/main.dart'), findsOneWidget);
      expect(find.text('project/README.md'), findsOneWidget);
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
          expect(find.byTooltip('Unstage Changes'), findsOneWidget);
          expect(find.byTooltip('Stage Changes'), findsNothing);
          // Discard on a staged-only row is a revert to HEAD, not a no-op —
          // the bridge drops the index entry before restoring (git.ts,
          // includeStaged).
          expect(find.byTooltip('Discard Changes'), findsOneWidget);
        },
      );
    });

    testWidgets('a conflicted file exposes no actions', (tester) async {
      var discarded = false;
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
        ),
        () async {
          expect(find.byTooltip('Stage Changes'), findsNothing);
          expect(find.byTooltip('Unstage Changes'), findsNothing);
          expect(find.byTooltip('Discard Changes'), findsNothing);
          expect(discarded, isFalse);
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
          ),
        );
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

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

    testWidgets('a conflicted file has no tray', (tester) async {
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
  });
}
