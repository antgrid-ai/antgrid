import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/session_fork_dialog.dart';

SessionForkChoice? _answer;
bool _answered = false;

const _codex = (tool: 'codex', label: 'Codex');
const _targets = [_codex, (tool: 'claude-code', label: 'Claude Code')];

/// Opens the dialog from a button, the way the kebab menu does, and records
/// what it answered into [_answer] / [_answered].
Future<void> _open(
  WidgetTester tester, {
  required bool isolatedSource,
  SessionForkTarget? source,
  Future<List<SessionForkTarget>>? targets,
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
                source: source,
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

Future<void> _openWithAgents(
  WidgetTester tester, {
  bool isolatedSource = true,
}) => _open(
  tester,
  isolatedSource: isolatedSource,
  source: _codex,
  targets: Future.value(_targets),
);

Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _pickClaude(WidgetTester tester) => _pick(tester, 'Claude Code');

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

  testWidgets('a fork continues in this workspace by default', (tester) async {
    await _openWithAgents(tester);
    expect(
      find.text('Same files as this session, uncommitted changes included.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCurrent);
    expect(_answer?.targetTool, 'codex');
  });

  testWidgets('changing agent leaves the workspace where it was', (
    tester,
  ) async {
    await _openWithAgents(tester);
    await _pickClaude(tester);
    expect(find.text('Continue'), findsOneWidget);
    await _pick(tester, 'Codex');
    expect(find.text('Fork'), findsOneWidget);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCurrent);
    expect(_answer?.targetTool, 'codex');
  });

  testWidgets('a new workspace names the work it leaves behind', (
    tester,
  ) async {
    await _open(tester, isolatedSource: true);
    await tester.tap(find.text('NEW WORKSPACE'));
    await tester.pumpAndSettle();
    // Whether uncommitted changes come along is the one thing a user cannot
    // see by looking, so the arm has to say it outright.
    expect(
      find.text('Starts from the last commit, without uncommitted changes.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCopy);
  });

  // "This workspace" means something different for a session on the main tree:
  // the fork lands where every ordinary session already is.
  testWidgets('a main-tree session is told it shares the main directory', (
    tester,
  ) async {
    await _open(tester, isolatedSource: false);
    expect(
      find.text('Your main directory, uncommitted changes included.'),
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

  testWidgets('another agent continues with the uncommitted changes', (
    tester,
  ) async {
    await _openWithAgents(tester);
    await _pickClaude(tester);
    expect(
      find.text('Same files as this session, uncommitted changes included.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCurrent);
    expect(_answer?.targetTool, 'claude-code');
  });

  testWidgets('a new workspace survives an agent change', (tester) async {
    await _openWithAgents(tester);
    await tester.tap(find.text('NEW WORKSPACE'));
    await tester.pumpAndSettle();
    await _pickClaude(tester);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(_answer?.workspace, forkWorkspaceCopy);
    expect(_answer?.targetTool, 'claude-code');
  });

  testWidgets('no agent row without a source', (tester) async {
    await _open(
      tester,
      isolatedSource: true,
      targets: Future.value(_targets),
    );
    expect(find.byKey(const Key('fork-agent-selector')), findsNothing);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.targetTool, isNull);
  });

  // The list's presence is the bridge's answer, known before the dialog opens;
  // only its contents wait on the machine.
  testWidgets('the agent list fills in when the machine answers', (
    tester,
  ) async {
    final targets = Completer<List<SessionForkTarget>>();
    await _open(
      tester,
      isolatedSource: true,
      source: _codex,
      targets: targets.future,
    );
    expect(find.byKey(const Key('fork-agent-selector')), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Checking installed agents…'), findsOneWidget);
    expect(find.text('Claude Code'), findsNothing);

    targets.complete(_targets);
    await tester.pumpAndSettle();
    expect(find.text('Checking installed agents…'), findsNothing);
    await _pickClaude(tester);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('a machine with only the source agent says so', (tester) async {
    await _open(
      tester,
      isolatedSource: true,
      source: _codex,
      targets: Future.value(const [_codex]),
    );
    expect(
      find.text('No other agent installed.'),
      findsOneWidget,
    );
  });

  testWidgets('a machine that cannot list its agents says so', (tester) async {
    final targets = Completer<List<SessionForkTarget>>();
    await _open(
      tester,
      isolatedSource: true,
      source: _codex,
      targets: targets.future,
    );
    targets.completeError(TimeoutException('no answer'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't list installed agents."), findsOneWidget);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(_answer?.targetTool, 'codex');
  });
}
