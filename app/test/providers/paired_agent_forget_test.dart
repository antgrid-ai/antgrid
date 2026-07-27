import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/models/qr_payload.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/recent_ports.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusCacheProvider;
import 'package:antgrid/services/storage_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/storage/recent_ports_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

class _MemoryStorageService extends StorageService {
  _MemoryStorageService(this.agents);

  List<PairedAgent> agents;

  @override
  Future<List<PairedAgent>> loadPairedAgents() async => List.of(agents);

  @override
  Future<void> savePairedAgents(List<PairedAgent> agents) async {
    this.agents = List.of(agents);
  }
}

/// Fails the FIRST persist, then succeeds — models a QR import that dies
/// half-way so the retry path can be exercised.
class _FailOnceStorageService extends StorageService {
  List<PairedAgent> agents = <PairedAgent>[];
  var saves = 0;

  @override
  Future<List<PairedAgent>> loadPairedAgents() async => List.of(agents);

  @override
  Future<void> savePairedAgents(List<PairedAgent> next) async {
    saves++;
    if (saves == 1) throw PairException('first import attempt failed');
    agents = List.of(next);
  }
}

PairedAgent _paired(String id) =>
    PairedAgent(relayUrl: 'ws://relay.test', agentDeviceId: id, agentName: id);

RecentAgent _recent(String id) {
  final now = DateTime.utc(2026, 1, 1);
  return RecentAgent(
    agentDeviceId: id,
    agentLabel: id,
    agentEd25519Pubkey: 'agent-pubkey',
    relayUrl: 'ws://relay.test',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({
      ProviderContainer container,
      RecentAgentsStore recentStore,
      _MemoryStorageService storage,
    })
  >
  buildContainer({
    required List<PairedAgent> paired,
    required List<RecentAgent> recent,
  }) async {
    useInMemoryPrefs();
    final recentStore = await RecentAgentsStore.open();
    for (final agent in recent) {
      await recentStore.upsert(agent);
    }
    final storage = _MemoryStorageService(paired);
    // forgetMachine purges each forgotten agent's per-entry footprint, so the
    // container must provide the stores purgeEntryState reads.
    final cachedSessions = await CachedSessionsStore.open();
    final recentPorts = await RecentPortsStore.open();
    final statusTmp = await Directory.systemTemp.createTemp(
      'antgrid-forget-buildc-',
    );
    final statusCache = ProjectStatusCache.testInstance(root: statusTmp.path);
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        recentAgentsStoreProvider.overrideWithValue(recentStore),
        cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
        recentPortsStoreProvider.overrideWithValue(recentPorts),
        projectStatusCacheProvider.overrideWithValue(statusCache),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(recentStore.close);
    addTearDown(cachedSessions.close);
    addTearDown(recentPorts.close);
    addTearDown(() async {
      try {
        await statusTmp.delete(recursive: true);
      } on FileSystemException {
        // Windows teardown handle race — harmless.
      }
    });
    return (container: container, recentStore: recentStore, storage: storage);
  }

  test(
    'forgetMachine removes inactive remote from paired and recent stores',
    () async {
      final h = await buildContainer(
        paired: [_paired('M.project'), _paired('N.project')],
        recent: [_recent('M.project'), _recent('N.project')],
      );
      await h.container.read(pairedAgentProvider.future);

      await h.container.read(pairedAgentProvider.notifier).forgetMachine('M');
      await Future<void>.delayed(Duration.zero);

      expect(h.storage.agents.map((a) => a.agentDeviceId), ['N.project']);
      expect(h.recentStore.list().map((a) => a.agentDeviceId), ['N.project']);
      expect(
        h.container
            .read(pairedAgentProvider)
            .value
            ?.map((a) => a.agentDeviceId),
        ['N.project'],
      );
    },
  );

  test(
    'forgetMachine preserves nonmatching paired agents before provider load',
    () async {
      final h = await buildContainer(
        paired: [_paired('M.project'), _paired('N.project')],
        recent: [_recent('M.project'), _recent('N.project')],
      );

      await h.container.read(pairedAgentProvider.notifier).forgetMachine('M');
      await Future<void>.delayed(Duration.zero);

      expect(h.storage.agents.map((a) => a.agentDeviceId), ['N.project']);
      expect(h.recentStore.list().map((a) => a.agentDeviceId), ['N.project']);
    },
  );

  test(
    'forgetMachine clears active target for the forgotten machine',
    () async {
      final h = await buildContainer(
        paired: [_paired('M.project'), _paired('N.project')],
        recent: [_recent('M.project'), _recent('N.project')],
      );
      h.container
          .read(selectedTargetProvider.notifier)
          .set(const RemoteTarget.legacy('M.project'));
      await h.container.read(pairedAgentProvider.future);

      await h.container
          .read(pairedAgentProvider.notifier)
          .forgetMachine('M.project');

      expect(h.container.read(selectedTargetProvider), isNull);
    },
  );

  test(
    'forgetMachine removes all compound ids for the same bare machine',
    () async {
      final h = await buildContainer(
        paired: [
          _paired('M.projectA'),
          _paired('M.projectB'),
          _paired('N.project'),
        ],
        recent: [
          _recent('M.projectA'),
          _recent('M.projectB'),
          _recent('N.project'),
        ],
      );
      final mgr = h.container.read(relayConnectionManagerProvider);
      mgr.connectionFor('M.projectA');
      mgr.connectionFor('M.projectB');
      mgr.connectionFor('N.project');
      await h.container.read(pairedAgentProvider.future);

      await h.container.read(pairedAgentProvider.notifier).forgetMachine('M');

      expect(h.storage.agents.map((a) => a.agentDeviceId), ['N.project']);
      expect(h.recentStore.list().map((a) => a.agentDeviceId), ['N.project']);
      expect(mgr.peek('M.projectA'), isNull);
      expect(mgr.peek('M.projectB'), isNull);
      expect(mgr.peek('N.project'), isNotNull);
    },
  );

  test(
    'forgetMachine purges cached sessions + status cache for its agents',
    () async {
      useInMemoryPrefs();
      final tmp = await Directory.systemTemp.createTemp('antgrid-forget-test-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } on FileSystemException {
          // Windows teardown handle race — harmless for the assertion.
        }
      });
      final statusCache = ProjectStatusCache.testInstance(root: tmp.path);

      final recentStore = await RecentAgentsStore.open();
      await recentStore.upsert(_recent('M.project'));
      await recentStore.upsert(_recent('N.project'));
      addTearDown(recentStore.close);

      final cachedSessions = await CachedSessionsStore.open();
      addTearDown(cachedSessions.close);
      final recentPorts = await RecentPortsStore.open();
      addTearDown(recentPorts.close);
      await cachedSessions.put('M.project', [
        SessionEntry(
          id: 's1',
          name: 's1',
          createdAt: 1,
          lastUsedAt: 2,
          archived: false,
          running: false,
        ),
      ]);
      await cachedSessions.put('N.project', [
        SessionEntry(
          id: 's2',
          name: 's2',
          createdAt: 1,
          lastUsedAt: 2,
          archived: false,
          running: false,
        ),
      ]);
      await statusCache.write('M.project', const ProjectStatus.empty());

      final storage = _MemoryStorageService([
        _paired('M.project'),
        _paired('N.project'),
      ]);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          recentAgentsStoreProvider.overrideWithValue(recentStore),
          cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
          recentPortsStoreProvider.overrideWithValue(recentPorts),
          projectStatusCacheProvider.overrideWithValue(statusCache),
        ],
      );
      addTearDown(container.dispose);
      await container.read(pairedAgentProvider.future);

      await container.read(pairedAgentProvider.notifier).forgetMachine('M');
      await Future<void>.delayed(Duration.zero);

      expect(cachedSessions.get('M.project'), isEmpty);
      expect(await statusCache.read('M.project'), isNull);
      // The other machine's cached sessions survive.
      expect(cachedSessions.get('N.project').map((s) => s.id), ['s2']);
    },
  );

  test('a QR import can retry after a failed attempt', () async {
    useInMemoryPrefs();
    final recentStore = await RecentAgentsStore.open();
    final storage = _FailOnceStorageService();
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        recentAgentsStoreProvider.overrideWithValue(recentStore),
        currentUserProvider.overrideWith(
          (_) async => CurrentUser(
            userId: 'user-1',
            email: 'user@example.test',
            tier: 'pro',
          ),
        ),
        connectionDeviceRecordProvider.overrideWith(
          (_) async => DeviceRecord(
            userId: 'user-1',
            deviceUuid: 'controller-uuid',
            clientId: 'cid',
            clientSecret: 'csec',
            ed25519Pub: base64Encode(List<int>.filled(32, 1)),
            ed25519Priv: base64Encode(List<int>.filled(32, 2)),
            x25519Pub: base64Encode(List<int>.filled(32, 3)),
            x25519Priv: base64Encode(List<int>.filled(32, 4)),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(recentStore.close);

    final qr = QrPayload(
      relayUrl: 'ws://relay.test',
      agentDeviceId: 'M.project',
      agentEd25519PublicKey: Uint8List(32),
      agentName: 'Machine M',
    );

    await expectLater(
      container.read(pairedAgentProvider.notifier).importCoordinates(qr),
      throwsA(isA<PairException>()),
    );

    await container.read(pairedAgentProvider.notifier).importCoordinates(qr);

    expect(
      storage.saves,
      2,
      reason: 'the AsyncError must not wedge the import',
    );
    expect(storage.agents.map((a) => a.agentDeviceId), ['M.project']);
    // The QR is now a pure coordinate import: it persists a dialable
    // RecentAgent row and nothing else.
    expect(recentStore.list().map((r) => r.agentDeviceId), ['M.project']);
    expect(recentStore.list().single.relayUrl, 'ws://relay.test');
  });
}
