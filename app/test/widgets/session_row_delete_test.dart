// A drawer delete hides the row's kebab while the request is in flight, so the
// bridge's answer arrives after the menu that asked is gone. A refusal must
// still reach the user — as the force-delete question for uncommitted work, as
// a toast for everything else — rather than ending with nothing on screen.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
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

const _isolated = SessionEntry(
  id: 'sess-1',
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  checkoutId: 'co-1',
  checkoutKind: 'managed-worktree',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<FakeAgentTransport> pumpRow(WidgetTester tester) async {
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
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider(_projectId).future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: abToastHostBuilder,
          home: const Scaffold(
            body: SessionRow(entryId: _projectId, session: _isolated),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return transport;
  }

  /// Kebab → Delete → confirm. Ends with the request sent and the row marked
  /// as deleting, which pulses forever — so no pumpAndSettle past this point.
  Future<String> confirmDelete(
    WidgetTester tester,
    FakeAgentTransport transport,
  ) async {
    await tester.tap(find.byTooltip('Session actions'));
    // The menu resolves provider futures before it paints, which can need
    // real event-loop turns rather than fake-clock ones.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete isolated session?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The precondition the fix exists for: the kebab that opened the menu is
    // gone by the time the bridge answers.
    expect(find.byTooltip('Session actions'), findsNothing);
    expect(find.text('DELETING'), findsOneWidget);

    return transport.sent.lastWhere(
          (m) => m['type'] == 'session:delete',
        )['requestId']
        as String;
  }

  Future<void> refuse(
    WidgetTester tester,
    FakeAgentTransport transport,
    String requestId, {
    required String code,
    required String message,
  }) async {
    transport.emit('session:result', {
      'requestId': requestId,
      'ok': false,
      'error': message,
      'errorCode': code,
      'checkoutId': 'co-1',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('uncommitted changes ask the force-delete question', (
    tester,
  ) async {
    final transport = await pumpRow(tester);
    final requestId = await confirmDelete(tester, transport);

    await refuse(
      tester,
      transport,
      requestId,
      code: 'WORKTREE_DIRTY',
      message: 'The isolated worktree has uncommitted changes.',
    );

    expect(
      find.text('Delete isolated session with uncommitted changes?'),
      findsOneWidget,
    );
    expect(find.text('Force delete'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      transport.sent.where((m) => m['type'] == 'session:delete'),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('force delete retries once with force set', (tester) async {
    final transport = await pumpRow(tester);
    final requestId = await confirmDelete(tester, transport);
    await refuse(
      tester,
      transport,
      requestId,
      code: 'WORKTREE_DIRTY',
      message: 'The isolated worktree has uncommitted changes.',
    );

    await tester.tap(find.text('Force delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final deletes = transport.sent
        .where((m) => m['type'] == 'session:delete')
        .toList();
    expect(deletes, hasLength(2));
    expect(deletes.last['force'], isTrue);

    await refuse(
      tester,
      transport,
      deletes.last['requestId'] as String,
      code: 'WORKTREE_DELETE_FAILED',
      message: 'Still could not delete it.',
    );
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('any other refusal is reported as a toast', (tester) async {
    final transport = await pumpRow(tester);
    final requestId = await confirmDelete(tester, transport);

    await refuse(
      tester,
      transport,
      requestId,
      code: 'WORKTREE_DELETE_HELD',
      message: 'node.exe (pid 4242) is holding the working directory.',
    );

    expect(find.textContaining('pid 4242'), findsOneWidget);

    // Past the toast's display window so no timer outlives the test.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
  });
}
