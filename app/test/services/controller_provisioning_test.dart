import 'dart:convert';

import 'package:antgrid/services/device_provisioning.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_device_store.dart';

class RecordingDevicesApi implements DevicesApiCreator {
  int createCalls = 0;
  final List<String?> kinds = <String?>[];
  final List<String> deviceUuids = <String>[];
  final List<String> ed25519Pubs = <String>[];

  @override
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,
    String? kind,
  }) async {
    createCalls++;
    kinds.add(kind);
    deviceUuids.add(deviceUuid);
    ed25519Pubs.add(ed25519Pub);
    // Yield so concurrent callers genuinely interleave — a synchronous fake
    // would make the single-flight assertion pass even without the guard.
    await Future<void>.delayed(Duration.zero);
    return CreatedDevice(
      deviceUuid: deviceUuid,
      clientId: 'cid-$deviceUuid',
      clientSecret: 'csec-$deviceUuid',
    );
  }
}

void main() {
  test('desktop provisions a controller record with its own uuid, keys '
      'and oauth client', () async {
    final api = RecordingDevicesApi();
    final store = inMemoryDeviceStore();
    final prov = DeviceProvisioning(
      api: api,
      store: store,
      platform: 'windows',
    );

    final main = await prov.ensureProvisioned(
      userId: 'u1',
      displayName: 'Desk',
    );
    final rec = await prov.ensureControllerProvisioned(
      userId: 'u1',
      displayName: 'Desk controller',
    );

    expect(api.kinds.last, 'app');
    expect(rec.deviceUuid, isNot(equals(main.deviceUuid)));
    expect(rec.ed25519Pub, isNot(equals(main.ed25519Pub)));
    expect(rec.clientId, isNot(equals(main.clientId)));
    expect(rec.clientSecret, isNotEmpty);
    expect(base64Decode(rec.ed25519Priv).length, 32);
    expect(await store.readController(), isNotNull);
    expect((await store.readController())!.deviceUuid, rec.deviceUuid);
  });

  test('the controller slot never disturbs the main record', () async {
    final api = RecordingDevicesApi();
    final store = inMemoryDeviceStore();
    final prov = DeviceProvisioning(api: api, store: store, platform: 'macos');

    final main = await prov.ensureProvisioned(userId: 'u1', displayName: 'Mac');
    await prov.ensureControllerProvisioned(
      userId: 'u1',
      displayName: 'Mac controller',
    );

    expect((await store.read())!.deviceUuid, main.deviceUuid);

    await store.clearController();
    expect(await store.readController(), isNull);
    expect(await store.read(), isNotNull);
  });

  test('ensureControllerProvisioned is single-flight and idempotent', () async {
    final api = RecordingDevicesApi();
    final store = inMemoryDeviceStore();
    final prov = DeviceProvisioning(api: api, store: store, platform: 'linux');

    final results = await Future.wait([
      prov.ensureControllerProvisioned(userId: 'u1', displayName: 'c'),
      prov.ensureControllerProvisioned(userId: 'u1', displayName: 'c'),
    ]);
    expect(results[0].deviceUuid, results[1].deviceUuid);
    expect(api.createCalls, 1);

    // A later call must reuse the persisted record rather than mint a second
    // OAuth client (which would orphan the first against the device cap).
    final again = await prov.ensureControllerProvisioned(
      userId: 'u1',
      displayName: 'c',
    );
    expect(again.deviceUuid, results[0].deviceUuid);
    expect(api.createCalls, 1);
  });

  test('a different user re-provisions the controller slot', () async {
    final api = RecordingDevicesApi();
    final store = inMemoryDeviceStore();
    final prov = DeviceProvisioning(api: api, store: store, platform: 'linux');

    final a = await prov.ensureControllerProvisioned(
      userId: 'A',
      displayName: 'c',
    );
    final b = await prov.ensureControllerProvisioned(
      userId: 'B',
      displayName: 'c',
    );

    expect(b.deviceUuid, isNot(equals(a.deviceUuid)));
    expect(api.createCalls, 2);
    expect((await store.readController())!.userId, 'B');
  });

  test('the main record still registers without an explicit kind', () async {
    final api = RecordingDevicesApi();
    final store = inMemoryDeviceStore();
    final prov = DeviceProvisioning(
      api: api,
      store: store,
      platform: 'windows',
    );

    await prov.ensureProvisioned(userId: 'u1', displayName: 'Desk');

    // Desktop's main record must keep deriving kind:"agent" server-side — it is
    // the local bridge's relay identity.
    expect(api.kinds.single, isNull);
  });
}
