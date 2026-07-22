import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/phone_identity.dart';

void main() {
  test('ensureKeypair is idempotent for the same bare deviceUuid', () async {
    final id = PhoneIdentity.inMemory();
    final kp1 = await id.ensureKeypair('uuid-bare');
    final kp2 = await id.ensureKeypair('uuid-bare');

    expect(kp1.pubkeyB64, equals(kp2.pubkeyB64));
    expect(kp1.privSeed, equals(kp2.privSeed));
  });

  test('distinct bare deviceUuids yield distinct keypairs', () async {
    final id = PhoneIdentity.inMemory();
    final a = await id.ensureKeypair('uuid-a');
    final b = await id.ensureKeypair('uuid-b');

    expect(a.pubkeyB64, isNot(equals(b.pubkeyB64)));
  });

  test('secure storage key uses the BARE deviceUuid (no .projectId suffix)',
      () {
    // The trust anchor is the bare deviceUuid; the key must NOT embed a
    // compound `<deviceId>.<projectId>` id.
    expect(
      PhoneIdentity.privStorageKey('uuid-bare'),
      equals('antgrid.phone_priv.uuid-bare'),
    );
    expect(
      PhoneIdentity.pubStorageKey('uuid-bare'),
      equals('antgrid.phone_pub.uuid-bare'),
    );
    expect(PhoneIdentity.privStorageKey('uuid-bare'), isNot(contains('.proj')));
  });
}
