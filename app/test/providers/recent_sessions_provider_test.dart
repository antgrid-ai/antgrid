import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  test(
    'recentSessionsProvider aggregates cached sessions sorted by recency',
    () async {
      useInMemoryPrefs();

      final (projectStore, recentAgentsStore, cachedSessionsStore) = await (
        ProjectStore.open(),
        RecentAgentsStore.open(),
        CachedSessionsStore.open(),
      ).wait;
      addTearDown(recentAgentsStore.close);
      addTearDown(cachedSessionsStore.close);

      await cachedSessionsStore.put('projLocal', const [
        SessionEntry(
          id: 'l1',
          name: 'L1',
          createdAt: 0,
          lastUsedAt: 100,
          archived: false,
          running: false,
        ),
      ]);
      await cachedSessionsStore.put('uuidA.projRemote', const [
        SessionEntry(
          id: 'r1',
          name: 'R1',
          createdAt: 0,
          lastUsedAt: 200,
          archived: false,
          running: false,
        ),
      ]);
      await cachedSessionsStore.flushNow();

      final container = ProviderContainer(
        overrides: [
          projectStoreProvider.overrideWithValue(projectStore),
          recentAgentsStoreProvider.overrideWithValue(recentAgentsStore),
          cachedSessionsStoreProvider.overrideWithValue(cachedSessionsStore),
          // accountAgentsProvider is a FutureProvider hitting the network; short-
          // circuit with an empty inventory — the aggregation logic gracefully
          // falls back to bare uuid labels when no inventory is present.
          accountAgentsProvider.overrideWith((_) async => const []),
          // localDeviceUuidProvider reads the keychain + SharedPreferences; null
          // is fine here (no local projects in the test store).
          localDeviceUuidProvider.overrideWith((_) async => null),
        ],
      );
      addTearDown(container.dispose);

      final rows = container.read(recentSessionsProvider);
      expect(rows.map((r) => r.session.id), ['r1', 'l1']);
    },
  );

  test('overlays the focused project live sessions so a just-created session '
      'shows in Recent before the cache write-through lands', () async {
    useInMemoryPrefs();

    final (projectStore, recentAgentsStore, cachedSessionsStore) = await (
      ProjectStore.open(),
      RecentAgentsStore.open(),
      CachedSessionsStore.open(),
    ).wait;
    addTearDown(recentAgentsStore.close);
    addTearDown(cachedSessionsStore.close);

    // The cache for the focused remote project holds ONLY the old session —
    // the freshly-created one hasn't been written through yet (or was
    // clobbered by a stale control-plane peek).
    await cachedSessionsStore.put('uuidA.projRemote', const [
      SessionEntry(
        id: 'old',
        name: 'Old',
        createdAt: 0,
        lastUsedAt: 100,
        archived: false,
        running: false,
      ),
    ]);
    await cachedSessionsStore.flushNow();

    final container = ProviderContainer(
      overrides: [
        projectStoreProvider.overrideWithValue(projectStore),
        recentAgentsStoreProvider.overrideWithValue(recentAgentsStore),
        cachedSessionsStoreProvider.overrideWithValue(cachedSessionsStore),
        accountAgentsProvider.overrideWith((_) async => const []),
        localDeviceUuidProvider.overrideWith((_) async => null),
        // Live SessionsService state for the focused project carries the new
        // session (as the sidebar's sessionsForEntryProvider would render it).
        freshSessionsStateProvider.overrideWithValue(
          const SessionsState(
            projectId: 'uuidA.projRemote',
            sessions: [
              SessionEntry(
                id: 'old',
                name: 'Old',
                createdAt: 0,
                lastUsedAt: 100,
                archived: false,
                running: false,
              ),
              SessionEntry(
                id: 'new',
                name: 'New',
                createdAt: 0,
                lastUsedAt: 300,
                archived: false,
                running: true,
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final rows = container.read(recentSessionsProvider);
    // The live 'new' session appears (sorted first by recency) even though
    // the cache only had 'old'.
    expect(rows.map((r) => r.session.id), ['new', 'old']);
  });

  test('two consecutive writes to the SAME project both reach the drawer and '
      'Recent', () async {
    // The second write is the regression: cacheChangesProvider used to emit a
    // bare entryId, and a StreamProvider re-emitting an equal value notifies
    // nobody — so a session created (or deleted) in a project that had just
    // changed never reached the rows.
    useInMemoryPrefs();

    final (projectStore, recentAgentsStore, cachedSessionsStore) = await (
      ProjectStore.open(),
      RecentAgentsStore.open(),
      CachedSessionsStore.open(),
    ).wait;
    addTearDown(recentAgentsStore.close);
    addTearDown(cachedSessionsStore.close);

    final container = ProviderContainer(
      overrides: [
        projectStoreProvider.overrideWithValue(projectStore),
        recentAgentsStoreProvider.overrideWithValue(recentAgentsStore),
        cachedSessionsStoreProvider.overrideWithValue(cachedSessionsStore),
        accountAgentsProvider.overrideWith((_) async => const []),
        localDeviceUuidProvider.overrideWith((_) async => null),
      ],
    );
    addTearDown(container.dispose);

    // Settle the async metadata sources first so their resolution isn't
    // counted as one of the cache-driven pushes asserted below.
    await container.read(accountAgentsProvider.future);
    await container.read(localDeviceUuidProvider.future);

    // Read once so the family member registers its cache-change listener —
    // it's the drawer rendering the row that does this in production.
    expect(container.read(cachedSessionsProvider('projLocal')), isEmpty);
    // Keep Recent alive the way its tab does, and record every push: the
    // regression is a MISSING notification, which a plain read after the fact
    // would hide by recomputing.
    final recentPushes = <int>[];
    container.listen(
      recentSessionsProvider,
      (_, rows) => recentPushes.add(rows.length),
    );

    SessionEntry session(String id, int lastUsedAt) => SessionEntry(
      id: id,
      name: id,
      createdAt: 0,
      lastUsedAt: lastUsedAt,
      archived: false,
      running: false,
    );

    await cachedSessionsStore.put('projLocal', [session('a', 100)]);
    await pumpEventQueue();
    expect(
      container.read(cachedSessionsProvider('projLocal')).map((s) => s.id),
      ['a'],
    );

    await cachedSessionsStore.put('projLocal', [
      session('a', 100),
      session('b', 200),
    ]);
    await pumpEventQueue();
    expect(
      container.read(cachedSessionsProvider('projLocal')).map((s) => s.id),
      ['a', 'b'],
    );
    expect(container.read(recentSessionsProvider).map((r) => r.session.id), [
      'b',
      'a',
    ]);

    // A deletion is the same signal in reverse — it must not need an
    // unrelated project's write to land either.
    await cachedSessionsStore.put('projLocal', [session('a', 100)]);
    await pumpEventQueue();
    expect(container.read(recentSessionsProvider).map((r) => r.session.id), [
      'a',
    ]);

    // One push per write — never a repeat collapsed into silence.
    expect(recentPushes, [1, 2, 1]);
  });
}
