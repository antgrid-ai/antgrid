import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_viewer_router.dart';
import 'package:antgrid/widgets/markdown_preview.dart';
import 'package:antgrid/widgets/svg_preview.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';

Widget _host(FileContent? fc, {bool loading = false}) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: FileViewerRouter(
        fileContent: fc,
        isLoading: loading,
        selectedFilePath: fc?.path,
      ),
    ),
  ),
);

void main() {
  setUpAll(() {
    // markdown_widget uses VisibilityDetector which fires a 500ms debounce
    // timer. Zero interval makes callbacks synchronous so pumpAndSettle drains
    // without leaving pending timers on teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('routes .md to MarkdownPreview', (tester) async {
    await tester.pumpWidget(
      _host(const FileContent(path: 'a.md', content: '# Hi', size: 4)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownPreview), findsOneWidget);
  });

  testWidgets('routes .svg to SvgPreview', (tester) async {
    await tester.pumpWidget(
      _host(const FileContent(path: 'a.svg', content: '<svg/>', size: 6)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPreview), findsOneWidget);
  });

  testWidgets('routes code to FileContentViewer', (tester) async {
    await tester.pumpWidget(
      _host(
        const FileContent(
          path: 'main.dart',
          content: 'void main(){}',
          size: 13,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FileContentViewer), findsOneWidget);
  });

  testWidgets('delegates error to FileContentViewer', (tester) async {
    await tester.pumpWidget(
      _host(const FileContent(path: 'a.md', size: 0, error: 'Binary file')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FileContentViewer), findsOneWidget);
    expect(find.byType(MarkdownPreview), findsNothing);
  });

  testWidgets('uses a per-file key so state resets when path changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const FileContent(path: 'a.md', content: '# A', size: 3)),
    );
    await tester.pumpAndSettle();
    final firstKey = tester
        .widget<MarkdownPreview>(find.byType(MarkdownPreview))
        .key;
    expect(firstKey, const ValueKey('a.md'));

    await tester.pumpWidget(
      _host(const FileContent(path: 'b.md', content: '# B', size: 3)),
    );
    await tester.pumpAndSettle();
    final secondKey = tester
        .widget<MarkdownPreview>(find.byType(MarkdownPreview))
        .key;
    expect(secondKey, const ValueKey('b.md'));
    expect(secondKey, isNot(firstKey));
  });
}
