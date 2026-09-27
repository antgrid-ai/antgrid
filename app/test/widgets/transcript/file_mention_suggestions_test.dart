import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/transcript/file_mention_suggestions.dart';

// Matching and ranking both moved bridge-side (`file:find` — see the
// [FileMention] typedef's doc comment); this widget is now pure display +
// tap over whatever entries it is handed, plus the loading/no-match/inactive
// states nothing else in the mention flow can show on its own.
void main() {
  Widget buildTestWidget({
    List<FileMention> entries = const [],
    int selectedIndex = 0,
    bool visible = true,
    bool loading = false,
    void Function(FileMention)? onPick,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: FileMentionSuggestions(
          entries: entries,
          selectedIndex: selectedIndex,
          onPick: onPick ?? (_) {},
          visible: visible,
          loading: loading,
        ),
      ),
    );
  }

  group('FileMentionSuggestions', () {
    testWidgets('renders nothing when not visible, even with entries', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          visible: false,
          entries: const [(path: 'README.md', isDir: false)],
        ),
      );

      expect(find.text('README.md'), findsNothing);
    });

    testWidgets('shows a searching status row while loading with no entries yet', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestWidget(loading: true, entries: const []));

      expect(find.text('Searching…'), findsOneWidget);
    });

    testWidgets('shows a no-match status row once search settles empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(loading: false, entries: const []),
      );

      expect(find.text('No matching files'), findsOneWidget);
    });

    testWidgets('renders a file entry bare and a directory entry with a trailing slash', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestWidget(
          entries: const [
            (path: 'lib/main.dart', isDir: false),
            (path: 'lib/src', isDir: true),
          ],
        ),
      );

      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('lib/src/'), findsOneWidget);
    });

    testWidgets('tapping a row picks that entry', (tester) async {
      FileMention? picked;
      await tester.pumpWidget(
        buildTestWidget(
          entries: const [
            (path: 'README.md', isDir: false),
            (path: 'lib', isDir: true),
          ],
          onPick: (e) => picked = e,
        ),
      );

      await tester.tap(find.text('lib/'));
      expect(picked, (path: 'lib', isDir: true));
    });
  });
}
