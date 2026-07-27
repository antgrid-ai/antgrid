import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'M';
const _projectId = 'p1';
const _compoundId = 'M.p1';

RecentAgent _recentAgent() {
  final now = DateTime(2026, 1, 1);
  return RecentAgent(
    agentDeviceId: '$_machineUuid.someproj',
    agentLabel: 'Remote Agent',
    agentEd25519Pubkey: '',
    relayUrl: 'wss://relay.example.test/ws',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

class _SeededRecentAgentsNotifier extends RecentAgentsNotifier {
  _SeededRecentAgentsNotifier(this._seed);
  final List<RecentAgent> _seed;
  @override
  List<RecentAgent> build() {
    super.build(); // wire the store-change subscription
    return _seed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'drawer peek fetches via control plane, caches, never starts a project',
    (tester) async {
      useInMemoryPrefs();
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final recent = _recentAgent();

      // Control-plane client backed by a fake transport that answers sessions.list.
      final cpTransport = FakeAgentTransport();
      cpTransport.requestHandler = (method, params) => {
        'sessions': [
          {
            'id': 's1',
            'name': 'Session 1',
            'createdAt': 1,
            'lastUsedAt': 2,
            'archived': false,
            'running': false,
          },
        ],
      };
      final cpClient = ControlPlaneClient(transport: cpTransport);
      addTearDown(cpClient.dispose);

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            recentAgentsProvider.overrideWith(
              () => _SeededRecentAgentsNotifier([recent]),
            ),
            controlPlaneClientForProvider(
              _machineUuid,
            ).overrideWith((ref) async => cpClient),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const SizedBox();
            },
          ),
        ),
      );

      // `drawerProjectSessionsProvider` is `autoDispose`; a bare `container.read`
      // opens and immediately closes its subscription, leaving zero listeners
      // while the fetch is still in flight. Riverpod 3 disposes an autoDispose
      // provider with zero listeners as soon as the scheduler gets a chance to
      // run — even mid-`build()` — so the in-flight future can throw
      // `UnmountedRefException` instead of resolving. Hold a real subscription
      // open for the fetch's duration, then close it.
      final sub = container.listen(
        drawerProjectSessionsProvider(_compoundId),
        (_, _) {},
      );
      addTearDown(sub.close);
      await container.read(drawerProjectSessionsProvider(_compoundId).future);

      // 1. Fetched over the control plane via sessions.list (NOT project:start).
      expect(cpTransport.requests.single.method, 'sessions.list');
      expect(cpTransport.requests.single.params, {
        'projectId': _projectId,
        'includeArchived': false,
      });
      expect(
        cpTransport.sent.any((m) => m['type'] == 'project:start'),
        isFalse,
      );

      // 2. Written through to the cache the drawer renders from (keyed by regId).
      await stores.cachedSessionsStore.flushNow();
      final cached = stores.cachedSessionsStore.get(_compoundId);
      expect(cached.map((s) => s.id), ['s1']);
    },
  );

  test(
    'drawer peek rejects a bare (dotless) id with StateError, not RangeError',
    () async {
      useInMemoryPrefs();
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // A bare machine id has no '.<projectId>' — the substring extraction would
      // throw RangeError; the guard must surface a clear StateError instead.
      await expectLater(
        container.read(drawerProjectSessionsProvider('bareid').future),
        throwsA(isA<StateError>()),
      );
    },
  );
}
