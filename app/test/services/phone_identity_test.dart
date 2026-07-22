import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/phone_identity.dart';

void main() {
  test('inMemory ensureKeypair returns stable per-agent keypair', () async {
    final id = PhoneIdentity.inMemory();
    final kp1 = await id.ensureKeypair('agent-1');
    final kp2 = await id.ensureKeypair('agent-1');
    final kp3 = await id.ensureKeypair('agent-2');

    expect(kp1.pubkeyB64.length, greaterThan(40));
    expect(kp1.pubkeyB64, equals(kp2.pubkeyB64));
    expect(kp1.pubkeyB64, isNot(equals(kp3.pubkeyB64)));
  });

  test('deleteKeypair regenerates only that machine keypair', () async {
    final id = PhoneIdentity.inMemory();
    final a1 = await id.ensureKeypair('agent-1');
    final b1 = await id.ensureKeypair('agent-2');

    await id.deleteKeypair('agent-1');

    final a2 = await id.ensureKeypair('agent-1');
    final b2 = await id.ensureKeypair('agent-2');
    expect(a2.pubkeyB64, isNot(equals(a1.pubkeyB64)));
    expect(b2.pubkeyB64, equals(b1.pubkeyB64));
  });
}
