// Disposing while a dial is in flight must stay silent.
//
// `connect()` deliberately does not await `_doConnect`, so the attempt outlives
// the service: dispose() closes the controllers, then the still-running dial
// fails (unreachable host, or a `channel.ready` rejected by the sink dispose
// just closed) and emits its `disconnected` state onto a closed controller.
// `Bad state: Cannot add new events after calling close` is thrown inside an
// unawaited future — nothing can catch it, and under `flutter test` it lands as
// a "failed after test completion" on whatever test happened to be running.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(32),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

void main() {
  test(
    'dispose() during an in-flight dial does not throw when the dial fails',
    () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final relay = RelayService(crypto: CryptoService());
        // Unroutable host, so the dial is guaranteed to still be resolving when
        // dispose lands and to fail some time after it.
        final dial = relay.connect(
          'ws://relay.invalid.test:9',
          _identity(),
          licenseToken: 'tok',
          epoch: 1,
        );
        dial.ignore();
        relay.dispose();
        // Long enough for the DNS failure to surface into `_doConnect`'s catch.
        await Future<void>.delayed(const Duration(seconds: 2));
      }, (e, _) => errors.add(e));

      expect(
        errors,
        isEmpty,
        reason: 'a post-dispose dial failure must be inert',
      );
    },
  );

  test('currentState still tracks the failure after dispose', () {
    final relay = RelayService(crypto: CryptoService());
    relay.dispose();

    // Dropping the notification must not freeze the snapshot readers poll.
    expect(
      relay.currentState.connectionState,
      RelayConnectionState.disconnected,
    );
  });
}
