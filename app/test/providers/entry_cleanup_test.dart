import 'dart:io';

import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusCacheProvider;
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/entry_cleanup.dart';
import 'package:antgrid/providers/recent_ports.dart';
import 'package:antgrid/storage/recent_ports_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// Exposes the container's [Ref] so a plain `test()` can call the
/// `Ref`-typed [purgeEntryState] without a widget.
final _refProbe = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ProjectStatusCache cache;

  setUp(() async {
    useInMemoryPrefs();
    tmp = await Directory.systemTemp.createTemp('antgrid-purge-test-');
    cache = ProjectStatusCache.testInstance(root: tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows teardown handle race — harmless for the assertion.
    }
  });

  test(
    'purgeEntryState clears recentPorts + statusCache even when the cachedSessions '
    'clear throws (failure isolation)',
    () async {
      final recentPorts = await RecentPortsStore.open();
      addTearDown(recentPorts.close);
      await recentPorts.add('p1', 3000, 'http');
      await cache.write('p1', const ProjectStatus.empty());

      final container = ProviderContainer(
        overrides: [
          // First store in the purge order blows up — the rest must still run.
          cachedSessionsStoreProvider.overrideWith(
            (ref) => throw StateError('cached sessions store unavailable'),
          ),
          recentPortsStoreProvider.overrideWithValue(recentPorts),
          projectStatusCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(container.dispose);
      final ref = container.read(_refProbe);

      // Must not throw despite the first clear failing.
      await purgeEntryState(ref, 'p1');

      expect(recentPorts.list('p1'), isEmpty);
      expect(await cache.read('p1'), isNull);
    },
  );

  test(
    'purgeEntryState surfaces a swallowed store failure to onError (not silent)',
    () async {
      final recentPorts = await RecentPortsStore.open();
      addTearDown(recentPorts.close);
      await recentPorts.add('p1', 3000, 'http');
      await cache.write('p1', const ProjectStatus.empty());

      final container = ProviderContainer(
        overrides: [
          cachedSessionsStoreProvider.overrideWith(
            (ref) => throw StateError('cached sessions store unavailable'),
          ),
          recentPortsStoreProvider.overrideWithValue(recentPorts),
          projectStatusCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(container.dispose);
      final ref = container.read(_refProbe);

      final failures = <String>[];
      await purgeEntryState(
        ref,
        'p1',
        onError: (store, _) => failures.add(store),
      );

      // The swallowed failure is reported with its store label...
      expect(failures, ['cachedSessions']);
      // ...and the other stores still cleared (isolation preserved).
      expect(recentPorts.list('p1'), isEmpty);
      expect(await cache.read('p1'), isNull);
    },
  );
}
