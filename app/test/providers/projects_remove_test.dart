import 'dart:io';
import 'dart:async';

import 'package:antgrid/launcher/host_control_client.dart';

import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/pending_forgets_store.dart';
import 'package:antgrid/storage/project_store.dart';
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
    'backfill cannot restore a project during cleanup or from an older poll',
    () async {
      final projectStore = await ProjectStore.open();
      await projectStore.upsert(_project('p1'));
      final pending = await PendingForgetsStore.open();
      final cached = await CachedSessionsStore.open();
      addTearDown(cached.close);
      final blockedCache = _BlockingStatusCache(statusCache);
      final container = ProviderContainer(
        overrides: [
          projectStoreProvider.overrideWithValue(projectStore),
          pendingForgetsStoreProvider.overrideWithValue(pending),
          cachedSessionsStoreProvider.overrideWithValue(cached),
          projectStatusCacheProvider.overrideWithValue(blockedCache),
          projectSessionRegistryProvider.overrideWith(
            () => ProjectSessionRegistryController(
              ProjectSessionRegistry(
                localCap: 10,
                relayCap: 30,
                onEvict: (_) async {},
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final projects = container.read(projectsProvider.notifier);
      final beforeDelete = projects.hostCatalogGeneration;
      final removal = projects.remove('p1');
      await blockedCache.started.future;
      final duringDelete = projects.hostCatalogGeneration;
      const known = [
        KnownProject(projectId: 'p1', path: '/tmp/p1', running: false),
      ];
      expect(pending.read(), contains('p1'));
      await projects.backfillFromHost(known, hostUuid: 'host');
      expect(projectStore.list(), isEmpty);
      // An empty catalog must not retire a guard while cleanup still owns it.
      await projects.backfillFromHost(const [], hostUuid: 'host');
      expect(pending.read(), contains('p1'));
      blockedCache.release.complete();
      await removal;
      await projects.backfillFromHost(const [], hostUuid: 'host');
      expect(pending.read(), isEmpty);
      for (final generation in [beforeDelete, duringDelete]) {
        await projects.backfillFromHost(
          known,
          hostUuid: 'host',
          generation: generation,
        );
        expect(projectStore.list(), isEmpty);
      }
    },
  );

  test(
    'remove purges cached sessions and the status cache file',
    () async {
      final projectStore = await ProjectStore.open();
      await projectStore.upsert(_project('p1'));
      await projectStore.upsert(_project('p2'));

      final cachedSessions = await CachedSessionsStore.open();
      await cachedSessions.put('p1', [_session('a')]);
      await cachedSessions.put('p2', [_session('b')]);

      final pendingForgets = await PendingForgetsStore.open();

      final container = ProviderContainer(
        overrides: [
          projectStoreProvider.overrideWithValue(projectStore),
          pendingForgetsStoreProvider.overrideWithValue(pendingForgets),
          cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
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

      // Mark p1 warm so the delete-path eviction actually fires onEvict (which
      // writes the status file we then expect to be purged).
      container
          .read(projectSessionRegistryProvider.notifier)
          .touch('p1', isLocal: true);

      await container.read(projectsProvider.notifier).remove('p1');

      // p1 fully purged...
      expect(container.read(projectsProvider).map((p) => p.projectId), ['p2']);
      expect(cachedSessions.get('p1'), isEmpty);
      expect(await statusCache.read('p1'), isNull);

      // ...p2 untouched.
      expect(cachedSessions.get('p2').map((s) => s.id), ['b']);
    },
  );
}

class _BlockingStatusCache implements ProjectStatusCache {
  _BlockingStatusCache(this.delegate);
  final ProjectStatusCache delegate;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> clear(String id) async {
    started.complete();
    await release.future;
    await delegate.clear(id);
  }

  @override
  Future<void> clearAll() => delegate.clearAll();

  @override
  Future<ProjectStatus?> read(String id) => delegate.read(id);

  @override
  Future<void> write(String id, ProjectStatus status) =>
      delegate.write(id, status);
}
