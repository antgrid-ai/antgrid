import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:antgrid/services/keychain_device_store.dart';

/// In-memory [DeviceSecretStorage] backed by a simple nullable string field.
/// Suitable for unit tests that need a [KeychainDeviceStore] without the
/// platform secure-storage dependency.
class InMemoryDeviceSecretStorage implements DeviceSecretStorage {
  InMemoryDeviceSecretStorage(this._value);
  String? _value;

  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String v) async => _value = v;
  @override
  Future<void> delete() async => _value = null;
}

/// Builds a [KeychainDeviceStore] pre-seeded with the given [record].
///
/// Each test provides the exact [DeviceRecord] it needs — including the
/// membership test which uses a real keypair so its produced signature verifies.
KeychainDeviceStore fakeDeviceStoreFromRecord(DeviceRecord record) {
  return KeychainDeviceStore(
    storage: InMemoryDeviceSecretStorage(jsonEncode(record.toJson())),
  );
}

/// Convenience: builds a [KeychainDeviceStore] from a real Ed25519 keypair
/// derived from [seed] (a 32-byte list).  Stores both the raw seed (as
/// [DeviceRecord.ed25519Priv]) and the public key (as [DeviceRecord.ed25519Pub])
/// so that the service can sign account-membership proofs and callers can
/// verify them.
Future<KeychainDeviceStore> fakeDeviceStoreFromSeed(
  List<int> seed, {
  String userId = 'user-1',
  String deviceUuid = 'account-device-1',
  String clientId = 'client-1',
  String clientSecret = 'secret-1',
}) async {
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  final rec = DeviceRecord(
    userId: userId,
    deviceUuid: deviceUuid,
    clientId: clientId,
    clientSecret: clientSecret,
    ed25519Pub: base64Encode(pub.bytes),
    ed25519Priv: base64Encode(seed),
    x25519Pub: base64Encode(Uint8List(32)),
    x25519Priv: base64Encode(Uint8List(32)),
  );
  return fakeDeviceStoreFromRecord(rec);
}

/// The canonical test seed used by most tests: `(i * 5 + 1) % 256` for
/// i in [0, 32).  Produces a stable, deterministic keypair.
Future<KeychainDeviceStore> fakeDeviceStore() async {
  final seed = List<int>.generate(32, (i) => (i * 5 + 1) % 256);
  return fakeDeviceStoreFromSeed(seed);
}
