import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/session_fork_dialog.dart';

String? _answer;
bool _answered = false;

/// Opens the dialog from a button, the way the kebab menu does, and records
/// what it answered into [_answer] / [_answered].
Future<void> _open(WidgetTester tester, {required bool isolatedSource}) async {
  _answer = null;
  _answered = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              _answer = await promptSessionFork(
                context,
                isolatedSource: isolatedSource,
              );
              _answered = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('both workspaces are readable before anything is touched', (
    tester,
  ) async {
    await _open(tester, isolatedSource: true);
    // The whole reason this is a segmented control and not the confirm dialog's
    // opt-in toggle: a mode choice has to show what it is not. Upper case
    // because that is how AbSegmented paints every cell label.
    expect(find.text('NEW WORKSPACE'), findsOneWidget);
    expect(find.text('THIS WORKSPACE'), findsOneWidget);
  });

  testWidgets('the default fork takes a workspace of its own', (tester) async {
    await _open(tester, isolatedSource: true);
    // The uncommitted-changes consequence is the one thing a user cannot
    // recover by looking, so the default arm has to say it outright.
    expect(
      find.textContaining('Work you have not committed stays here'),
      findsOneWidget,
    );
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer, forkWorkspaceCopy);
  });

  testWidgets('picking this workspace names the concurrency it buys', (
    tester,
  ) async {
    await _open(tester, isolatedSource: true);
    await tester.tap(find.text('THIS WORKSPACE'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Both sessions work in this one directory'),
      findsOneWidget,
    );
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer, forkWorkspaceCurrent);
  });

  // "This workspace" means something different for a session on the main tree:
  // the fork lands where every ordinary session already is, and the work it
  // would not see sits in the main directory rather than in a private checkout.
  testWidgets('a main-tree session is told where its work stays', (
    tester,
  ) async {
    await _open(tester, isolatedSource: false);
    expect(
      find.textContaining(
        'Work you have not committed stays in your main directory',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('THIS WORKSPACE'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('alongside every other session there'),
      findsOneWidget,
    );
  });

  testWidgets('cancelling forks nothing', (tester) async {
    await _open(tester, isolatedSource: true);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_answered, isTrue);
    expect(_answer, isNull);
  });
}
