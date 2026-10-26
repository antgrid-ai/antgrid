// The kebab's Fork carries the chosen agent to `session:fork` only for a bridge
// that said it honours `targetTool`: an older bridge's schema would strip the
// key and fork into the same agent while the dialog promised another.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
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
  agentKey: 'codex',
);

final _detectedFor = <SessionTarget>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    useInMemoryPrefs();
    _detectedFor.clear();
  });

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
        detectedToolsForProvider.overrideWith((ref, target) async {
          if (target != null) _detectedFor.add(target);
          return const <String, String?>{
            'codex': 'Codex',
            'claude-code': 'Claude Code',
          };
        }),
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

    // Away to another agent and back, so the own-agent pick is a real choice
    // and not the untouched default.
    await tester.tap(find.text('Claude Code'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('fork-agent-selector')),
        matching: find.text('Codex'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();

    final fork = sentFork(transport);
    expect(fork.containsKey('targetTool'), isFalse);
    expect(fork['workspace'], 'current');

    await refuseFork(tester, transport);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('agent detection is asked of the rows own machine', (
    tester,
  ) async {
    final transport = await pumpRow(tester, handoff: true);
    await openFork(tester);

    expect(_detectedFor.map((t) => t.registrationId), contains(_projectId));

    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    await refuseFork(tester, transport);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a fork reply that never comes is reported as outcome unknown', (
    tester,
  ) async {
    final transport = await pumpRow(tester, handoff: true);
    await openFork(tester);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();

    // Past the 90 s fork wait; the later list request lapses on its own timer.
    await tester.pump(const Duration(seconds: 91));
    await tester.pump();

    expect(
      find.textContaining('The fork may still be in progress'),
      findsOneWidget,
    );
    expect(transport.sent.where((m) => m['type'] == 'session:fork'), hasLength(1));
    expect(transport.sent.where((m) => m['type'] == 'session:list'), isNotEmpty);

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a second Fork while the first awaits its reply sends nothing', (
    tester,
  ) async {
    final transport = await pumpRow(tester, handoff: false);
    await openFork(tester);
    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();

    await openFork(tester);

    expect(find.textContaining('still being prepared'), findsOneWidget);
    expect(transport.sent.where((m) => m['type'] == 'session:fork'), hasLength(1));

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
