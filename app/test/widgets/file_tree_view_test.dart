import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
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
    void Function(String)? onToggleExpanded,
    void Function(String)? onFileSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FileTreeView(
          root: root,
          expandedPaths: expandedPaths,
          selectedFilePath: selectedFilePath,
          filterQuery: filterQuery,
          onToggleExpanded: onToggleExpanded ?? (_) {},
          onFileSelected: onFileSelected ?? (_) {},
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
  });
}
