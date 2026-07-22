import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';

void main() {
  Widget buildTestWidget({
    FileContent? fileContent,
    bool isLoading = false,
    String? selectedFilePath,
    bool fileWasModified = false,
    VoidCallback? onRefreshContent,
    VoidCallback? onClose,
  }) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: FileContentViewer(
            fileContent: fileContent,
            isLoading: isLoading,
            selectedFilePath: selectedFilePath,
            fileWasModified: fileWasModified,
            onRefreshContent: onRefreshContent,
            onClose: onClose,
          ),
        ),
      ),
    );
  }

  group('FileContentViewer', () {
    testWidgets('shows loading indicator when isLoading is true', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestWidget(isLoading: true));
      expect(find.byType(AbLoading), findsOneWidget);
    });

    testWidgets('shows "Select a file to view" when content is null', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestWidget());
      expect(find.text('Select a file to view'), findsOneWidget);
    });

    testWidgets('shows deleted message for "not found" error', (tester) async {
      bool closeCalled = false;
      await tester.pumpWidget(
        buildTestWidget(
          fileContent: const FileContent(
            path: 'src/deleted.dart',
            size: 0,
            error: 'File not found',
          ),
          onClose: () => closeCalled = true,
        ),
      );

      expect(find.byType(AbEmptyState), findsOneWidget);
      expect(find.text('This file was deleted'), findsOneWidget);

      // Tap close button
      await tester.tap(find.text('Close'));
      expect(closeCalled, isTrue);
    });

    testWidgets('shows file name in header when content is available', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          fileContent: const FileContent(
            path: 'lib/main.dart',
            content: 'void main() {}',
            size: 15,
          ),
        ),
      );

      expect(find.text('main.dart'), findsOneWidget);
    });

    testWidgets('shows modified banner when fileWasModified is true', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          fileContent: const FileContent(
            path: 'lib/main.dart',
            content: 'void main() {}',
            size: 15,
          ),
          fileWasModified: true,
        ),
      );

      expect(find.text('File changed externally'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
    });

    testWidgets('does not show modified banner when fileWasModified is false', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          fileContent: const FileContent(
            path: 'lib/main.dart',
            content: 'void main() {}',
            size: 15,
          ),
          fileWasModified: false,
        ),
      );

      expect(find.text('File changed externally'), findsNothing);
    });

    testWidgets('shows generic error for non-deleted errors', (tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          fileContent: const FileContent(
            path: 'binary.bin',
            size: 1024,
            error: 'Binary file cannot be displayed',
          ),
        ),
      );

      expect(find.text('Binary file cannot be displayed'), findsOneWidget);
      expect(find.text('!'), findsOneWidget);
    });
  });
}
