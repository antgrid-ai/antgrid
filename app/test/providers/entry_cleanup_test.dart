import 'dart:io';

import 'package:antgrid/config/storage_scope.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusCacheProvider;
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/entry_cleanup.dart';
import 'package:antgrid/providers/projects.dart' show projectStoreProvider;
import 'package:antgrid/providers/providers.dart'
    show preferencesServiceProvider, storageServiceProvider;
import 'package:antgrid/services/preferences_service.dart';
import 'package:antgrid/services/storage_service.dart';
import 'package:antgrid/storage/agent_catalog_store.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
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
    'purgeEntryState clears statusCache even when the cachedSessions '
    'clear throws (failure isolation)',
    () async {
      await cache.write('p1', const ProjectStatus.empty());

      final container = ProviderContainer(
        overrides: [
          // First store in the purge order blows up — the rest must still run.
          cachedSessionsStoreProvider.overrideWith(
            (ref) => throw StateError('cached sessions store unavailable'),
          ),
          projectStatusCacheProvider.overrideWithValue(cache),
        ],
      );
      addTearDown(container.dispose);
      final ref = container.read(_refProbe);

      // Must not throw despite the first clear failing.
      await purgeEntryState(ref, 'p1');

      expect(await cache.read('p1'), isNull);
    },
  );

  test(
    'purgeEntryState surfaces a swallowed store failure to onError (not silent)',
    () async {
      await cache.write('p1', const ProjectStatus.empty());

      final container = ProviderContainer(
        overrides: [
          cachedSessionsStoreProvider.overrideWith(
            (ref) => throw StateError('cached sessions store unavailable'),
          ),
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
      expect(await cache.read('p1'), isNull);
    },
  );

  group('purgeAccountCaches', () {
    late Map<String, String> secureBacking;
    late ProjectStore projectStore;

    setUp(() async {
      secureBacking = <String, String>{};
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        secureBacking,
      );
      // The purge asks which projects are LOCAL before it touches a store —
      // preferences for those survive sign-out (see clearAccountScoped).
      projectStore = await ProjectStore.open();
    });

    test('wipes every account-derived cache', () async {
      final cachedSessions = await CachedSessionsStore.open();
      addTearDown(cachedSessions.close);
      final catalog = AgentCatalogStore();
      final pairedStore = StorageService();
      final prefsService = PreferencesService();
      addTearDown(prefsService.dispose);

      const entryId = 'machine-1.proj-1';
      await cachedSessions.put(entryId, const [
        SessionEntry(
          id: 's1',
          name: 'refactor the biller',
          createdAt: 1,
          lastUsedAt: 2,
          archived: false,
          running: false,
        ),
      ]);
      cachedSessions.putLabel(entryId, 'Biller');
      cachedSessions.putStatus(entryId, 'attention');
      await cachedSessions.flushNow();
      await cache.write(entryId, const ProjectStatus.empty());
      await catalog.write(const {
        'claude': AgentDescriptor(
          tool: 'claude',
          label: 'Claude Code',
          chatCapable: true,
          judgeCapable: true,
          handlerTerminal: true,
          handlerChat: true,
        ),
      });
      // Written by hand: nothing produces this blob any more (QR pairing is
      // gone), but a pre-account-trust install still carries one and sign-out
      // has to evict it.
      secureBacking[scopedStorageKey('paired_agents')] = '[]';
      await prefsService.load(entryId);

      final container = ProviderContainer(
        overrides: [
          cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
          projectStatusCacheProvider.overrideWithValue(cache),
          agentCatalogStoreProvider.overrideWithValue(catalog),
          storageServiceProvider.overrideWithValue(pairedStore),
          preferencesServiceProvider.overrideWithValue(prefsService),
          projectStoreProvider.overrideWithValue(projectStore),
        ],
      );
      addTearDown(container.dispose);

      final failures = <String>[];
      await purgeAccountCaches(
        container.read(_refProbe),
        onError: (store, _) => failures.add(store),
      );

      expect(failures, isEmpty);
      expect(cachedSessions.get(entryId), isEmpty);
      expect(cachedSessions.has(entryId), isFalse);
      expect(cachedSessions.label(entryId), isNull);
      expect(cachedSessions.statusOf(entryId), isNull);
      expect(await cache.read(entryId), isNull);
      expect(await catalog.read(), isEmpty);
      expect(secureBacking, isNot(contains(scopedStorageKey('paired_agents'))));
      // The prefs file lives behind path_provider, which isn't mocked here —
      // the in-memory reset is what stops the stale entry being served.
      expect(prefsService.projectId, isNull);

      // Reopening from disk is the real assertion: a store that only cleared
      // its in-memory copy would still hand the next sign-in the old rows.
      final reopenedSessions = await CachedSessionsStore.open();
      addTearDown(reopenedSessions.close);
      expect(reopenedSessions.entries(), isEmpty);
      expect(reopenedSessions.labels(), isEmpty);
      expect(reopenedSessions.allStatuses(), isEmpty);
    });

    test('a failing store is reported and does not strand the rest', () async {
      await cache.write('p1', const ProjectStatus.empty());
      final pairedStore = StorageService();
      secureBacking[scopedStorageKey('paired_agents')] = '[]';

      final container = ProviderContainer(
        overrides: [
          // First store in the purge order blows up.
          cachedSessionsStoreProvider.overrideWith(
            (ref) => throw StateError('cached sessions store unavailable'),
          ),
          projectStatusCacheProvider.overrideWithValue(cache),
          agentCatalogStoreProvider.overrideWithValue(AgentCatalogStore()),
          storageServiceProvider.overrideWithValue(pairedStore),
          preferencesServiceProvider.overrideWithValue(PreferencesService()),
          projectStoreProvider.overrideWithValue(projectStore),
        ],
      );
      addTearDown(container.dispose);

      final failures = <String>[];
      await purgeAccountCaches(
        container.read(_refProbe),
        onError: (store, _) => failures.add(store),
      );

      expect(failures, ['cachedSessions']);
      expect(await cache.read('p1'), isNull);
      expect(secureBacking, isNot(contains(scopedStorageKey('paired_agents'))));
    });
  });
}
