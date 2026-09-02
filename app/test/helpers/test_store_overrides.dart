// Test helper that materializes the persistent-store providers main()
// expects to be overridden. Tests that mount widgets reading from
// `recentAgentsProvider`, `projectsProvider`, etc. can call
// [buildTestStoreOverrides] inside their test setup to satisfy those
// throw-by-default providers.
//
// Caller is responsible for calling useInMemoryPrefs() (test/helpers/prefs_test_mock.dart) before invocation (the stores read prefs eagerly on open).
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/misc.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/collapsed_drawer.dart';
import 'package:antgrid/providers/drawer_order.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/update_available.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusCacheProvider;
import 'package:antgrid/project/project_status_cache.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/drawer_collapsed_store.dart';
import 'package:antgrid/storage/drawer_order_store.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/storage/update_handoff_store.dart';

class TestStoreOverrides {
  final List<Override> overrides;
  final ProjectStore projectStore;
  final RecentAgentsStore recentAgentsStore;
  final DrawerOrderStore drawerOrderStore;
  final CachedSessionsStore cachedSessionsStore;

  TestStoreOverrides._({
    required this.overrides,
    required this.projectStore,
    required this.recentAgentsStore,
    required this.drawerOrderStore,
    required this.cachedSessionsStore,
  });

  /// Releases the stores, but deliberately does not AWAIT them.
  ///
  /// Each close() runs synchronously up to its first suspension — the stream
  /// controllers are marked closed and CachedSessionsStore cancels its pending
  /// flush timer — so nothing leaks into the next test. What is skipped is only
  /// the confirmation: CachedSessionsStore.close() flushes through
  /// SharedPreferencesAsync, and awaiting that real I/O inside testWidgets'
  /// fake-async zone wedges the tearDown whenever a test FAILS, because the
  /// binding only drains real async on the passing path. That hung the runner
  /// forever (never a timeout — you have to kill it), and a green run can't show
  /// it, so it only ever bites while debugging a failure. Nothing reads these
  /// per-test temp stores afterwards, so the write itself is pointless work.
  ///
  /// Same reasoning as the status-cache temp dir, which is left for the OS to
  /// reap. ProjectStore and DrawerOrderStore have no close() at all.
  Future<void> close() async {
    unawaited(recentAgentsStore.close());
    unawaited(cachedSessionsStore.close());
  }
}

Future<TestStoreOverrides> buildTestStoreOverrides() async {
  final (
    projectStore,
    recentAgentsStore,
    drawerOrderStore,
    drawerCollapsedStore,
    cachedSessionsStore,
    firstRunStore,
    updateHandoffStore,
    prefs,
  ) = await (
    ProjectStore.open(),
    RecentAgentsStore.open(),
    DrawerOrderStore.open(),
    DrawerCollapsedStore.open(),
    CachedSessionsStore.open(),
    FirstRunStore.open(),
    UpdateHandoffStore.open(),
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
      firstRunStoreProvider.overrideWithValue(firstRunStore),
      updateHandoffStoreProvider.overrideWithValue(updateHandoffStore),
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
  );
}
