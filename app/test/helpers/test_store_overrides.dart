// Test helper that materializes the four persistent-store providers main()
// expects to be overridden. Tests that mount widgets reading from
// `recentAgentsProvider`, `projectsProvider`, etc. can call
// [buildTestStoreOverrides] inside their test setup to satisfy those
// throw-by-default providers.
//
// Caller is responsible for calling useInMemoryPrefs() (test/helpers/prefs_test_mock.dart) before invocation (the stores read prefs eagerly on open).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/misc.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/collapsed_drawer.dart';
import 'package:antgrid/providers/drawer_order.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/recent_ports.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusCacheProvider;
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/drawer_collapsed_store.dart';
import 'package:antgrid/storage/drawer_order_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/storage/recent_ports_store.dart';

class TestStoreOverrides {
  final List<Override> overrides;
  final ProjectStore projectStore;
  final RecentAgentsStore recentAgentsStore;
  final DrawerOrderStore drawerOrderStore;
  final CachedSessionsStore cachedSessionsStore;
  final RecentPortsStore recentPortsStore;

  TestStoreOverrides._({
    required this.overrides,
    required this.projectStore,
    required this.recentAgentsStore,
    required this.drawerOrderStore,
    required this.cachedSessionsStore,
    required this.recentPortsStore,
  });

  Future<void> close() async {
    await recentAgentsStore.close();
    await cachedSessionsStore.close();
    await recentPortsStore.close();
    // ProjectStore and DrawerOrderStore have no close(); the status-cache temp
    // dir is created lazily only if a test writes status and is left for the OS
    // to reap — deleting it here would be real teardown I/O that stalls inside
    // testWidgets' fake-async zone.
  }
}

Future<TestStoreOverrides> buildTestStoreOverrides() async {
  final (
    projectStore,
    recentAgentsStore,
    drawerOrderStore,
    drawerCollapsedStore,
    cachedSessionsStore,
    recentPortsStore,
    prefs,
  ) = await (
    ProjectStore.open(),
    RecentAgentsStore.open(),
    DrawerOrderStore.open(),
    DrawerCollapsedStore.open(),
    CachedSessionsStore.open(),
    RecentPortsStore.open(),
    openAppSettingsPrefs(),
  ).wait;
  // Deterministic, NOT eagerly created: ProjectStatusCache.testInstance only
  // stores the path; the dir is created lazily on first write() and the file is
  // statted only when clear()/read() run. Crucially this performs NO real I/O at
  // build time, so tests that call buildTestStoreOverrides() from inside a
  // testWidgets body don't stall on the fake-async clock (createTemp would).
  // identityHashCode(projectStore) gives a per-build-unique dir without Date/
  // random (banned) or a filesystem round-trip.
  final statusCacheRoot = p.join(
    Directory.systemTemp.path,
    'antgrid-test-status-${identityHashCode(projectStore)}',
  );
  return TestStoreOverrides._(
    overrides: [
      projectStoreProvider.overrideWithValue(projectStore),
      recentAgentsStoreProvider.overrideWithValue(recentAgentsStore),
      drawerOrderStoreProvider.overrideWithValue(drawerOrderStore),
      drawerCollapsedStoreProvider.overrideWithValue(drawerCollapsedStore),
      cachedSessionsStoreProvider.overrideWithValue(cachedSessionsStore),
      recentPortsStoreProvider.overrideWithValue(recentPortsStore),
      projectStatusCacheProvider.overrideWithValue(
        ProjectStatusCache.testInstance(root: statusCacheRoot),
      ),
      appSettingsServiceProvider.overrideWith(
        () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
      ),
    ],
    projectStore: projectStore,
    recentAgentsStore: recentAgentsStore,
    drawerOrderStore: drawerOrderStore,
    cachedSessionsStore: cachedSessionsStore,
    recentPortsStore: recentPortsStore,
  );
}
