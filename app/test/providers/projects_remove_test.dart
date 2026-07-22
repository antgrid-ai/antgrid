import 'dart:io';

import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_ports.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:antgrid/storage/recent_ports_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

AbProject _project(String id) => AbProject(
  projectId: id,
  folder: '/tmp/$id',
  displayName: id,
  hostDeviceUuid: null,
  hostMachineName: 'host',
  lastOpenedAt: DateTime.utc(2026, 1, 1),
);

SessionEntry _session(String id) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 1,
  lastUsedAt: 2,
  archived: false,
  running: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ProjectStatusCache statusCache;

  setUp(() async {
    useInMemoryPrefs();
    tmp = await Directory.systemTemp.createTemp('antgrid-remove-test-');
    statusCache = ProjectStatusCache.testInstance(root: tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a transient handle on teardown; harmless for the test.
    }
  });

  test(
    'remove purges cached sessions, recent ports, and the status cache file',
    () async {
      final projectStore = await ProjectStore.open();
      await projectStore.upsert(_project('p1'));
      await projectStore.upsert(_project('p2'));

      final cachedSessions = await CachedSessionsStore.open();
      await cachedSessions.put('p1', [_session('a')]);
      await cachedSessions.put('p2', [_session('b')]);

      final recentPorts = await RecentPortsStore.open();
      await recentPorts.add('p1', 3000, 'http');
      await recentPorts.add('p2', 8080, 'http');

      final container = ProviderContainer(
        overrides: [
          projectStoreProvider.overrideWithValue(projectStore),
          cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
          recentPortsStoreProvider.overrideWithValue(recentPorts),
          projectStatusCacheProvider.overrideWithValue(statusCache),
          // Real registry whose onEvict WRITES a status file — this reproduces
          // the eviction-writes-status race the delete path must defeat.
          projectSessionRegistryProvider.overrideWith(
            () => ProjectSessionRegistryController(
              ProjectSessionRegistry(
                localCap: 10,
                relayCap: 30,
                onEvict: (id) async =>
                    statusCache.write(id, const ProjectStatus.empty()),
              ),
            ),
          ),
          // No live agent in the test — make warming the session fail fast so
          // `remove` doesn't block on the 10s stop-sessions timeout.
          projectSessionProvider('p1').overrideWith(
            (ref) => Future<ProjectSession>.error(StateError('no agent')),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(cachedSessions.close);
      addTearDown(recentPorts.close);

      // Mark p1 warm so the delete-path eviction actually fires onEvict (which
      // writes the status file we then expect to be purged).
      container
          .read(projectSessionRegistryProvider.notifier)
          .touch('p1', isLocal: true);

      await container.read(projectsProvider.notifier).remove('p1');

      // p1 fully purged...
      expect(container.read(projectsProvider).map((p) => p.projectId), ['p2']);
      expect(cachedSessions.get('p1'), isEmpty);
      expect(recentPorts.list('p1'), isEmpty);
      expect(await statusCache.read('p1'), isNull);

      // ...p2 untouched.
      expect(cachedSessions.get('p2').map((s) => s.id), ['b']);
      expect(recentPorts.list('p2').map((e) => e.port), [8080]);
    },
  );
}
