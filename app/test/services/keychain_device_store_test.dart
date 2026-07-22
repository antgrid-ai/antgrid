import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/keychain_device_store.dart';

class FakeSecureStorage implements DeviceSecretStorage {
  String? _value;
  @override Future<String?> read() async => _value;
  @override Future<void> write(String v) async { _value = v; }
  @override Future<void> delete() async { _value = null; }
}

DeviceRecord _sample({String userId = 'user-1', String uuid = '00000000-0000-0000-0000-000000000001'}) =>
    DeviceRecord(
      userId: userId, deviceUuid: uuid,
      clientId: 'cid', clientSecret: 'csec',
      ed25519Pub: 'a', ed25519Priv: 'b',
      x25519Pub: 'c', x25519Priv: 'd',
    );

void main() {
  test('round-trips a device record', () async {
    final store = KeychainDeviceStore(storage: FakeSecureStorage());
    await store.write(_sample());
    final got = await store.read();
    expect(got, isNotNull);
    expect(got!.clientSecret, 'csec');
    expect(got.userId, 'user-1');
  });

  test('returns null when no record present', () async {
    final store = KeychainDeviceStore(storage: FakeSecureStorage());
    expect(await store.read(), isNull);
  });

  test('clear() removes the record', () async {
    final store = KeychainDeviceStore(storage: FakeSecureStorage());
    await store.write(_sample());
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('readIfMatchesUser returns null on userId mismatch', () async {
    final store = KeychainDeviceStore(storage: FakeSecureStorage());
    await store.write(_sample(userId: 'user-A'));
    expect(await store.readIfMatchesUser('user-B'), isNull);
    expect((await store.readIfMatchesUser('user-A'))?.userId, 'user-A');
  });

  test('corrupt JSON returns null', () async {
    final fake = FakeSecureStorage();
    final store = KeychainDeviceStore(storage: fake);
    await fake.write('not-json');
    expect(await store.read(), isNull);
  });
}
