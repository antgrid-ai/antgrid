// Tapping a stopped isolated session whose checkout has vanished used to be a
// silent no-op: the bridge refuses `session:start` with a WORKTREE_MISSING code,
// and SessionsService collapsed every mutation refusal to null. The row is the
// primary place such a session is tapped, so it is where the refusal has to
// speak — and the workspace must not move onto a session that never spawned.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:antgrid/widgets/session_start_refusal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _projectId = 'p';
const _sessionId = 'sess-1';

/// A stopped managed-worktree session the bridge has already flagged as having
/// lost its checkout. The flag is NOT what gates the affordance — the tap is
/// always attempted (see the row) — it is just the shape a user meets this in.
const _entry = SessionEntry(
  id: _sessionId,
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  checkoutId: 'wt-1',
  checkoutKind: 'managed-worktree',
  checkoutState: 'missing',
);

Future<ProjectSession> _session(
  FakeAgentTransport transport,
  CachedSessionsStore cache,
) async => ProjectSession(
  projectId: _projectId,
  transport: transport,
  mode: ProjectSessionMode.local,
  cachedSessionsStore: cache,
  onClose: () async => await transport.dispose(),
);

/// Answers the row's `session:start` once it has been sent.
Future<void> _answerStart(
  WidgetTester tester,
  FakeAgentTransport transport, {
  required bool ok,
}) async {
  await tester.pump();
  await tester.pump();
  final sent = transport.sent.firstWhere((m) => m['type'] == 'session:start');
  transport.emit('session:result', {
    'requestId': sent['requestId'],
    'ok': ok,
    if (!ok) ...{
      'errorCode': 'WORKTREE_MISSING',
      'error': 'The isolated worktree is no longer available.',
    },
    if (ok) 'session': _entry.copyWith(running: true).toJson(),
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<ProviderContainer> pumpRow(
    WidgetTester tester,
    FakeAgentTransport transport,
  ) async {
    final cache = await CachedSessionsStore.open();
    final session = await _session(transport, cache);
    // The row's own tap asks whether this entry is relay-reached, which reads
    // the recent-agents store — a throw-by-default provider, and a throw there
    // is swallowed as a failed activation, i.e. a tap that does nothing.
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);
    final container = ProviderContainer(
      overrides: [
        ...stores.overrides,
        selectedRegistrationIdProvider.overrideWithValue(_projectId),
        projectSessionProvider.overrideWith((ref, id) async => session),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider(_projectId).future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SessionRow(entryId: _projectId, session: _entry),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('a refused start is reported and does not take the workspace', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpRow(tester, transport);
    // Parked off the workspace so "the surface didn't move" is an observation,
    // not the default value the provider already held.
    container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.newSession);

    await tester.tap(find.byType(SessionRow));
    await _answerStart(tester, transport, ok: false);

    expect(
      find.text(
        sessionStartRefusalCopy(
          'WORKTREE_MISSING',
          'The isolated worktree is no longer available.',
        ),
      ),
      findsOneWidget,
    );
    // A session whose PTY never spawned must not become the workspace — that
    // reads as the app having lost the agent's output.
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.newSession,
    );
    expect(
      transport.sent.where((m) => m['type'] == 'session:focus'),
      isEmpty,
      reason: 'the refusal short-circuits before focus',
    );

    // Drain the 8s snack bar so its dismiss timer can't outlive the test.
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an accepted start still focuses and moves the surface', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpRow(tester, transport);
    container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.newSession);

    await tester.tap(find.byType(SessionRow));
    await _answerStart(tester, transport, ok: true);

    expect(find.textContaining('Restore its folder'), findsNothing);
    expect(
      container.read(workbenchSurfaceProvider),
      WorkbenchSurface.workspace,
    );
    expect(
      transport.sent.where((m) => m['type'] == 'session:focus'),
      isNotEmpty,
    );

    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
