import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';

class FakeStorage implements DeviceSecretStorage {
  String? v;
  bool failWrites = false;
  @override
  Future<String?> read() async => v;
  @override
  Future<void> write(String s) async {
    if (failWrites) throw StateError('secure storage unavailable');
    v = s;
  }

  @override
  Future<void> delete() async {
    v = null;
  }
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
    String? kind,
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
  for (final controller in [false, true]) {
    test(
      'cached ${controller ? "controller" : "primary"} gains one persistent endpoint key without changing identity',
      () async {
        final primary = FakeStorage();
        final secondary = FakeStorage();
        final store = KeychainDeviceStore(
          storage: primary,
          controllerStorage: secondary,
        );
        final legacy = DeviceRecord(
          userId: 'owner',
          deviceUuid: 'device',
          clientId: 'client',
          clientSecret: 'credential-secret',
          ed25519Pub: 'ed-pub',
          ed25519Priv: 'ed-secret',
          x25519Pub: 'x-pub',
          x25519Priv: 'x-secret',
        );
        if (controller) {
          await store.writeController(legacy);
        } else {
          await store.write(legacy);
        }
        final api = FakeDevicesApi();
        final service = DeviceProvisioning(
          api: api,
          store: store,
          platform: 'linux',
        );
        Future<DeviceRecord> ensure() => controller
            ? service.ensureControllerProvisioned(
                userId: 'owner',
                displayName: 'controller',
              )
            : service.ensureProvisioned(userId: 'owner', displayName: 'host');
        final records = await Future.wait([ensure(), ensure(), ensure()]);
        expect(
          records.map((record) => record.endpointSecret).toSet(),
          hasLength(1),
        );
        expect(base64Decode(records.first.endpointSecret!), hasLength(32));
        final identity = records.first.toJson()..remove('endpointSecret');
        expect(identity, legacy.toJson());
        final stored = controller
            ? await store.readController()
            : await store.read();
        expect(stored!.endpointSecret, records.first.endpointSecret);
        expect((await ensure()).endpointSecret, records.first.endpointSecret);
        expect(api.callCount, 0);
      },
    );

    test(
      'failed ${controller ? "controller" : "primary"} endpoint storage never returns an ephemeral identity',
      () async {
        final storage = FakeStorage();
        final store = KeychainDeviceStore(
          storage: controller ? FakeStorage() : storage,
          controllerStorage: controller ? storage : FakeStorage(),
        );
        final legacy = DeviceRecord(
          userId: 'owner',
          deviceUuid: 'device',
          clientId: 'client',
          clientSecret: 'secret',
          ed25519Pub: 'ed-pub',
          ed25519Priv: 'ed-secret',
          x25519Pub: 'x-pub',
          x25519Priv: 'x-secret',
        );
        if (controller) {
          await store.writeController(legacy);
        } else {
          await store.write(legacy);
        }
        storage.failWrites = true;
        final api = FakeDevicesApi();
        final service = DeviceProvisioning(
          api: api,
          store: store,
          platform: 'linux',
        );
        final pending = controller
            ? service.ensureControllerProvisioned(
                userId: 'owner',
                displayName: 'controller',
              )
            : service.ensureProvisioned(userId: 'owner', displayName: 'host');
        await expectLater(pending, throwsA(isA<ProvisioningException>()));
        final stored = controller
            ? await store.readController()
            : await store.read();
        expect(stored!.toJson(), legacy.toJson());
        expect(api.callCount, 0);
      },
    );
  }

  test(
    'first-time provisioning generates keys, calls API, stores in keychain',
    () async {
      final store = KeychainDeviceStore(storage: FakeStorage());
      final api = FakeDevicesApi();
      final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
      final rec = await svc.ensureProvisioned(
        userId: 'user-1',
        displayName: 'host',
      );
      expect(rec.clientSecret, isNotNull);
      expect(api.callCount, 1);
      final stored = await store.read();
      expect(stored, isNotNull);
      expect(stored!.userId, 'user-1');
      expect(stored.clientId, rec.clientId);
      expect(base64Decode(rec.endpointSecret!), hasLength(32));
      expect(stored.endpointSecret, rec.endpointSecret);
      expect(rec.endpointSecret, isNot(rec.ed25519Priv));
    },
  );

  test('returns cached record on subsequent call (no API call)', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi();
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    final r1 = await svc.ensureProvisioned(userId: 'u', displayName: 'h');
    final r2 = await svc.ensureProvisioned(userId: 'u', displayName: 'h');
    expect(r2.clientId, r1.clientId);
    expect(r2.endpointSecret, r1.endpointSecret);
    expect(api.callCount, 1);
  });

  test(
    'bridge and controller endpoint keys have distinct enrollment lifetimes',
    () async {
      final store = KeychainDeviceStore(
        storage: FakeStorage(),
        controllerStorage: FakeStorage(),
      );
      final svc = DeviceProvisioning(
        api: FakeDevicesApi(),
        store: store,
        platform: 'linux',
      );
      final bridge = await svc.ensureProvisioned(
        userId: 'owner',
        displayName: 'host',
      );
      final controller = await svc.ensureControllerProvisioned(
        userId: 'owner',
        displayName: 'controller',
      );
      expect(controller.endpointSecret, isNot(bridge.endpointSecret));
      await store.clearController();
      expect((await store.read())!.endpointSecret, bridge.endpointSecret);
      expect(await store.readController(), isNull);
    },
  );

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

  test(
    'concurrent ensureProvisioned calls share one in-flight attempt',
    () async {
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
      expect(results.map((r) => r.ed25519Pub).toSet(), {
        results.first.ed25519Pub,
      });
    },
  );

  test('PAYMENT exception propagates', () async {
    final store = KeychainDeviceStore(storage: FakeStorage());
    final api = FakeDevicesApi()
      ..fail = ProvisioningException('PAYMENT', 'Subscription required');
    final svc = DeviceProvisioning(api: api, store: store, platform: 'linux');
    await expectLater(
      svc.ensureProvisioned(userId: 'u', displayName: 'h'),
      throwsA(
        isA<ProvisioningException>().having((e) => e.code, 'code', 'PAYMENT'),
      ),
    );
    expect(await store.read(), isNull);
  });
}
