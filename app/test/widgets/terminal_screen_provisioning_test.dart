// While `worktree.setup` runs, the bridge HOLDS the session's `session:start`,
// so the entry reports `running: false` for the whole run with
// `setup.pendingStart` set. The terminal pane read that flag as "stopped" and
// offered a Start button whose press re-entered the same gate, changed nothing
// and reported nothing — a dead control under a banner saying the workspace was
// being prepared. These pin the pane's side of "a queued start is not a stopped
// session"; the auto-start paths that share the rule are pinned by
// `new_session_queued_start_test.dart` and `session_setup_test.dart`.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/terminal_screen.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _projectId = 'P';
const _sessionId = 's1';

SessionSetup _setup({required bool pendingStart}) => SessionSetup(
  state: 'running',
  stepIndex: 1,
  stepCount: 4,
  stepName: 'Install dependencies',
  terminalId: 'worktree-1:setup',
  pendingStart: pendingStart,
  startedAt: 1700,
);

SessionEntry _entry(SessionSetup? setup) => SessionEntry(
  id: _sessionId,
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  // The whole point: a queued session is indistinguishable from a stopped one
  // on this field alone, which is what the pane used to decide on.
  running: false,
  checkoutId: 'worktree-1',
  checkoutKind: 'managed-worktree',
  setup: setup,
);

/// Mounts the pane over a hand-seeded session list and a real per-project
/// session on a fake wire, so a press is asserted where it lands rather than
/// against a stub.
///
/// `terminalStateProvider` is overridden with an empty state: no tab means the
/// pane takes its transcript-less arm, which is the state a run reaches before
/// it has reported the PTY it spawned — and the one every assertion here is
/// about. The transcript arm is the banner's own `_buildLog` widget.
Future<FakeAgentTransport> pumpPane(
  WidgetTester tester,
  SessionSetup? setup,
) async {
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: _projectId,
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
  addTearDown(session.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWith((ref) => _projectId),
        projectSessionProvider(_projectId).overrideWith((ref) async => session),
        activeSessionIdProvider.overrideWith(
          () => ValueController<String?>(_sessionId),
        ),
        freshSessionsStateProvider.overrideWithValue(
          SessionsState(projectId: _projectId, sessions: [_entry(setup)]),
        ),
        terminalStateProvider.overrideWith(
          (ref) => Stream.value(const TerminalState()),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const Scaffold(body: TerminalScreen()),
      ),
    ),
  );
  // Two pumps: the project session and the terminal stream both resolve async.
  await tester.pump();
  await tester.pump();
  return transport;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets('a queued session is never called stopped', (tester) async {
    await pumpPane(tester, _setup(pendingStart: true));

    expect(find.text('Session stopped'), findsNothing);
    expect(find.text('Start'), findsNothing);
    expect(find.text('Preparing workspace…'), findsOneWidget);
    expect(find.text('Start agent now'), findsOneWidget);
    // The bridge has accepted `cancel` since the verb shipped and no surface
    // offered it; this pane is the one that does.
    expect(find.text('Cancel setup'), findsOneWidget);
  });

  // The gate is the ONLY thing this branch keys on. A session stopped for any
  // other reason — an explicit Stop, a crashed PTY — still owes the user the
  // button that respawns it.
  testWidgets('a genuinely stopped session still offers Start', (tester) async {
    await pumpPane(tester, _setup(pendingStart: false));

    expect(find.text('Session stopped'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Start agent now'), findsNothing);
  });

  // A shared session reports no setup at all, and must reach the same stopped
  // state as before this branch existed.
  testWidgets('a session with no setup is unaffected', (tester) async {
    await pumpPane(tester, null);

    expect(find.text('Session stopped'), findsOneWidget);
  });

  testWidgets('the release asks the bridge to skip the gate', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start agent now'));
    await tester.pump();
    await tester.pump();

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    expect(sent['sessionId'], _sessionId);
    expect(sent['action'], 'skip');

    // Answer it so nothing is left waiting on the reply timeout.
    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': true,
      'session': _entry(_setup(pendingStart: false)).toJson(),
    });
    await tester.pump();
  });

  testWidgets('cancelling asks the bridge to stop the run', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Cancel setup'));
    await tester.pump();
    await tester.pump();

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    expect(sent['action'], 'cancel');

    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': true,
      'session': _entry(_setup(pendingStart: false)).toJson(),
    });
    await tester.pump();
  });

  // Nothing else on screen moves when a setup verb is refused, so a refusal
  // that only reached the log would be indistinguishable from a dropped press.
  testWidgets('a refusal is named rather than swallowed', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start agent now'));
    await tester.pump();
    await tester.pump();

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': false,
      'error': 'This isolated session is being deleted.',
    });
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        "Couldn't start the agent — This isolated session is being deleted.",
      ),
      findsOneWidget,
    );
  });
}
