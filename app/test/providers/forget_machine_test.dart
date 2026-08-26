import 'dart:io';

import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/recent_ports.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusCacheProvider;
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/storage/recent_ports_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

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

  Future<({ProviderContainer container, RecentAgentsStore recentStore})>
  buildContainer({required List<RecentAgent> recent}) async {
    useInMemoryPrefs();
    final recentStore = await RecentAgentsStore.open();
    for (final agent in recent) {
      await recentStore.upsert(agent);
    }
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
    return (container: container, recentStore: recentStore);
  }

  test('forgetMachine drops the machine from the reconnect list', () async {
    final h = await buildContainer(
      recent: [_recent('M.project'), _recent('N.project')],
    );

    await h.container
        .read(machineConnectionProvider.notifier)
        .forgetMachine('M');
    await Future<void>.delayed(Duration.zero);

    expect(h.recentStore.list().map((a) => a.agentDeviceId), ['N.project']);
  });

  test(
    'forgetMachine clears active target for the forgotten machine',
    () async {
      final h = await buildContainer(
        recent: [_recent('M.project'), _recent('N.project')],
      );
      h.container
          .read(selectedTargetProvider.notifier)
          .set(const RemoteTarget.legacy('M.project'));

      await h.container
          .read(machineConnectionProvider.notifier)
          .forgetMachine('M.project');

      expect(h.container.read(selectedTargetProvider), isNull);
    },
  );

  test(
    'forgetMachine removes all compound ids for the same bare machine',
    () async {
      final h = await buildContainer(
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

      await h.container
          .read(machineConnectionProvider.notifier)
          .forgetMachine('M');

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

      final container = ProviderContainer(
        overrides: [
          recentAgentsStoreProvider.overrideWithValue(recentStore),
          cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
          recentPortsStoreProvider.overrideWithValue(recentPorts),
          projectStatusCacheProvider.overrideWithValue(statusCache),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(machineConnectionProvider.notifier)
          .forgetMachine('M');
      await Future<void>.delayed(Duration.zero);

      expect(cachedSessions.get('M.project'), isEmpty);
      expect(await statusCache.read('M.project'), isNull);
      // The other machine's cached sessions survive.
      expect(cachedSessions.get('N.project').map((s) => s.id), ['s2']);
    },
  );
}
