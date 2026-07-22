import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

/// Regression guard for the reconnect-backoff overflow.
///
/// The delay used to be `1000 * (1 << attempt)` against an unbounded attempt
/// counter. Dart VM ints wrap at 64 bits, so around attempt 54 (~27min of
/// outage at the 30s cap) the product turned negative, the `> 30000` ceiling
/// stopped matching, and `Timer` fired immediately — pinning the phone in a
/// tight reconnect loop it could never leave.
void main() {
  group('RelayService reconnect backoff', () {
    late RelayService relay;

    setUp(() => relay = RelayService(crypto: CryptoService()));

    test(
      'stays in [500ms, 30s] for every attempt, well past the old overflow',
      () {
        for (var attempt = 0; attempt <= 200; attempt++) {
          final ms = relay.debugBackoffMs(attempt);
          expect(ms, inInclusiveRange(500, 30000), reason: 'attempt $attempt');
        }
      },
    );

    test('grows toward the cap and holds there', () {
      expect(relay.debugBackoffMs(0), inInclusiveRange(500, 1000));
      expect(relay.debugBackoffMs(2), inInclusiveRange(2000, 4000));
      expect(relay.debugBackoffMs(5), inInclusiveRange(15000, 30000));
      expect(relay.debugBackoffMs(60), inInclusiveRange(15000, 30000));
    });

    test('treats a negative attempt as the first one, rather than throwing', () {
      // `1 << negative` is an ArgumentError in Dart, not a wrap. No production
      // caller can get here (the attempt counter starts at 0 and only grows),
      // but debugBackoffMs is public, so the seam should not have a sharp edge.
      expect(relay.debugBackoffMs(-1), inInclusiveRange(500, 1000));
    });

    test('jitters, so clients sharing a relay restart do not sync up', () {
      final samples = {for (var i = 0; i < 50; i++) relay.debugBackoffMs(5)};
      expect(samples.length, greaterThan(1));
    });
  });
}
