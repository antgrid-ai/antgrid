import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/services/provisioning_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_device_store.dart';

class _DevicesApi implements DevicesApiCreator {
  _DevicesApi({this.failure});

  final ProvisioningException? failure;
  int calls = 0;

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String platform,
    required String displayName,
    String? kind,
  }) async {
    calls++;
    final error = failure;
    if (error != null) throw error;
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'client-$deviceUuid',
      clientSecret: 'secret-$deviceUuid',
    );
  }
}

ProvisioningCoordinator _coordinator({
  required DevicesApiCreator api,
  required KeychainDeviceStore store,
  required CurrentUser? Function() currentUser,
  required void Function() publishSuccess,
  required void Function(DeviceCapInfo? cap) publishDeviceCap,
  String? hostUuid = 'host-1',
}) {
  var persistedHostUuid = hostUuid;
  return ProvisioningCoordinator(
    provisioning: DeviceProvisioning(api: api, store: store, platform: 'linux'),
    store: store,
    readCurrentUser: () async => currentUser(),
    currentUserId: () => currentUser()?.userId,
    readDisplayName: () async => 'Test machine',
    readLocalHostUuid: () async => persistedHostUuid,
    writeLocalHostUuid: (value) async => persistedHostUuid = value,
    rehostLocalProjects: ({required from, required to}) async {},
    publishSuccess: publishSuccess,
    publishDeviceCap: publishDeviceCap,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'post-sign-in and retry publish the same success side effects',
    () async {
      final store = inMemoryDeviceStore();
      final api = _DevicesApi();
      final user = CurrentUser(userId: 'user-1', email: 'user@example.test');
      var successes = 0;
      final caps = <DeviceCapInfo?>[];
      final coordinator = _coordinator(
        api: api,
        store: store,
        currentUser: () => user,
        publishSuccess: () => successes++,
        publishDeviceCap: caps.add,
      );

      await coordinator.provisionSignedInUser(user.userId);
      await coordinator.retryCurrentUser();

      expect(
        api.calls,
        1,
        reason: 'retry reuses the provisioned keychain record',
      );
      expect(successes, 2);
      expect(caps, [null, null]);
    },
  );

  test('a cap result is published by the coordinator and rethrown', () async {
    final cap = DeviceCapInfo(
      message: 'Device limit reached',
      kind: DeviceCapKind.appDevice,
      limit: 2,
    );
    final error = ProvisioningException(
      'APP_DEVICE_CAP',
      cap.message,
      cap: cap,
    );
    final user = CurrentUser(userId: 'user-1', email: 'user@example.test');
    final published = <DeviceCapInfo?>[];
    final coordinator = _coordinator(
      api: _DevicesApi(failure: error),
      store: inMemoryDeviceStore(),
      currentUser: () => user,
      publishSuccess: () => fail('must not publish success'),
      publishDeviceCap: published.add,
    );

    await expectLater(
      coordinator.provisionSignedInUser(user.userId),
      throwsA(same(error)),
    );
    expect(published, [cap]);
  });
}
