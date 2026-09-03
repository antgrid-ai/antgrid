import 'dart:io' show Platform;

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

AbProject _project(String id) => AbProject(
  projectId: id,
  folder: '/tmp/$id',
  displayName: id,
  hostDeviceUuid: 'host-1',
  hostMachineName: 'host',
  lastOpenedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => useInMemoryPrefs());

  group('missingLocalProjects', () {
    test('turns a known project absent from locals into an AbProject', () {
      final out = missingLocalProjects(
        locals: [_project('p1')],
        known: const [
          KnownProject(projectId: 'p1', path: '/tmp/p1', running: false),
          KnownProject(
            projectId: 'p2',
            path: '/tmp/p2',
            label: 'grisb-training',
            running: true,
            lastActiveAt: '2026-02-01T00:00:00.000Z',
          ),
        ],
        hostUuid: 'host-1',
      );

      expect(out, hasLength(1));
      expect(out.single.projectId, 'p2');
      expect(out.single.folder, '/tmp/p2');
      expect(out.single.displayName, 'grisb-training');
      expect(out.single.hostDeviceUuid, 'host-1');
      expect(out.single.lastOpenedAt, DateTime.parse('2026-02-01T00:00:00.000Z'));
    });

    test('falls back to the path basename when the catalog carries no label', () {
      final sep = Platform.pathSeparator;
      final out = missingLocalProjects(
        locals: const [],
        known: [
          KnownProject(
            projectId: 'p1',
            path: '${sep}Users${sep}me${sep}Grisb.Preview',
            running: false,
          ),
        ],
        hostUuid: 'host-1',
      );

      expect(out.single.displayName, 'Grisb.Preview');
    });

    test('skips a catalog hint with no path — nothing to open it with', () {
      final out = missingLocalProjects(
        locals: const [],
        known: const [KnownProject(projectId: 'p1', running: false)],
        hostUuid: 'host-1',
      );

      expect(out, isEmpty);
    });
  });

  test(
    'backfillFromHost registers a project the bridge knows about but the '
    "app's own store never saw — e.g. one opened from another device's "
    'remote-control session on this machine',
    () async {
      final store = await ProjectStore.open();
      await store.upsert(_project('p1'));

      final container = ProviderContainer(
        overrides: [projectStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      await container.read(projectsProvider.notifier).backfillFromHost(
        const [
          KnownProject(projectId: 'p1', path: '/tmp/p1', running: false),
          KnownProject(
            projectId: 'p2',
            path: '/tmp/grisb-training',
            label: 'grisb-training',
            running: false,
          ),
        ],
        hostUuid: 'host-1',
      );

      final ids = container.read(projectsProvider).map((p) => p.projectId);
      expect(ids, containsAll(['p1', 'p2']));
      final backfilled = container
          .read(projectsProvider)
          .firstWhere((p) => p.projectId == 'p2');
      expect(backfilled.displayName, 'grisb-training');
      expect(backfilled.hostDeviceUuid, 'host-1');
    },
  );
}
