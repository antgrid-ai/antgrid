// Regression tests for ProjectsNotifier.reconcileWithHost (D-A3): folding an
// app-minted duplicate row onto the primary project a host resolver now
// names for the same repository, and the backfillFromHost guard that keeps
// a folded alias id from resurrecting via the host's seen-catalog.
import 'dart:io';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/pending_forgets_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// pathBasename splits on Platform.pathSeparator, so a hardcoded '/repo'
/// resolves to the whole string (not 'repo') on Windows — build every path
/// whose basename a test asserts on through this.
final String _sep = Platform.pathSeparator;
final String _repoPath = '${_sep}repo';

AbProject _project(
  String id, {
  String? folder,
  String? hostDeviceUuid,
  String? displayName,
}) => AbProject(
  projectId: id,
  folder: folder ?? '/tmp/$id',
  displayName: displayName ?? id,
  hostDeviceUuid: hostDeviceUuid,
  hostMachineName: 'host',
  lastOpenedAt: DateTime.utc(2026, 1, 1),
);

SessionEntry _session(String id, {String checkoutId = 'main'}) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 1,
  lastUsedAt: 2,
  archived: false,
  running: false,
  checkoutId: checkoutId,
);

ResolvedLocalProject _resolved(
  String projectId, {
  String? repoPath,
  String? kind,
}) => ResolvedLocalProject(
  projectId: projectId,
  repoPath: repoPath ?? '/repo',
  selectedPath: repoPath ?? '/repo',
  label: 'repo',
  isGitRepository: true,
  kind: kind ?? 'plain',
);

class _Harness {
  _Harness({
    required this.container,
    required this.projectStore,
    required this.cachedSessions,
    required this.statusCache,
  });

  final ProviderContainer container;
  final ProjectStore projectStore;
  final CachedSessionsStore cachedSessions;
  final ProjectStatusCache statusCache;

  ProjectsNotifier get notifier => container.read(projectsProvider.notifier);
  List<String> get ids =>
      container.read(projectsProvider).map((p) => p.projectId).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    useInMemoryPrefs();
    tmp = await Directory.systemTemp.createTemp('antgrid-reconcile-test-');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a transient handle on teardown; harmless.
    }
  });

  Future<_Harness> buildHarness(
    List<AbProject> initial, {
    Future<void> Function(String id)? onEvictExtra,
  }) async {
    final projectStore = await ProjectStore.open();
    for (final p in initial) {
      await projectStore.upsert(p);
    }
    final pendingForgets = await PendingForgetsStore.open();
    final cachedSessions = await CachedSessionsStore.open();
    final statusCache = ProjectStatusCache.testInstance(root: tmp.path);
    final container = ProviderContainer(
      overrides: [
        projectStoreProvider.overrideWithValue(projectStore),
        pendingForgetsStoreProvider.overrideWithValue(pendingForgets),
        cachedSessionsStoreProvider.overrideWithValue(cachedSessions),
        projectStatusCacheProvider.overrideWithValue(statusCache),
        projectSessionRegistryProvider.overrideWith(
          () => ProjectSessionRegistryController(
            ProjectSessionRegistry(
              localCap: 10,
              relayCap: 30,
              onEvict: (id) async {
                if (onEvictExtra != null) await onEvictExtra(id);
                await statusCache.write(id, const ProjectStatus.empty());
              },
            ),
          ),
        ),
      ],
    );
    return _Harness(
      container: container,
      projectStore: projectStore,
      cachedSessions: cachedSessions,
      statusCache: statusCache,
    );
  }

  test(
    'a duplicate row folds onto its survivor and the alias caches are purged',
    () async {
      final h = await buildHarness([
        _project('primary', folder: '/repo'),
        _project('alias-id', folder: '/repo/wt/checkout'),
      ]);
      addTearDown(h.container.dispose);
      addTearDown(h.cachedSessions.close);
      await h.cachedSessions.put('alias-id', [_session('s1')]);

      // Mark the alias warm so eviction actually fires onEvict (which writes
      // the status file we then expect purgeEntryState to clear).
      h.container
          .read(projectSessionRegistryProvider.notifier)
          .touch('alias-id', isLocal: true);

      Future<ResolvedLocalProject> resolve(String folder) async {
        return _resolved('primary', repoPath: '/repo');
      }

      await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');

      expect(h.ids, ['primary']);
      expect(h.cachedSessions.get('alias-id'), isEmpty);
      expect(await h.statusCache.read('alias-id'), isNull);
    },
  );

  test('a row with no survivor is rekeyed under the resolved id', () async {
    final h = await buildHarness([
      _project(
        'old-id',
        folder: '$_repoPath${_sep}wt${_sep}checkout',
        displayName: 'checkout',
        // Non-null so the JSON round-trip through the store takes the
        // current schema, not the legacy (pre-v2, hostMachineName-dropping)
        // migration path — see AbProject.fromJson.
        hostDeviceUuid: 'host-1',
      ),
    ]);
    addTearDown(h.container.dispose);
    addTearDown(h.cachedSessions.close);

    Future<ResolvedLocalProject> resolve(String folder) async {
      return _resolved('new-id', repoPath: _repoPath);
    }

    await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');

    expect(h.ids, ['new-id']);
    final rekeyed = h.container
        .read(projectsProvider)
        .single;
    expect(rekeyed.folder, _repoPath);
    expect(rekeyed.displayName, 'repo');
    expect(rekeyed.hostMachineName, 'host');
  });

  test(
    'a concurrent generation bump mid-fold does not lose the rekeyed row',
    () async {
      late _Harness h;
      Future<void>? concurrentRemove;
      h = await buildHarness(
        [
          _project(
            'old-id',
            folder: '$_repoPath${_sep}wt${_sep}checkout',
            hostDeviceUuid: 'host-1',
          ),
          _project('other', folder: '/other', hostDeviceUuid: 'host-1'),
        ],
        onEvictExtra: (id) async {
          if (id != 'old-id') return;
          // Simulates a user-initiated delete of an unrelated project landing
          // between forceEvictAndSettle and upsert — remove() bumps the
          // generation synchronously before its first await. The fold must
          // still finish: bailing here would leave the store with 'old-id'
          // removed and 'new-id' never written.
          concurrentRemove = h.notifier.remove('other');
        },
      );
      addTearDown(h.container.dispose);
      addTearDown(h.cachedSessions.close);

      h.container
          .read(projectSessionRegistryProvider.notifier)
          .touch('old-id', isLocal: true);

      Future<ResolvedLocalProject> resolve(String folder) async =>
          _resolved('new-id', repoPath: _repoPath);

      await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');
      await concurrentRemove;

      expect(h.ids, contains('new-id'));
      expect(h.ids, isNot(contains('old-id')));
    },
  );

  test('a row hosted on another machine is never touched', () async {
    final h = await buildHarness([
      _project('remote-p', folder: '/remote', hostDeviceUuid: 'other-host'),
    ]);
    addTearDown(h.container.dispose);
    addTearDown(h.cachedSessions.close);

    var calls = 0;
    Future<ResolvedLocalProject> resolve(String folder) async {
      calls++;
      return _resolved('should-not-happen');
    }

    await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');

    expect(h.ids, ['remote-p']);
    expect(calls, 0);
  });

  test(
    'a resolve failure is skipped without aborting the rest of the sweep',
    () async {
      final h = await buildHarness([
        _project('a', folder: '/a'),
        _project('b', folder: '/b'),
      ]);
      addTearDown(h.container.dispose);
      addTearDown(h.cachedSessions.close);

      Future<ResolvedLocalProject> resolve(String folder) async {
        if (folder == '/a') throw StateError('unreachable host');
        return _resolved('b-resolved', repoPath: '/b-repo');
      }

      await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');

      expect(h.ids, containsAll(['a', 'b-resolved']));
      expect(h.ids, isNot(contains('b')));
    },
  );

  test('a second run is a no-op', () async {
    final h = await buildHarness([
      _project('old-id', folder: '/repo/wt/checkout'),
    ]);
    addTearDown(h.container.dispose);
    addTearDown(h.cachedSessions.close);

    Future<ResolvedLocalProject> resolve(String folder) async {
      // Idempotent by folder: the rekeyed row's folder becomes '/repo', which
      // must itself resolve to 'new-id' — otherwise the second sweep would
      // see it as yet another alias.
      return _resolved('new-id', repoPath: '/repo');
    }

    await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');
    final afterFirst = h.ids;
    await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');

    expect(h.ids, afterFirst);
    expect(h.ids, ['new-id']);
  });

  test(
    'reports whether the sweep completed, so a caller can gate '
    'once-per-host bookkeeping on it',
    () async {
      final h = await buildHarness([_project('primary', folder: '/repo')]);
      addTearDown(h.container.dispose);
      addTearDown(h.cachedSessions.close);

      Future<ResolvedLocalProject> resolve(String folder) async =>
          _resolved('primary', repoPath: '/repo');

      final stale = await h.notifier.reconcileWithHost(
        resolve: resolve,
        hostUuid: 'host-1',
        generation: h.notifier.hostCatalogGeneration + 1,
      );
      expect(stale, isFalse);

      final completed = await h.notifier.reconcileWithHost(
        resolve: resolve,
        hostUuid: 'host-1',
      );
      expect(completed, isTrue);
    },
  );

  test(
    'a selected alias moves selection to the survivor',
    () async {
      final h = await buildHarness([
        _project('primary', folder: '/repo'),
        _project('alias-id', folder: '/repo/wt/checkout'),
      ]);
      addTearDown(h.container.dispose);
      addTearDown(h.cachedSessions.close);

      h.container
          .read(selectedTargetProvider.notifier)
          .set(const LocalProject('alias-id'));

      Future<ResolvedLocalProject> resolve(String folder) async {
        return _resolved('primary', repoPath: '/repo');
      }

      await h.notifier.reconcileWithHost(resolve: resolve, hostUuid: 'host-1');

      expect(h.container.read(selectedRegistrationIdProvider), 'primary');
    },
  );

  test(
    'backfillFromHost skips a folded alias id and only resolves it once',
    () async {
      final h = await buildHarness(const []);
      addTearDown(h.container.dispose);
      addTearDown(h.cachedSessions.close);

      var calls = 0;
      Future<ResolvedLocalProject> resolve(String folder) async {
        calls++;
        return _resolved('primary', repoPath: '/repo');
      }

      const known = [
        KnownProject(
          projectId: 'alias-id',
          path: '/repo/wt/checkout',
          running: false,
        ),
      ];

      await h.notifier.backfillFromHost(
        known,
        hostUuid: 'host-1',
        resolve: resolve,
      );
      expect(h.ids, isEmpty);
      expect(calls, 1);

      await h.notifier.backfillFromHost(
        known,
        hostUuid: 'host-1',
        resolve: resolve,
      );
      expect(h.ids, isEmpty);
      expect(calls, 1, reason: 'a folded alias must cost only ONE resolve');
    },
  );
}
