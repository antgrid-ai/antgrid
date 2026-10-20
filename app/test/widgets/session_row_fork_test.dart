// The kebab's Fork carries the chosen agent to `session:fork` only for a bridge
// that said it honours `targetTool`: an older bridge's schema would strip the
// key and fork into the same agent while the dialog promised another.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';
import '../helpers/toast_host.dart';

const _projectId = 'p';

SessionEntry _entry({required bool handoff}) => SessionEntry(
  id: 'sess-1',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  forkSupported: true,
  handoffSupported: handoff,
  agentKey: handoff ? 'codex' : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<FakeAgentTransport> pumpRow(
    WidgetTester tester, {
    required bool handoff,
  }) async {
    final transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: _projectId,
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await transport.dispose(),
    );
    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);
    final container = ProviderContainer(
      overrides: [
        ...stores.overrides,
        selectedRegistrationIdProvider.overrideWithValue(_projectId),
        projectSessionProvider.overrideWith((ref, id) async => session),
        detectedToolsForProvider.overrideWith(
          (ref, target) async => const <String, String?>{
            'codex': 'Codex',
            'claude-code': 'Claude Code',
          },
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider(_projectId).future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: abToastHostBuilder,
          home: Scaffold(
            body: SessionRow(
              entryId: _projectId,
              session: _entry(handoff: handoff),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return transport;
  }

  Future<void> openFork(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Session actions'));
    // The menu resolves provider futures before it paints, which can need
    // real event-loop turns rather than fake-clock ones.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();
  }

  /// Refuses the fork so its reply timer and the resulting toast are drained.
  Future<void> refuseFork(
    WidgetTester tester,
    FakeAgentTransport transport,
  ) async {
    transport.emit('session:result', {
      'requestId': transport.sent.firstWhere(
        (m) => m['type'] == 'session:fork',
      )['requestId'],
      'ok': false,
      'error': 'refused',
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> sentFork(FakeAgentTransport transport) =>
      transport.sent.firstWhere((m) => m['type'] == 'session:fork');

  testWidgets('fork menu passes the chosen target agent', (tester) async {
    final transport = await pumpRow(tester, handoff: true);
    await openFork(tester);

    await tester.tap(find.byKey(const Key('fork-agent-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    final fork = sentFork(transport);
    expect(fork['targetTool'], 'claude-code');
    expect(fork['workspace'], 'current');

    await refuseFork(tester, transport);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("picking the session's own agent sends no targetTool", (
    tester,
  ) async {
    final transport = await pumpRow(tester, handoff: true);
    await openFork(tester);

    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();

    final fork = sentFork(transport);
    expect(fork.containsKey('targetTool'), isFalse);
    expect(fork['workspace'], 'copy');

    await refuseFork(tester, transport);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an old bridge (handoffSupported false) never sends targetTool', (
    tester,
  ) async {
    final transport = await pumpRow(tester, handoff: false);
    await openFork(tester);

    expect(find.byKey(const Key('fork-agent-selector')), findsNothing);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();

    expect(sentFork(transport).containsKey('targetTool'), isFalse);

    await refuseFork(tester, transport);
    await tester.pumpWidget(const SizedBox());
  });
}
