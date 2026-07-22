import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/post_signin_provisioning.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import '../helpers/prefs_test_mock.dart';

class _MemStorage implements DeviceSecretStorage {
  String? v;
  @override
  Future<String?> read() async => v;
  @override
  Future<void> write(String s) async {
    v = s;
  }

  @override
  Future<void> delete() async {
    v = null;
  }
}

class _FakeDevicesApi implements DevicesApiCreator {
  _FakeDevicesApi({this.fail, this.gate});

  int calls = 0;

  /// When set, [createDevice] throws this instead of succeeding.
  final ProvisioningException? fail;

  /// When set, [createDevice] blocks on this before resolving — lets a test
  /// flip the signed-in user mid-flight to exercise the sign-out race.
  final Completer<void>? gate;

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
  }) async {
    calls++;
    if (gate != null) await gate!.future;
    if (fail != null) throw fail!;
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'cid-$deviceUuid',
      clientSecret: 'csec-$deviceUuid',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => useInMemoryPrefs());

  // Every test below activates `postSignInProvisioningProvider` via
  // `container.listen(..., (_, _) {})` rather than a bare `container.read`.
  // `read` closes its subscription immediately after resolving the value, so
  // in riverpod 3 the hook's own `ref.listen(currentUserProvider, ...)` goes
  // inactive right away (a provider deactivates its dependency subscriptions
  // once it has zero listeners of its own) and never sees later state changes.
  // A no-op persistent listener keeps it live for the container's lifetime,
  // matching how `main.dart` activates it in production.

  test(
    'ensures provisioning when currentUser flips null -> non-null',
    () async {
      final storage = _MemStorage();
      final store = KeychainDeviceStore(storage: storage);
      final fakeApi = _FakeDevicesApi();
      CurrentUser? userCtl;

      final container = ProviderContainer(
        overrides: [
          keychainDeviceStoreProvider.overrideWithValue(store),
          licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
          deviceProvisioningProvider.overrideWithValue(
            DeviceProvisioning(api: fakeApi, store: store, platform: 'linux'),
          ),
          currentUserProvider.overrideWith((ref) => userCtl),
        ],
      );
      addTearDown(container.dispose);

      container.listen(postSignInProvisioningProvider, (_, _) {});
      expect(fakeApi.calls, 0);

      userCtl = CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro');
      container.invalidate(currentUserProvider);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeApi.calls, 1);
      final rec = await store.read();
      expect(rec, isNotNull);
      expect(rec!.userId, 'u-1');
    },
  );

  test(
    'reuses an existing anonymous prefs UUID when provisioning a new device '
    'so the anon→signed-in transition keeps a stable device identity',
    () async {
      useInMemoryPrefs({'antgrid.local_host_uuid': 'anon-uuid-42'});
      final storage = _MemStorage();
      final store = KeychainDeviceStore(storage: storage);
      final fakeApi = _FakeDevicesApi();
      CurrentUser? userCtl;

      final container = ProviderContainer(
        overrides: [
          keychainDeviceStoreProvider.overrideWithValue(store),
          licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
          deviceProvisioningProvider.overrideWithValue(
            DeviceProvisioning(api: fakeApi, store: store, platform: 'linux'),
          ),
          currentUserProvider.overrideWith((ref) => userCtl),
        ],
      );
      addTearDown(container.dispose);
      container.listen(postSignInProvisioningProvider, (_, _) {});

      userCtl = CurrentUser(userId: 'u-1', email: 'a@b.test');
      container.invalidate(currentUserProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeApi.calls, 1);
      final rec = await store.read();
      expect(
        rec!.deviceUuid,
        'anon-uuid-42',
        reason: 'should reuse the prefs UUID instead of minting fresh',
      );
    },
  );

  test(
    'a DEVICE_CAP rejection populates deviceCapProvider (not a silent failure)',
    () async {
      final storage = _MemStorage();
      final store = KeychainDeviceStore(storage: storage);
      final cap = DeviceCapInfo(
        message:
            'Device limit reached (10/10). Remove a device to register this one.',
        limit: 10,
        devices: [
          CappedDevice(id: 'd1', deviceId: 'uuid-1', displayName: 'Old laptop'),
        ],
      );
      final fakeApi = _FakeDevicesApi(
        fail: ProvisioningException('DEVICE_CAP', cap.message, cap: cap),
      );
      CurrentUser? userCtl;

      final container = ProviderContainer(
        overrides: [
          keychainDeviceStoreProvider.overrideWithValue(store),
          licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
          deviceProvisioningProvider.overrideWithValue(
            DeviceProvisioning(api: fakeApi, store: store, platform: 'linux'),
          ),
          currentUserProvider.overrideWith((ref) => userCtl),
        ],
      );
      addTearDown(container.dispose);
      container.listen(postSignInProvisioningProvider, (_, _) {});

      expect(container.read(deviceCapProvider), isNull);

      userCtl = CurrentUser(userId: 'u-1', email: 'a@b.test');
      container.invalidate(currentUserProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final captured = container.read(deviceCapProvider);
      expect(captured, isNotNull);
      expect(captured!.limit, 10);
      expect(captured.devices.single.displayName, 'Old laptop');
      // The cap must NOT write a keychain record (provisioning never succeeded).
      expect(await store.read(), isNull);
    },
  );

  test('a DEVICE_CAP that resolves AFTER sign-out does not populate '
      'deviceCapProvider (no phantom dialog over the auth screen)', () async {
    final storage = _MemStorage();
    final store = KeychainDeviceStore(storage: storage);
    final gate = Completer<void>();
    final cap = DeviceCapInfo(message: 'capped', limit: 10);
    final fakeApi = _FakeDevicesApi(
      fail: ProvisioningException('DEVICE_CAP', cap.message, cap: cap),
      gate: gate,
    );
    CurrentUser? userCtl;

    final container = ProviderContainer(
      overrides: [
        keychainDeviceStoreProvider.overrideWithValue(store),
        licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
        deviceProvisioningProvider.overrideWithValue(
          DeviceProvisioning(api: fakeApi, store: store, platform: 'linux'),
        ),
        currentUserProvider.overrideWith((ref) => userCtl),
      ],
    );
    addTearDown(container.dispose);
    container.listen(postSignInProvisioningProvider, (_, _) {});

    // Sign in → provisioning starts and blocks on the gate.
    userCtl = CurrentUser(userId: 'u-1', email: 'a@b.test');
    container.invalidate(currentUserProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeApi.calls, 1);

    // Sign out while the request is in flight, then let it fail with the cap.
    userCtl = null;
    container.invalidate(currentUserProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The late rejection must NOT resurrect the cap for the signed-out user.
    expect(container.read(deviceCapProvider), isNull);
  });

  test(
    'does not re-provision when same user reappears (cached record)',
    () async {
      final storage = _MemStorage();
      final store = KeychainDeviceStore(storage: storage);
      final fakeApi = _FakeDevicesApi();
      CurrentUser? userCtl = CurrentUser(userId: 'u-1', email: 'a@b.test');

      final container = ProviderContainer(
        overrides: [
          keychainDeviceStoreProvider.overrideWithValue(store),
          licenseApiUrlProvider.overrideWithValue('https://api.antgrid.test'),
          deviceProvisioningProvider.overrideWithValue(
            DeviceProvisioning(api: fakeApi, store: store, platform: 'linux'),
          ),
          currentUserProvider.overrideWith((ref) => userCtl),
        ],
      );
      addTearDown(container.dispose);
      container.listen(postSignInProvisioningProvider, (_, _) {});

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fakeApi.calls, 1);

      container.invalidate(currentUserProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fakeApi.calls, 1);
    },
  );
}
