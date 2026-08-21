import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/project_store.dart';

import '../helpers/prefs_test_mock.dart';

/// Regression cover for the ISOLATED-session breadcrumb rendering a 16-char
/// projectId as the project name: the title bar falls back to this provider
/// when the focused checkout never received an `agent:status`.
void main() {
  late ProjectStore projectStore;
  late CachedSessionsStore cachedSessionsStore;

  Future<ProviderContainer> containerFor() async {
    useInMemoryPrefs();
    projectStore = await ProjectStore.open();
    cachedSessionsStore = await CachedSessionsStore.open();
    addTearDown(cachedSessionsStore.close);
    final container = ProviderContainer(
      overrides: [
        projectStoreProvider.overrideWithValue(projectStore),
        cachedSessionsStoreProvider.overrideWithValue(cachedSessionsStore),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a local project resolves to its stored display name', () async {
    final container = await containerFor();
    await container
        .read(projectsProvider.notifier)
        .upsert(
          AbProject(
            projectId: '6e5c50e5d6f973a8',
            folder: '/repos/antgrid',
            displayName: 'antgrid',
            hostDeviceUuid: 'uuidA',
            hostMachineName: 'desk',
            lastOpenedAt: DateTime.now(),
          ),
        );

    expect(
      container.read(projectDisplayNameProvider('6e5c50e5d6f973a8')),
      'antgrid',
    );
  });

  test('a remote project resolves to its control-plane advert label', () async {
    final container = await containerFor();
    container
        .read(remoteProjectLabelsProvider.notifier)
        .put('uuidA.6e5c50e5d6f973a8', 'antgrid');

    expect(
      container.read(projectDisplayNameProvider('uuidA.6e5c50e5d6f973a8')),
      'antgrid',
    );
  });

  test('an unknown id yields null, never the raw hash', () async {
    final container = await containerFor();
    // Null is the contract: a caller with a live `agent:status` name must be
    // able to prefer it, and only fall through to the id as a last resort.
    expect(
      container.read(projectDisplayNameProvider('6e5c50e5d6f973a8')),
      isNull,
    );
  });
}
