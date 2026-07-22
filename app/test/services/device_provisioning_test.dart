import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';

class FakeStorage implements DeviceSecretStorage {
  String? v;
  @override Future<String?> read() async => v;
  @override Future<void> write(String s) async { v = s; }
  @override Future<void> delete() async { v = null; }
}

class FakeDevicesApi implements DevicesApiCreator {
  ProvisioningException? fail;
  int callCount = 0;
  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
  }) async {
    callCount++;
    if (fail != null) throw fail!;
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'client-$deviceUuid',
      clientSecret: 'secret-$deviceUuid',
    );
  }
}

void main() {
  test('first-time provisioning generates keys, calls API, stores in keychain', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi();
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    final rec = await svc.ensureProvisioned(userId: 'user-1', displayName: 'host');
    expect(rec.clientSecret, isNotNull);
    expect(api.callCount, 1);
    final stored = await store.read();
    expect(stored, isNotNull);
    expect(stored!.userId, 'user-1');
    expect(stored.clientId, rec.clientId);
  });

  test('returns cached record on subsequent call (no API call)', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi();
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    final r1 = await svc.ensureProvisioned(userId: 'u', displayName: 'h');
    final r2 = await svc.ensureProvisioned(userId: 'u', displayName: 'h');
    expect(r2.clientId, r1.clientId);
    expect(api.callCount, 1);
  });

  test('identity mismatch clears keychain and re-provisions', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi();
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    await svc.ensureProvisioned(userId: 'A', displayName: 'h');
    final r2 = await svc.ensureProvisioned(userId: 'B', displayName: 'h');
    expect(r2.clientSecret, isNotNull);
    expect(api.callCount, 2);
    final stored = await store.read();
    expect(stored!.userId, 'B');
  });

  test('concurrent ensureProvisioned calls share one in-flight attempt', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi();
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    // Simulates postSignInProvisioning/localHostWarmup/agentTransport all
    // resolving the device record at sign-in without awaiting each other.
    final results = await Future.wait([
      svc.ensureProvisioned(userId: 'u', displayName: 'h'),
      svc.ensureProvisioned(userId: 'u', displayName: 'h'),
      svc.ensureProvisioned(userId: 'u', displayName: 'h'),
    ]);
    expect(api.callCount, 1);
    expect(results.map((r) => r.clientId).toSet(), {results.first.clientId});
    expect(results.map((r) => r.ed25519Pub).toSet(), {results.first.ed25519Pub});
  });

  test('PAYMENT exception propagates', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi()..fail = ProvisioningException('PAYMENT', 'Subscription required');
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    await expectLater(
      svc.ensureProvisioned(userId: 'u', displayName: 'h'),
      throwsA(isA<ProvisioningException>().having((e) => e.code, 'code', 'PAYMENT')),
    );
    expect(await store.read(), isNull);
  });
}
