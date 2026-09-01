// Push and Pull are the two header actions that reach the network, and the
// only ones whose refusal is handed to the agent rather than to a toast — so
// these pin what each button sends, when each is dead, and that a failure
// leaves an affordance behind instead of vanishing with the snackbar.
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/git_panel.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  late FakeAgentTransport transport;
  late ProjectSession session;

  /// The `git:sync-state` shape the bridge sends. Defaults describe a branch
  /// level with its upstream, which is the state both buttons are dead in.
  Map<String, dynamic> syncState({
    int ahead = 0,
    int behind = 0,
    bool hasUpstream = true,
    bool hasRemote = true,
    String? branch = 'main',
  }) => {
    'projectId': 'p',
    'branch': branch,
    'remote': hasRemote ? 'origin' : null,
    'remoteBranch': hasRemote ? 'main' : null,
    'ahead': ahead,
    'behind': behind,
    'hasUpstream': hasUpstream,
    'hasRemote': hasRemote,
  };

  Future<void> pump(
    WidgetTester tester, {
    Map<String, dynamic>? sync,
    // Wide enough to stay off the header's stacked layout, so the actions sit
    // on one row where the tooltips are reachable.
    double width = 900,
  }) async {
    useInMemoryPrefs();
    transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    session = ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => transport.dispose(),
    );
    final c = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('p'),
        projectSessionProvider('p').overrideWith((ref) => session),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(session.close);
    c.read(visibleWorkspaceViewProvider.notifier).set(WorkspaceView.git);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(width: width, child: const GitPanel()),
          ),
        ),
      ),
    );
    // The panel eagerly claims (and, one post-frame callback later, sends)
    // its first `git:log` the moment its FileService is ready — see
    // GitPanel._maybeLoadHistory. Answering it is what keeps that send's
    // 15s reply-timeout timer from outliving the test; waiting for it to
    // actually appear in `sent` (rather than a fixed pump count) is what
    // keeps this robust against exactly how many frames that takes.
    for (
      var i = 0;
      i < 5 && transport.sent.every((m) => m['type'] != 'git:log');
      i++
    ) {
      await tester.pump();
    }
    transport.emit('git:log-result', {
      'projectId': 'p',
      'commits': const <Object?>[],
      'skip': 0,
      'hasMore': false,
    });
    transport.emit('git:status', {'projectId': 'p', 'files': const []});
    if (sync != null) transport.emit('git:sync-state', sync);
    await tester.pump();
    await tester.pump();
  }

  /// Land a `git:sync-result` for the op currently in flight.
  ///
  /// Every test that presses Push or Pull must end with one: the send arms a
  /// wall-clock action timer that only the reply cancels, and a test that
  /// disposes the tree with it still running fails on a pending Timer.
  Future<void> finishSync(
    WidgetTester tester, {
    String op = 'push',
    bool success = true,
    String? failureKind,
  }) async {
    transport.emit('git:sync-result', {
      'projectId': 'p',
      'op': op,
      'success': success,
      'branch': 'main',
      if (!success) 'error': 'rejected',
      'failureKind': ?failureKind,
    });
    await tester.pump();
  }

  Map<String, dynamic>? sentOfType(String type) {
    for (final m in transport.sent.reversed) {
      if (m['type'] == type) return m;
    }
    return null;
  }

  testWidgets('asks for the sync state on open, without probing the remote', (
    tester,
  ) async {
    await pump(tester);
    final asked = sentOfType('git:sync-status');
    expect(asked, isNotNull);
    // A probe is a network round trip; the hydrator must never make one, or
    // every reconnect costs an `ls-remote`.
    expect(asked!['probeRemote'], isNull);
  });

  testWidgets('hides the sync control entirely when there is no remote', (
    tester,
  ) async {
    await pump(tester, sync: syncState(hasRemote: false, hasUpstream: false));
    expect(find.byTooltip('Push'), findsNothing);
    expect(find.byTooltip('Pull'), findsNothing);
  });

  testWidgets('Push sends git:sync and names the op', (tester) async {
    await pump(tester, sync: syncState(ahead: 2));
    await tester.tap(find.byTooltip('Push 2 commits'));
    await tester.pump();
    expect(sentOfType('git:sync')?['op'], 'push');
    await finishSync(tester);
  });

  testWidgets('Pull sends git:sync and names the op', (tester) async {
    await pump(tester, sync: syncState(behind: 1));
    await tester.tap(find.byTooltip('Pull 1 commit'));
    await tester.pump();
    expect(sentOfType('git:sync')?['op'], 'pull');
    await finishSync(tester, op: 'pull');
  });

  testWidgets('both stay mounted but dead on a branch level with its upstream', (
    tester,
  ) async {
    await pump(tester, sync: syncState());
    // Mounted: a control that vanishes at zero moves its neighbour under a
    // finger already travelling toward it.
    expect(find.byTooltip('Push'), findsOneWidget);
    expect(find.byTooltip('Pull'), findsOneWidget);
    await tester.tap(find.byTooltip('Push'), warnIfMissed: false);
    await tester.tap(find.byTooltip('Pull'), warnIfMissed: false);
    await tester.pump();
    expect(sentOfType('git:sync'), isNull);
  });

  testWidgets('a branch with no upstream offers Publish instead of Push', (
    tester,
  ) async {
    await pump(tester, sync: syncState(hasUpstream: false));
    expect(find.text('Publish Branch'), findsOneWidget);
    // Push and Pull measure against an upstream that does not exist.
    expect(find.byTooltip('Push'), findsNothing);
    expect(find.byTooltip('Pull'), findsNothing);

    await tester.tap(find.text('Publish Branch'));
    await tester.pump();
    expect(sentOfType('git:sync')?['op'], 'push');
    await finishSync(tester);
  });

  testWidgets('a second press while a sync is in flight sends nothing', (
    tester,
  ) async {
    await pump(tester, sync: syncState(ahead: 1, behind: 1));
    await tester.tap(find.byTooltip('Push 1 commit'));
    await tester.pump();
    expect(transport.sent.where((m) => m['type'] == 'git:sync').length, 1);

    // Both are disabled together: they mutate the same branch, and a pull
    // racing a push is a state neither result can describe.
    await tester.tap(find.byTooltip('Pull 1 commit'), warnIfMissed: false);
    await tester.pump();
    expect(transport.sent.where((m) => m['type'] == 'git:sync').length, 1);
    await finishSync(tester);
  });

  testWidgets('a failure leaves a strip offering the agent', (tester) async {
    await pump(tester, sync: syncState(ahead: 2, behind: 3));
    await tester.tap(find.byTooltip('Push 2 commits'));
    await tester.pump();

    transport.emit('git:sync-result', {
      'projectId': 'p',
      'op': 'push',
      'success': false,
      'branch': 'main',
      'remote': 'origin',
      'remoteBranch': 'main',
      'error': 'rejected',
      'failureKind': 'not-fast-forward',
      'command': 'git push',
      'stderr': '! [rejected] main -> main (non-fast-forward)',
    });
    await tester.pump();

    expect(find.textContaining('Push failed'), findsOneWidget);
    expect(find.text('Ask agent to fix'), findsOneWidget);
    // The buttons come back — the failure ended the op.
    await tester.tap(find.byTooltip('Push 2 commits'));
    await tester.pump();
    expect(transport.sent.where((m) => m['type'] == 'git:sync').length, 2);
    await finishSync(tester);
  });

  testWidgets('a failure the user fixes themselves offers no agent handoff', (
    tester,
  ) async {
    await pump(tester, sync: syncState(ahead: 1));
    await tester.tap(find.byTooltip('Push 1 commit'));
    await tester.pump();

    transport.emit('git:sync-result', {
      'projectId': 'p',
      'op': 'push',
      'success': false,
      'branch': null,
      'error': 'HEAD is detached — check out a branch first',
      'failureKind': 'detached',
    });
    await tester.pump();
    // Settled by the frame above — the result IS what ends the op.

    expect(find.textContaining('Push failed'), findsOneWidget);
    // Sending the agent to run `git switch` is worse than the one tap the
    // branch picker already is.
    expect(find.text('Ask agent to fix'), findsNothing);
  });

  testWidgets('a success clears the strip and the counts follow the bridge', (
    tester,
  ) async {
    await pump(tester, sync: syncState(ahead: 2));
    await tester.tap(find.byTooltip('Push 2 commits'));
    await tester.pump();
    transport.emit('git:sync-result', {
      'projectId': 'p',
      'op': 'push',
      'success': false,
      'branch': 'main',
      'error': 'rejected',
      'failureKind': 'rejected',
    });
    await tester.pump();
    expect(find.text('Ask agent to fix'), findsOneWidget);

    // A later success must not leave the previous failure's offer standing.
    await tester.tap(find.byTooltip('Push 2 commits'));
    await tester.pump();
    transport.emit('git:sync-result', {
      'projectId': 'p',
      'op': 'push',
      'success': true,
      'branch': 'main',
      'summary': 'Pushed main to origin/main',
    });
    transport.emit('git:sync-state', syncState());
    await tester.pump();

    expect(find.text('Ask agent to fix'), findsNothing);
    expect(find.byTooltip('Push'), findsOneWidget);
  });

  testWidgets('the commit button still renders beside the sync control', (
    tester,
  ) async {
    // The header is width-constrained and the sync control ate part of that
    // budget; Commit is what must survive.
    await pump(tester, sync: syncState(ahead: 2, behind: 1));
    expect(find.byType(AbButton), findsWidgets);
    expect(find.text('Commit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
