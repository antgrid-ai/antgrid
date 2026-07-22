import 'dart:io';

import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ProjectStatusCache cache;

  setUp(() async {
    useInMemoryPrefs();
    tmp = await Directory.systemTemp.createTemp('antgrid-evict-test-');
    cache = ProjectStatusCache.testInstance(root: tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows teardown handle race — harmless for the assertion.
    }
  });

  Future<ProjectSession> fakeSession(String id) async {
    final t = FakeAgentTransport();
    final store = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: id,
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: store,
      onClose: () async => t.dispose(),
    );
  }

  ProviderContainer buildContainer({
    required List<DrawerEntry> entries,
    required ProjectSession session,
  }) {
    return ProviderContainer(
      overrides: [
        projectStatusCacheProvider.overrideWithValue(cache),
        drawerEntriesProvider.overrideWithValue(entries),
        projectSessionProvider('p1').overrideWith((ref) async => session),
        projectSessionRegistryProvider.overrideWith(
          () => AppProjectSessionRegistryController(localCap: 10, relayCap: 30),
        ),
      ],
    );
  }

  test('evicting a still-listed project snapshots its status', () async {
    final session = await fakeSession('p1');
    final container = buildContainer(
      entries: [LocalProjectEntry(_project('p1'))],
      session: session,
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider('p1').future);
    final reg = container.read(projectSessionRegistryProvider.notifier);
    reg.touch('p1', isLocal: true);

    await reg.forceEvictAndSettle('p1');

    expect(await cache.read('p1'), isNotNull);
  });

  test(
    'evicting an id no longer in the drawer does NOT snapshot status (no resurrection)',
    () async {
      final session = await fakeSession('p1');
      // p1 has been deleted: it is no longer a live drawer entry. A late
      // warm-up that resolves after the delete purged the status file must NOT
      // re-create it.
      final container = buildContainer(entries: const [], session: session);
      addTearDown(container.dispose);
      await container.read(projectSessionProvider('p1').future);
      final reg = container.read(projectSessionRegistryProvider.notifier);
      reg.touch('p1', isLocal: true);

      await reg.forceEvictAndSettle('p1');

      expect(await cache.read('p1'), isNull);
    },
  );
}
