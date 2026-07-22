// app/test/widgets/git_commit_sheet_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/git_commit_sheet.dart';

void main() {
  testWidgets('commit button disabled until message and a file are present',
      (tester) async {
    String? committedMessage;
    List<String>? committedFiles;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitCommitSheet(
            changedFiles: const {'a.dart': 'M', 'b.dart': '?'},
            onCommit: (m, f) {
              committedMessage = m;
              committedFiles = f;
            },
          ),
        ),
      ),
    );

    // Empty message -> tapping commit does nothing.
    await tester.tap(find.text('Commit'));
    await tester.pump();
    expect(committedMessage, isNull);

    // Enter a message -> commit fires with all files selected by default.
    await tester.enterText(find.byType(TextField), 'my commit');
    await tester.pump();
    await tester.tap(find.text('Commit'));
    await tester.pump();

    expect(committedMessage, 'my commit');
    expect(committedFiles, containsAll(<String>['a.dart', 'b.dart']));
  });

  testWidgets('deselect all files disables Commit', (tester) async {
    String? committedMessage;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitCommitSheet(
            changedFiles: const {'a.dart': 'M', 'b.dart': '?'},
            onCommit: (m, f) {
              committedMessage = m;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'msg');
    await tester.pump();

    // Deselect both files by tapping each row (the path Text sits inside the
    // row's GestureDetector, so tapping it toggles selection).
    await tester.tap(find.text('a.dart'));
    await tester.pump();
    await tester.tap(find.text('b.dart'));
    await tester.pump();

    // Message present but no file selected -> Commit stays disabled.
    await tester.tap(find.text('Commit'));
    await tester.pump();
    expect(committedMessage, isNull);
  });

  testWidgets('partial selection commits only selected files', (tester) async {
    List<String>? committedFiles;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitCommitSheet(
            changedFiles: const {'a.dart': 'M', 'b.dart': '?'},
            onCommit: (m, f) {
              committedFiles = f;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'partial');
    await tester.pump();

    // Deselect only b.dart, leaving a.dart selected.
    await tester.tap(find.text('b.dart'));
    await tester.pump();

    await tester.tap(find.text('Commit'));
    await tester.pump();

    expect(committedFiles, equals(<String>['a.dart']));
    expect(committedFiles, isNot(contains('b.dart')));
  });
}
