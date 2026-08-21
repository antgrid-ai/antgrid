// A remote Recents delete cannot see the bridge's `deleting` flag, so the only
// thing that can strand its row is the app guessing. `accepted` guesses
// nothing: it re-reads the list and lets the bridge's own answer prune the row.
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/services/sessions_service.dart'
    show SessionOperationException;
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'M';
const _projectId = 'p1';
const _registrationId = 'M.p1';
const _sessionId = 's1';

SessionEntry _session() => const SessionEntry(
  id: _sessionId,
  name: 'Session 1',
  createdAt: 1,
  lastUsedAt: 2,
  archived: false,
  running: false,
);

RecentSessionRow _row() => RecentSessionRow(
  session: _session(),
  origin: const RecentOrigin(
    isLocal: false,
    registrationId: _registrationId,
    projectId: _projectId,
    machineUuid: _machineUuid,
    projectName: 'proj',
    deviceName: 'BuildBox',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;
  late FakeAgentTransport transport;
  late ControlPlaneClient client;
  late ProviderContainer container;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
    transport = FakeAgentTransport();
    client = ControlPlaneClient(transport: transport);
    container = ProviderContainer(
      overrides: [
        ...stores.overrides,
        controlPlaneClientForProvider(
          _machineUuid,
        ).overrideWith((ref) async => client),
      ],
    );
    await stores.cachedSessionsStore.put(_registrationId, [_session()]);
    await stores.cachedSessionsStore.flushNow();
  });

  tearDown(() async {
    container.dispose();
    await client.dispose();
    await stores.close();
  });

  test('a bridge yes prunes the row and flushes it', () async {
    transport.requestHandler = (method, params) => {'deleted': true};

    final outcome = await deleteRecentSession(container, _row());

    expect(outcome, RecentSessionDeleteOutcome.deleted);
    expect(stores.cachedSessionsStore.get(_registrationId), isEmpty);
  });

  // A lost answer says nothing about whether the removal happened, so the row
  // is reconciled by an idempotent re-read rather than pruned on a guess.
  test('a lost answer is accepted and reconciled by a re-peek', () async {
    var calls = 0;
    transport.requestHandler = (method, params) {
      calls++;
      if (method == 'sessions.delete') throw RpcException('E_TIMEOUT', 'gone');
      return {'sessions': const <Map<String, dynamic>>[]};
    };

    final outcome = await deleteRecentSession(container, _row());
    expect(outcome, RecentSessionDeleteOutcome.accepted);

    // The re-peek is detached; let it land.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await stores.cachedSessionsStore.flushNow();

    expect(calls, 2);
    expect(transport.requests.last.method, 'sessions.list');
    expect(
      stores.cachedSessionsStore.get(_registrationId),
      isEmpty,
      reason: 'pruned by the bridge no longer listing it, not by a guess',
    );
  });

  test('a re-peek that still lists the session leaves the row alone', () async {
    transport.requestHandler = (method, params) {
      if (method == 'sessions.delete') throw RpcException('E_TIMEOUT', 'gone');
      return {
        'sessions': [_session().toJson()],
      };
    };

    expect(
      await deleteRecentSession(container, _row()),
      RecentSessionDeleteOutcome.accepted,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(stores.cachedSessionsStore.get(_registrationId).map((s) => s.id), [
      _sessionId,
    ]);
  });

  // The request never left, which is a different answer entirely.
  test('a send failure stays a failure and re-peeks nothing', () async {
    var calls = 0;
    transport.requestHandler = (method, params) {
      calls++;
      throw RpcException('E_SEND_FAILED', 'no socket');
    };

    expect(
      await deleteRecentSession(container, _row()),
      RecentSessionDeleteOutcome.failed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
  });

  test('a bridge refusal is still re-typed for the confirm ladder', () async {
    transport.requestHandler = (method, params) =>
        throw RpcException('WORKTREE_DIRTY', 'dirty');

    await expectLater(
      () => deleteRecentSession(container, _row()),
      throwsA(
        isA<SessionOperationException>().having(
          (e) => e.errorCode,
          'errorCode',
          'WORKTREE_DIRTY',
        ),
      ),
    );
  });
}
