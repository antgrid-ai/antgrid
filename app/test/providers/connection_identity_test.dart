import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/providers/auth.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_device_store.dart';
import '../helpers/prefs_test_mock.dart';

class _FakeDevicesApi implements DevicesApiCreator {
  int calls = 0;
  final List<String?> kinds = <String?>[];

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
    String? kind,
  }) async {
    calls++;
    kinds.add(kind);
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'cid-$deviceUuid',
      clientSecret: 'csec-$deviceUuid',
    );
  }
}

DeviceRecord _mainRecord() => DeviceRecord(
  userId: 'u-1',
  deviceUuid: 'main-uuid',
  clientId: 'main-cid',
  clientSecret: 'main-secret',
  ed25519Pub: base64Encode(List<int>.filled(32, 1)),
  ed25519Priv: base64Encode(List<int>.filled(32, 2)),
  x25519Pub: base64Encode(List<int>.filled(32, 3)),
  x25519Priv: base64Encode(List<int>.filled(32, 4)),
);

ProviderContainer _container({
  required bool isMobile,
  required KeychainDeviceStore store,
  required DevicesApiCreator api,
}) {
  final container = ProviderContainer(
    overrides: [
      isMobilePlatformProvider.overrideWithValue(isMobile),
      keychainDeviceStoreProvider.overrideWithValue(store),
      deviceProvisioningProvider.overrideWithValue(
        DeviceProvisioning(api: api, store: store, platform: 'windows'),
      ),
      currentUserProvider.overrideWith(
        (ref) => CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro'),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => useInMemoryPrefs());

  test('mobile connects as the MAIN account device record', () async {
    final store = fakeDeviceStoreFromRecord(_mainRecord());
    final api = _FakeDevicesApi();
    final container = _container(isMobile: true, store: store, api: api);

    final rec = await container.read(connectionDeviceRecordProvider.future);

    expect(rec.deviceUuid, 'main-uuid');
    expect(api.calls, 0, reason: 'mobile provisions no second device');
    expect(await store.readController(), isNull);
  });

  test('desktop connects as a dedicated kind:app controller record', () async {
    final store = fakeDeviceStoreFromRecord(_mainRecord());
    final api = _FakeDevicesApi();
    final container = _container(isMobile: false, store: store, api: api);

    final rec = await container.read(connectionDeviceRecordProvider.future);

    expect(
      rec.deviceUuid,
      isNot('main-uuid'),
      reason: 'reusing the bridge deviceId would lose epoch arbitration',
    );
    expect(api.kinds.single, 'app');
    expect((await store.readController())!.deviceUuid, rec.deviceUuid);
    expect(
      (await store.read())!.deviceUuid,
      'main-uuid',
      reason: 'the local bridge identity is untouched',
    );
  });

  test('desktop reuses an already-provisioned controller record', () async {
    final store = fakeDeviceStoreFromRecord(_mainRecord());
    final api = _FakeDevicesApi();
    final first = _container(isMobile: false, store: store, api: api);
    final a = await first.read(connectionDeviceRecordProvider.future);

    final second = _container(isMobile: false, store: store, api: api);
    final b = await second.read(connectionDeviceRecordProvider.future);

    expect(b.deviceUuid, a.deviceUuid);
    expect(api.calls, 1);
  });

  test(
    'desktop never connects as a controller left behind by another account',
    () async {
      // Switching accounts without a hard sign-out leaves the previous user's
      // controller in the slot. Its clientId/clientSecret mint OAuth tokens
      // under THAT account, so reusing it would make the relay stamp this
      // socket's userId — and therefore sessionLimit and peer visibility —
      // with the wrong account.
      final stale = DeviceRecord(
        userId: 'u-previous',
        deviceUuid: 'stale-controller',
        clientId: 'stale-cid',
        clientSecret: 'stale-secret',
        ed25519Pub: base64Encode(List<int>.filled(32, 7)),
        ed25519Priv: base64Encode(List<int>.filled(32, 8)),
        x25519Pub: base64Encode(List<int>.filled(32, 9)),
        x25519Priv: base64Encode(List<int>.filled(32, 10)),
      );
      final store = KeychainDeviceStore(
        storage: InMemoryDeviceSecretStorage(
          jsonEncode(_mainRecord().toJson()),
        ),
        controllerStorage: InMemoryDeviceSecretStorage(
          jsonEncode(stale.toJson()),
        ),
      );
      final api = _FakeDevicesApi();
      final container = _container(isMobile: false, store: store, api: api);

      final rec = await container.read(connectionDeviceRecordProvider.future);

      expect(rec.deviceUuid, isNot('stale-controller'));
      expect(rec.userId, 'u-1');
      expect(
        rec.clientId,
        isNot('stale-cid'),
        reason: 'the previous account\'s credentials must never mint for u-1',
      );
      expect(api.calls, 1, reason: 'a controller is provisioned for u-1');
      expect(api.kinds.single, 'app');
    },
  );

  test('connectionIdentityFor maps the record onto a DeviceIdentity', () {
    final rec = _mainRecord();
    final identity = connectionIdentityFor(rec, machineDeviceId: 'machine-1');

    expect(identity.deviceId, relaySlotId(rec.deviceUuid, 'machine-1'));
    expect(identity.ed25519PublicKey, Uint8List.fromList(List.filled(32, 1)));
    expect(identity.ed25519PrivateKey, Uint8List.fromList(List.filled(32, 2)));
    expect(identity.x25519PublicKey, Uint8List.fromList(List.filled(32, 3)));
    expect(identity.x25519PrivateKey, Uint8List.fromList(List.filled(32, 4)));
  });

  test('connectionIdentityFor gives each machine its own relay slot', () {
    final rec = _mainRecord();
    final a = connectionIdentityFor(rec, machineDeviceId: 'machine-a');
    final b = connectionIdentityFor(rec, machineDeviceId: 'machine-b');

    // The whole point: two machines wanted at once must not arbitrate against
    // each other on one `hello.deviceId`.
    expect(a.deviceId, isNot(b.deviceId));
    // …while still resolving back to the one account device the E2E transcript
    // and the agent's peers inventory are keyed by.
    expect(baseSlotDeviceId(a.deviceId), rec.deviceUuid);
    expect(baseSlotDeviceId(b.deviceId), rec.deviceUuid);
  });
}
