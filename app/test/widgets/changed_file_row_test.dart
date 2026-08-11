// The git panel's changed-file rows, which have to survive a filename wider
// than the panel — a narrow context panel plus a long test filename is the
// everyday case, and it used to paint the yellow overflow hatching.
import 'package:antgrid/widgets/file_tree_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpChangedFiles(
  WidgetTester tester, {
  required Map<String, String> statuses,
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: FileTreeView(
            root: null,
            expandedPaths: const {},
            gitFileStatuses: statuses,
            showChangedOnly: true,
            onToggleExpanded: (_) {},
            onFileSelected: (_) {},
            onDiscard: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a filename wider than the panel does not overflow', (
    tester,
  ) async {
    await _pumpChangedFiles(
      tester,
      width: 260,
      statuses: const {
        'app/test/widgets/window_title_bar_contents_test.dart': 'M',
        'app/lib/services/app_settings_service.dart': 'M',
        'app/lib/providers/providers.dart': 'M',
      },
    );

    expect(tester.takeException(), isNull);
    expect(find.text('3 changed files'), findsOneWidget);
  });

  // The name is the identifying part, so it must be the LAST thing shortened:
  // the directory is what gives way first.
  testWidgets('the directory yields before the filename does', (tester) async {
    await _pumpChangedFiles(
      tester,
      width: 260,
      statuses: const {'app/lib/providers/some/deep/nesting/providers.dart': 'M'},
    );

    expect(tester.takeException(), isNull);
    // The row is one paragraph, name first: the ellipsis eats the tail, so the
    // directory is what gets cut and the name survives whole.
    final paragraphs = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText())
        .toList();
    expect(
      paragraphs.any((t) => t.startsWith('providers.dart')),
      isTrue,
      reason: 'name must lead the span run, directory trails it',
    );
  });

  testWidgets('a short row renders name and directory together', (
    tester,
  ) async {
    await _pumpChangedFiles(
      tester,
      width: 400,
      statuses: const {'lib/a.dart': 'M'},
    );

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('a.dart', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('lib', findRichText: true), findsOneWidget);
  });
}
