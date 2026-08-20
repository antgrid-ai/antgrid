import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:re_editor/re_editor.dart';

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

  group('FileContentViewer scrolling', () {
    const longLine =
        "final String greeting = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbcccccccccccccccccccccccccccc';";
    final wideFile = FileContent(
      path: 'lib/a.dart',
      size: 100,
      content: List.generate(60, (i) => '$longLine // $i').join('\n'),
    );

    Widget host() => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: FileContentViewer(
                fileContent: wideFile,
                selectedFilePath: 'lib/a.dart',
              ),
            ),
          ),
        ),
      ),
    );

    ScrollPosition axis(WidgetTester tester, AxisDirection direction) => tester
        .state<ScrollableState>(
          find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == direction,
          ),
        )
        .position;

    // The editor auto-scrolls when a SELECTION drag reaches past the viewport.
    // Armed on any drag, that turned reading a long line near the top or the
    // bottom of the pane into a fast vertical scroll: the file ran away
    // upwards under a gesture that asked to go sideways.
    testWidgets('a sideways drag near the edge does not scroll vertically', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      // Parked mid-file, so an upward auto-scroll has somewhere to go —
      // at offset zero this test could not fail.
      axis(tester, AxisDirection.down).jumpTo(200);
      await tester.pump();

      final rect = tester.getRect(find.byType(CodeEditor));
      final gesture = await tester.startGesture(
        Offset(rect.left + 200, rect.top + 15),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-16, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(axis(tester, AxisDirection.right).pixels, greaterThan(0));
      expect(axis(tester, AxisDirection.down).pixels, 200);
    });

    // The line-number gutter is inside the editor's vertical scrollable but
    // outside its horizontal one, so a sideways scroll landing on it had only
    // the vertical axis to go to.
    testWidgets('a sideways scroll over the line numbers stays sideways', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(CodeEditor));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(Offset(rect.left + 8, rect.center.dy)),
      );
      await tester.sendEventToBinding(pointer.scroll(const Offset(60, 6)));
      await tester.pumpAndSettle();

      expect(axis(tester, AxisDirection.right).pixels, greaterThan(0));
      expect(axis(tester, AxisDirection.down).pixels, 0);
    });
  });
}
