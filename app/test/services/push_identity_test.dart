import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/push_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ensureKeypair is idempotent and returns a 32-byte X25519 key',
    () async {
      final id = PushIdentity.inMemory();
      final k1 = await id.ensureKeypair();
      final k2 = await id.ensureKeypair();
      expect(k1.pubkeyB64, k2.pubkeyB64);
      expect(k1.privSeed, k2.privSeed);
      expect(k1.privSeed.length, 32);
    },
  );

  test('clear forces a new keypair', () async {
    final id = PushIdentity.inMemory();
    final k1 = await id.ensureKeypair();
    await id.clear();
    final k2 = await id.ensureKeypair();
    expect(k1.pubkeyB64, isNot(k2.pubkeyB64));
  });

  test('concurrent ensureKeypair calls collapse to one keypair', () async {
    final id = PushIdentity.inMemory();
    // Fire both before awaiting either: without single-flight both read "no
    // key", both generate, and one overwrites the other.
    final results = await Future.wait([id.ensureKeypair(), id.ensureKeypair()]);
    expect(results[0].pubkeyB64, results[1].pubkeyB64);
    expect(results[0].privSeed, results[1].privSeed);
  });
}
