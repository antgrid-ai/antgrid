import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
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
            name: 'a_very_long_filename_that_will_not_fit_in_a_narrow_panel.dart',
            path: 'project/a_very_long_filename_that_will_not_fit_in_a_narrow_panel.dart',
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

    testWidgets('a changed file shows a +added/-deleted badge', (
      tester,
    ) async {
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

    testWidgets('a directory carries no decoration of its own', (
      tester,
    ) async {
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
      // Still actionable — a staged deletion has to be unstageable.
      expect(find.byTooltip('Unstage Changes'), findsOneWidget);
    });

    testWidgets('changesOnly shows the changed file without expanding its directory', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          changesOnly: true,
          // expandedPaths deliberately empty — pruning must not depend on it.
          gitFileEntries: const [
            GitFileStatusEntry(path: 'project/lib/main.dart', status: 'M', staged: false),
          ],
        ),
      );

      expect(find.text('main.dart'), findsOneWidget);
    });

    testWidgets('changesOnly with no changes shows the empty state', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(buildTestWidget(root: tree, changesOnly: true));

      expect(find.byType(AbEmptyState), findsOneWidget);
      expect(find.text('No changed files'), findsOneWidget);
    });

    testWidgets('an unstaged file exposes Stage and Discard, not Unstage', (
      tester,
    ) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(path: 'project/lib/main.dart', status: 'M', staged: false),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) {},
        ),
      );

      expect(find.byTooltip('Stage Changes'), findsOneWidget);
      expect(find.byTooltip('Discard Changes'), findsOneWidget);
      expect(find.byTooltip('Unstage Changes'), findsNothing);
    });

    testWidgets('a staged file exposes only Unstage', (tester) async {
      final tree = makeTree();
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(path: 'project/lib/main.dart', status: 'M', staged: true),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) {},
        ),
      );

      expect(find.byTooltip('Unstage Changes'), findsOneWidget);
      expect(find.byTooltip('Stage Changes'), findsNothing);
      expect(find.byTooltip('Discard Changes'), findsNothing);
    });

    testWidgets('a conflicted file exposes no actions', (tester) async {
      final tree = makeTree();
      var discarded = false;
      await tester.pumpWidget(
        buildTestWidget(
          root: tree,
          expandedPaths: {'project/lib'},
          gitFileEntries: const [
            GitFileStatusEntry(path: 'project/lib/main.dart', status: '!', staged: false),
          ],
          onStage: (_) {},
          onUnstage: (_) {},
          onDiscard: (_) => discarded = true,
        ),
      );

      expect(find.byTooltip('Stage Changes'), findsNothing);
      expect(find.byTooltip('Unstage Changes'), findsNothing);
      expect(find.byTooltip('Discard Changes'), findsNothing);
      expect(discarded, isFalse);
    });
  });
}
