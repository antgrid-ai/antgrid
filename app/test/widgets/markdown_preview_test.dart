import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/markdown_preview.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:antgrid/widgets/viewer_support.dart';

void main() {
  setUpAll(() {
    // markdown_widget uses VisibilityDetector which has a debounce timer.
    // Setting updateInterval to zero makes callbacks fire synchronously in tests,
    // preventing the "pending timer" assertion failure on teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('renders heading text from markdown source', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            content: const FileContent(
              path: 'readme.md',
              content: '# Hello Antgrid',
              size: 15,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Hello Antgrid'), findsOneWidget);
  });

  testWidgets('opens in source view when a search line is set', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            content: const FileContent(
              path: 'readme.md',
              content: '# Hello\n\nworld',
              size: 14,
            ),
            searchLine: 3,
            searchQuery: 'world',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Search-to-line can't target a rendered preview, so it must land on source.
    expect(find.byType(FileContentViewer), findsOneWidget);
  });

  testWidgets('switches to source when a search hit lands on an already-open file',
      (tester) async {
    Widget host(int? line) => ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: MarkdownPreview(
                key: const ValueKey('readme.md'),
                content: const FileContent(
                  path: 'readme.md',
                  content: '# Hello\n\nworld',
                  size: 14,
                ),
                searchLine: line,
                searchQuery: line == null ? null : 'world',
              ),
            ),
          ),
        );

    // Opened normally (no search) → rendered preview, not source.
    await tester.pumpWidget(host(null));
    await tester.pumpAndSettle();
    expect(find.byType(FileContentViewer), findsNothing);

    // A search hit arrives for the same already-open path → must jump to source.
    await tester.pumpWidget(host(3));
    await tester.pumpAndSettle();
    expect(find.byType(FileContentViewer), findsOneWidget);
  });

  testWidgets('shows the modified banner in rendered preview mode',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            content: const FileContent(
              path: 'readme.md',
              content: '# Hello',
              size: 7,
            ),
            fileWasModified: true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ViewerModifiedBanner), findsOneWidget);
  });
}
