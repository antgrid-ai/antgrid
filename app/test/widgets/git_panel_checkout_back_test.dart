// An isolated session runs in a managed worktree, so the git panel is built
// from that checkout's FileService. Back has to unwind the same one: resolving
// the main checkout's service instead clears a tree nobody is looking at and
// still reports the press handled, which reads as a dead back button.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/navigation/back_intent.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/services/file_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/git_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// The active session is what [focusedCheckoutIdProvider] reads the checkout
/// off, so an entry carrying a worktree id is how a test says "isolated".
const _worktreeSession = SessionEntry(
  id: 'session-1',
  name: 'Session',
  createdAt: 1,
  lastUsedAt: 1,
  archived: false,
  running: true,
  checkoutId: 'wt-1',
  checkoutKind: 'managed-worktree',
  checkoutBranch: 'antgrid/session-1',
);

Future<ProjectSession> _buildFakeSession() async {
  useInMemoryPrefs();
  final t = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'test',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => t.dispose(),
  );
}

void main() {
  late ProviderContainer c;
  late ProjectSession session;
  late FileService worktree;
  late FileService main;

  Future<void> pumpGitPanel(WidgetTester tester) async {
    session = await _buildFakeSession();
    c = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
        activeSessionProvider.overrideWithValue(_worktreeSession),
      ],
    );
    addTearDown(c.dispose);
    // requestDiff arms a wall-clock latch per checkout; closing the session
    // settles every one of them, which the test binding checks for on teardown.
    addTearDown(session.close);
    c.read(visibleWorkspaceViewProvider.notifier).set(WorkspaceView.git);
    worktree = session.servicesForCheckout('wt-1').fileService;
    main = session.fileService;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 800, child: GitPanel())),
        ),
      ),
    );
    await tester.pump();
  }

  // Both checkouts are left viewing a file, so the assertion distinguishes
  // "unwound the right one" from "unwound one of them".
  testWidgets('back leaves the git view of the session checkout, not main', (
    tester,
  ) async {
    await pumpGitPanel(tester);
    worktree.gitViewFile('worktree.dart');
    main.gitViewFile('main.dart');
    await tester.pump();

    expect(resolveBackIntent(c), isTrue);

    expect(worktree.currentState.git.viewingPath, isNull);
    expect(main.currentState.git.viewingPath, 'main.dart');
  });

  testWidgets('back closes the diff of the session checkout, not main', (
    tester,
  ) async {
    await pumpGitPanel(tester);
    worktree.requestDiff('worktree.dart');
    main.requestDiff('main.dart');
    await tester.pump();

    expect(resolveBackIntent(c), isTrue);

    expect(worktree.currentState.git.diffPath, isNull);
    expect(main.currentState.git.diffPath, 'main.dart');

    // Back settled the worktree's diff latch by closing its diff; main's is
    // still armed on wall-clock, and the binding fails a test that leaves a
    // timer pending. Closing it here is teardown, not part of the assertion —
    // addTearDown runs after that check.
    main.clearDiff();
  });
}
