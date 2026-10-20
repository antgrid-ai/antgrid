import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/session_fork_dialog.dart';

SessionForkChoice? _answer;
bool _answered = false;

const _targets = [
  (tool: 'codex', label: 'Codex'),
  (tool: 'claude-code', label: 'Claude Code'),
];

/// Opens the dialog from a button, the way the kebab menu does, and records
/// what it answered into [_answer] / [_answered].
Future<void> _open(
  WidgetTester tester, {
  required bool isolatedSource,
  String? sourceTool,
  List<SessionForkTarget> targets = const [],
}) async {
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
                sourceTool: sourceTool,
                targets: targets,
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

Future<void> _pickClaude(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('fork-agent-selector')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Claude Code'));
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

  testWidgets('default copy for the same agent', (tester) async {
    await _open(tester, isolatedSource: true);
    // The uncommitted-changes consequence is the one thing a user cannot
    // recover by looking, so the default arm has to say it outright.
    expect(
      find.textContaining('Work you have not committed stays here'),
      findsOneWidget,
    );
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCopy);
    expect(_answer?.targetTool, isNull);
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
    expect(_answer?.workspace, forkWorkspaceCurrent);
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

  testWidgets('selecting another agent switches the default to This workspace', (
    tester,
  ) async {
    await _open(
      tester,
      isolatedSource: true,
      sourceTool: 'codex',
      targets: _targets,
    );
    await _pickClaude(tester);
    expect(
      find.textContaining('continues in this workspace with your uncommitted'),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCurrent);
    expect(_answer?.targetTool, 'claude-code');
  });

  testWidgets('a touched workspace is not overridden by an agent change', (
    tester,
  ) async {
    await _open(
      tester,
      isolatedSource: true,
      sourceTool: 'codex',
      targets: _targets,
    );
    await tester.tap(find.text('THIS WORKSPACE'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NEW WORKSPACE'));
    await tester.pumpAndSettle();
    await _pickClaude(tester);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCopy);
    expect(_answer?.targetTool, 'claude-code');
  });

  testWidgets('no agent row when targets is empty', (tester) async {
    await _open(tester, isolatedSource: true, sourceTool: 'codex');
    expect(find.byKey(const Key('fork-agent-selector')), findsNothing);
  });

  testWidgets('no agent row when sourceTool is null', (tester) async {
    await _open(tester, isolatedSource: true, targets: _targets);
    expect(find.byKey(const Key('fork-agent-selector')), findsNothing);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.targetTool, isNull);
  });

  testWidgets('cross-agent copy wording warns uncommitted changes stay behind', (
    tester,
  ) async {
    await _open(
      tester,
      isolatedSource: true,
      sourceTool: 'codex',
      targets: _targets,
    );
    await _pickClaude(tester);
    await tester.tap(find.text('NEW WORKSPACE'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('uncommitted changes stay behind'),
      findsOneWidget,
    );
  });
}
