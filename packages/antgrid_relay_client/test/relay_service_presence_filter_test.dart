// The relay fans `peer-online`/`peer-offline` out ACCOUNT-WIDE (all of a
// user's machines — `presencePeers` in `relay/src/server.ts`), not just the
// one this socket serves. These tests cover the resulting filter: only
// presence frames for THIS socket's machine may drive its state. Uses
// `debugHandleFrame`/`debugSetMachineDeviceId` (the test-only seams documented
// on RelayService), mirroring the no-socket style of
// relay_service_hello_test.dart.
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  group('RelayService — presence frames filtered by machine deviceId', () {
    test('a peer-offline for a different machine is ignored', () async {
      final relay = RelayService(crypto: CryptoService())
        ..debugSetMachineDeviceId('this-machine');

      final presenceEvents = <bool>[];
      relay.peerPresenceStream.listen(presenceEvents.add);

      relay.debugHandleFrame(
        jsonEncode({'type': 'peer-offline', 'peerId': 'other-machine'}),
      );
      // peerPresenceStream is a broadcast StreamController (async delivery);
      // flush the microtask queue before asserting nothing arrived.
      await Future<void>.delayed(Duration.zero);

      expect(presenceEvents, isEmpty);
      expect(relay.currentState.error, isNull);
    });

    test('a peer-offline for THIS machine still flips presence/error',
        () async {
      final relay = RelayService(crypto: CryptoService())
        ..debugSetMachineDeviceId('this-machine');

      final presenceEvents = <bool>[];
      relay.peerPresenceStream.listen(presenceEvents.add);

      relay.debugHandleFrame(
        jsonEncode({'type': 'peer-offline', 'peerId': 'this-machine'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(presenceEvents, [false]);
      expect(relay.currentState.error, 'Peer offline');
    });

    test('a peer-online for a different machine is ignored', () async {
      final relay = RelayService(crypto: CryptoService())
        ..debugSetMachineDeviceId('this-machine');

      final presenceEvents = <bool>[];
      relay.peerPresenceStream.listen(presenceEvents.add);

      relay.debugHandleFrame(
        jsonEncode({'type': 'peer-online', 'peerId': 'other-machine'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(presenceEvents, isEmpty);
      expect(relay.currentState.connectionState,
          RelayConnectionState.disconnected);
    });

    test('a peer-online for THIS machine flips presence — and ONLY presence',
        () async {
      final relay = RelayService(crypto: CryptoService())
        ..debugSetMachineDeviceId('this-machine');

      final presenceEvents = <bool>[];
      relay.peerPresenceStream.listen(presenceEvents.add);

      relay.debugHandleFrame(
        jsonEncode({'type': 'peer-online', 'peerId': 'this-machine'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(presenceEvents, [true]);
      // Agent presence is not a socket phase: the connection state tracks OUR
      // socket only, and a peer showing up must not promote it.
      expect(relay.currentState.connectionState,
          RelayConnectionState.disconnected);
    });

    test(
        'no machineDeviceId set: presence is ignored (fail closed) — '
        'an unset filter never flips this socket state', () async {
      final relay = RelayService(crypto: CryptoService());

      final presenceEvents = <bool>[];
      relay.peerPresenceStream.listen(presenceEvents.add);

      relay.debugHandleFrame(
        jsonEncode({'type': 'peer-offline', 'peerId': 'anything'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(presenceEvents, isEmpty);
      expect(relay.currentState.error, isNull);
    });
  });
}
