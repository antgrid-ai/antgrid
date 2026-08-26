// This device's own host identity can MOVE under an already-stored project:
// `localDeviceUuidProvider` mints an anonymous uuid whenever it is read with an
// empty keychain, and sign-in provisioning then replaces it. The prefs key
// self-heals; the project rows stamped with the outgoing value did not, and a
// row left behind fails `AbProject.isLocalFor` forever — a folder on this disk
// with no working-directory actions and a "Remote host" chip.
import 'dart:async';

import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_device_store.dart';
import '../helpers/prefs_test_mock.dart';

AbProject _project(String id, String? hostDeviceUuid) => AbProject(
  projectId: id,
  folder: '/tmp/$id',
  displayName: id,
  hostDeviceUuid: hostDeviceUuid,
  hostMachineName: '',
  lastOpenedAt: DateTime.utc(2026, 1, 1),
);

/// Echoes the requested uuid exactly as `POST /devices` does (it never mints
/// one of its own), and holds the call open so a test can move the persisted
/// host identity mid-flight — the window the race actually lives in.
class _GatedDevicesApi implements DevicesApiCreator {
  _GatedDevicesApi(this.gate);

  final Completer<void> gate;
  final started = Completer<void>();

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
    String? kind,
  }) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'cid-$deviceUuid',
      clientSecret: 'csec-$deviceUuid',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rehost moves only the rows carrying the outgoing uuid', () async {
    useInMemoryPrefs();
    final store = await ProjectStore.open();
    await store.upsert(_project('p1', 'anon-A'));
    await store.upsert(_project('p2', 'other-B'));
    await store.upsert(_project('p3', null));
    final container = ProviderContainer(
      overrides: [projectStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    await container
        .read(projectsProvider.notifier)
        .rehost(from: 'anon-A', to: 'device-K');

    final byId = {
      for (final p in container.read(projectsProvider)) p.projectId: p,
    };
    expect(byId['p1']!.hostDeviceUuid, 'device-K');
    // A row on some other uuid is NOT this device's to claim, and a pre-v2 null
    // already reads as local — neither is the row the repair is for.
    expect(byId['p2']!.hostDeviceUuid, 'other-B');
    expect(byId['p3']!.hostDeviceUuid, isNull);
  });

  test(
    'a folder opened while provisioning is in flight is re-hosted onto the '
    'provisioned uuid',
    () async {
      // Prefs starts empty, so provisioning reads no uuid to reuse and mints
      // one — the exact ordering that lets the self-heal slip in behind it.
      useInMemoryPrefs();
      final projectStore = await ProjectStore.open();
      final keychain = inMemoryDeviceStore();
      final gate = Completer<void>();
      final api = _GatedDevicesApi(gate);

      final container = ProviderContainer(
        overrides: [
          projectStoreProvider.overrideWithValue(projectStore),
          keychainDeviceStoreProvider.overrideWithValue(keychain),
          licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
          deviceProvisioningProvider.overrideWithValue(
            DeviceProvisioning(api: api, store: keychain, platform: 'linux'),
          ),
          currentUserProvider.overrideWith(
            (ref) => CurrentUser(userId: 'u-1', email: 'a@b.test'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final provisioning = ensureCurrentUserDeviceRecord(container);
      await api.started.future;
      // The desktop self-heal mints and persists an anonymous uuid, and the
      // folder picked in that window is stamped with it.
      await SharedPreferencesAsync().setString(kLocalHostUuidKey, 'anon-A');
      await projectStore.upsert(_project('p1', 'anon-A'));
      gate.complete();
      final record = await provisioning;

      expect(record.deviceUuid, isNot('anon-A'));
      expect(
        await SharedPreferencesAsync().getString(kLocalHostUuidKey),
        record.deviceUuid,
      );
      final project = container.read(projectsProvider).single;
      expect(project.hostDeviceUuid, record.deviceUuid);
      expect(project.isLocalFor(record.deviceUuid), isTrue);
    },
  );

  test('a project already on the provisioned uuid is left alone', () async {
    useInMemoryPrefs({'antgrid.local_host_uuid': 'anon-A'});
    final projectStore = await ProjectStore.open();
    await projectStore.upsert(_project('p1', 'anon-A'));
    final keychain = inMemoryDeviceStore();
    final gate = Completer<void>()..complete();
    final api = _GatedDevicesApi(gate);

    final container = ProviderContainer(
      overrides: [
        projectStoreProvider.overrideWithValue(projectStore),
        keychainDeviceStoreProvider.overrideWithValue(keychain),
        licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
        deviceProvisioningProvider.overrideWithValue(
          DeviceProvisioning(api: api, store: keychain, platform: 'linux'),
        ),
        currentUserProvider.overrideWith(
          (ref) => CurrentUser(userId: 'u-1', email: 'a@b.test'),
        ),
      ],
    );
    addTearDown(container.dispose);

    // The anon uuid is reused as the account device's, so nothing moves — this
    // is the ordinary anonymous→signed-in transition, not the race.
    final record = await ensureCurrentUserDeviceRecord(container);

    expect(record.deviceUuid, 'anon-A');
    expect(container.read(projectsProvider).single.hostDeviceUuid, 'anon-A');
  });
}
