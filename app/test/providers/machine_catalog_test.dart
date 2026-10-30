import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/project_catalog.dart';
import 'package:antgrid/providers/machine_catalog.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

AdvertisedProject advertised(String id, {Object? remote = _absent}) =>
    AdvertisedProject.fromJson({
      'projectId': id,
      'label': 'label-$id',
      'running': false,
      if (remote != _absent) 'gitRemote': remote,
    })!;

const _absent = Object();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => useInMemoryPrefs());

  group('advert parsing', () {
    test('keeps "no remote" apart from "not probed yet"', () {
      final none = advertised('a', remote: null);
      expect(none.gitRemoteProbed, isTrue);
      expect(none.gitRemote, isNull);

      final unprobed = advertised('b');
      expect(unprobed.gitRemoteProbed, isFalse);

      final keyed = advertised('c', remote: 'github.com/a/b');
      expect(keyed.gitRemote, 'github.com/a/b');
    });
  });

  group('catalogFromAdvert', () {
    test('replaces the catalog from an advert with remote access on', () {
      final catalog = catalogFromAdvert(
        ControlPlaneState(
          projects: [advertised('a', remote: 'r/a')],
          remoteAccessEnabled: true,
        ),
      );
      expect(catalog, [
        const CatalogProject(
          projectId: 'a',
          label: 'label-a',
          gitRemote: 'r/a',
          gitRemoteProbed: true,
        ),
      ]);
    });

    test('an empty list with remote access on is a real answer', () {
      expect(
        catalogFromAdvert(const ControlPlaneState(remoteAccessEnabled: true)),
        isEmpty,
      );
    });

    test('remote access off leaves the stored catalog alone', () {
      expect(
        catalogFromAdvert(const ControlPlaneState(remoteAccessEnabled: false)),
        isNull,
      );
    });

    test('no advert yet leaves it alone; an older bridge listing projects replaces it', () {
      expect(catalogFromAdvert(const ControlPlaneState()), isNull);
      expect(
        catalogFromAdvert(ControlPlaneState(projects: [advertised('a')])),
        hasLength(1),
      );
    });
  });

  group('mergeLocalCatalog', () {
    test('updates probed warm projects and keeps cold ones', () {
      const cold = CatalogProject(
        projectId: 'cold',
        gitRemote: 'r/cold',
        gitRemoteProbed: true,
      );
      final merged = mergeLocalCatalog(
        [cold],
        const [
          ProjectSummary(
            projectId: 'warm',
            path: '/w',
            running: true,
            mode: 'local',
            gitRemote: 'r/warm',
            gitRemoteProbed: true,
          ),
          ProjectSummary(
            projectId: 'unprobed',
            path: '/u',
            running: true,
            mode: 'local',
          ),
        ],
      );
      expect(merged.map((p) => p.projectId), ['cold', 'warm']);
      expect(merged.last.gitRemote, 'r/warm');
    });
  });

  group('CachedSessionsStore catalogs', () {
    test('round-trips through disk and drops the sample project', () async {
      final store = await CachedSessionsStore.open();
      store.putCatalog('mbp', const [
        CatalogProject(projectId: 'a', label: 'A', gitRemoteProbed: true),
        CatalogProject(projectId: kDemoProjectId, label: 'demo'),
      ]);
      await store.flushNow();

      final reopened = await CachedSessionsStore.open();
      final catalog = reopened.catalogs()['mbp']!;
      expect(catalog, [
        const CatalogProject(projectId: 'a', label: 'A', gitRemoteProbed: true),
      ]);
    });

    test('sign-out clears catalogs', () async {
      final store = await CachedSessionsStore.open();
      store.putCatalog('mbp', const [CatalogProject(projectId: 'a')]);
      await store.clear();
      expect((await CachedSessionsStore.open()).catalogs(), isEmpty);
    });
  });
}
