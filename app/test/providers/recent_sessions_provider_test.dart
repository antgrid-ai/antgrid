import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  test('recentSessionsProvider aggregates cached sessions sorted by recency',
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

    final container = ProviderContainer(overrides: [
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
    ]);
    addTearDown(container.dispose);

    final rows = container.read(recentSessionsProvider);
    expect(rows.map((r) => r.session.id), ['r1', 'l1']);
  });
}
