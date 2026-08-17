// app/test/widgets/git_commit_sheet_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/git_commit_sheet.dart';

void main() {
  testWidgets('commit button disabled until a message is present', (
    tester,
  ) async {
    String? committedMessage;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitCommitSheet(
            onCommit: (m) => committedMessage = m,
          ),
        ),
      ),
    );

    // Empty message -> tapping commit does nothing.
    await tester.tap(find.text('Commit'));
    await tester.pump();
    expect(committedMessage, isNull);

    // Enter a message -> commit fires with just the message; there's no
    // file checklist to select — staging already decided what's included.
    await tester.enterText(find.byType(TextField), 'my commit');
    await tester.pump();
    await tester.tap(find.text('Commit'));
    await tester.pump();

    expect(committedMessage, 'my commit');
  });

  testWidgets('whitespace-only message keeps Commit disabled', (
    tester,
  ) async {
    String? committedMessage;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitCommitSheet(
            onCommit: (m) => committedMessage = m,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();

    await tester.tap(find.text('Commit'));
    await tester.pump();
    expect(committedMessage, isNull);
  });

  testWidgets('Cancel dismisses without committing', (tester) async {
    var committed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitCommitSheet(onCommit: (_) => committed = true),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'msg');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(committed, isFalse);
  });
}
