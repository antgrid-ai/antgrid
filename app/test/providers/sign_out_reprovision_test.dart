import 'dart:convert';

import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/sign_out.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/services/sign_out_service.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_device_store.dart';
import '../helpers/prefs_test_mock.dart';

class _FakeDevicesApi implements DevicesApiCreator {
  final List<String> createdUuids = <String>[];

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
    String? kind,
  }) async {
    createdUuids.add(deviceUuid);
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'cid-$deviceUuid',
      clientSecret: 'csec-$deviceUuid',
    );
  }
}

class _MemAuthStorage implements AuthStorage {
  String? _cookie = 'better-auth.session_token=signed.value';
  @override
  Future<String?> readCookie() async => _cookie;
  @override
  Future<void> writeCookie(String v) async => _cookie = v;
  @override
  Future<void> clearCookie() async => _cookie = null;
  @override
  Future<String?> readPendingSignIn() async => null;
  @override
  Future<void> writePendingSignIn(String v) async {}
  @override
  Future<void> clearPendingSignIn() async {}
}

class _NoopPushIdentity implements PushIdentity {
  @override
  Future<void> clear() async {}
  @override
  Future<PushKeypair> ensureKeypair() async => throw UnimplementedError();
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
  });

  test(
    'hard sign-out lets the desktop controller record be re-provisioned',
    () async {
      final store = fakeDeviceStoreFromRecord(_mainRecord());
      final api = _FakeDevicesApi();
      final recents = await RecentAgentsStore.open();

      final container = ProviderContainer(
        overrides: [
          isMobilePlatformProvider.overrideWithValue(false),
          keychainDeviceStoreProvider.overrideWithValue(store),
          deviceProvisioningProvider.overrideWithValue(
            DeviceProvisioning(api: api, store: store, platform: 'windows'),
          ),
          currentUserProvider.overrideWith(
            (ref) => CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro'),
          ),
          recentAgentsStoreProvider.overrideWithValue(recents),
          // The real teardown minus the Riverpod-wired callbacks: what matters
          // here is that it clears the controller keychain slot, exactly as the
          // production wiring does. The network-backed steps fail and are
          // swallowed, which is also what happens on a signed-out machine.
          signOutServiceProvider.overrideWithValue(
            SignOutService(
              authService: AuthService(
                licenseApiUrl: 'http://127.0.0.1:1',
                storage: _MemAuthStorage(),
              ),
              keychainStore: store,
              devicesApi: DevicesApi(
                licenseApiUrl: 'http://127.0.0.1:1',
                cookieProvider: () async => null,
              ),
              pushIdentity: _NoopPushIdentity(),
              recentAgentsStore: recents,
              secureStorage: const FlutterSecureStorage(),
              onStepError: (_, _) {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final before = await container.read(connectionDeviceRecordProvider.future);
      expect(api.createdUuids, hasLength(1));

      await performHardSignOut(container);

      // Sign-out deleted this row and its OAuth client server-side, so reusing
      // it mints `400 invalid_client` forever and no "(controller)" device ever
      // returns to the account. Re-reading must provision a fresh one.
      final after = await container.read(connectionDeviceRecordProvider.future);

      expect(
        api.createdUuids,
        hasLength(2),
        reason: 'the controller record must be provisioned again after sign-out',
      );
      expect(after.deviceUuid, isNot(before.deviceUuid));
      expect(after.clientId, isNot(before.clientId));
    },
  );
}
