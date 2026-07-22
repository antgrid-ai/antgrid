// MachineSession key-lifecycle coverage: nothing dispatches before the first
// handshake establishes, rekey swaps to fresh keys with a make-before-break
// handover (old keys keep decrypting until the new ones are confirmed) and
// zeroizes the superseded key material, and a peer-online-after-offline
// transition triggers a rekey. Replaces the deleted relay_transport_test.dart
// cases that exercised `RelayTransport.updateAgent` (send/receive silently
// gated on key presence, keys hot-swapped) — that hot-swap now lives in
// MachineSession's `_runHandshake`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_paired_relay.dart';

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

bool _isZeroized(SessionKeys keys) {
  bool allZero(Uint8List b) => b.every((x) => x == 0);
  return allZero(keys.a2p) && allZero(keys.p2a) && allZero(keys.confirm);
}

void main() {
  group('no app traffic before the first handshake establishes', () {
    test('sendOnStream is a silent no-op while keys are unset', () async {
      final relay = FakePairedRelay(
          initial: RelayConnectionState.authenticated); // NOT yet paired
      final handshaker = FakeHandshaker(fixedKeys(1));
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      // Not paired yet → start() must not have kicked off the handshake.
      expect(handshaker.performCalls, 0);

      await session.sendOnStream('proj-1', {'type': 'ping'}, 'control');
      expect(relay.sent, isEmpty,
          reason: 'no keys installed yet — the send must be dropped, not '
              'queued or sent in the clear');

      await session.dispose();
      await relay.closeStreams();
    });

    test('an inbound sealed frame arriving before establishment is dropped '
        '(pre-key traffic is never dispatched)', () async {
      final relay = FakePairedRelay();
      // A handshaker that never resolves during this test's window — models
      // "handshake still in flight".
      final handshaker = FakeHandshaker(fixedKeys(1))
        ..delayFor = (_) => const Duration(milliseconds: 500);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();

      final control = session.streamFor(kControlStreamId);
      final seen = <Map<String, dynamic>>[];
      final sub = control.messages.listen((m) => seen.add(m.json));

      // Seal under keys the session doesn't have yet (arbitrary keys) —
      // MachineSession has no `_keys` installed, so `_onRouted` must drop
      // this on the floor without even attempting a decrypt.
      relay.inject(IncomingRouteMessage(
        from: 'm1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(
            fixedKeys(1), jsonEncode({'m': {'type': 'agent:projects'}})),
      ));

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen, isEmpty);

      await sub.cancel();
      await session.dispose();
      await relay.closeStreams();
    });
  });

  group('rekey', () {
    test('a peer-online after peer-offline triggers a fresh handshake '
        'attempt (rekey)', () async {
      final relay = FakePairedRelay();
      final handshaker =
          FakeHandshaker.sequence([fixedKeys(1), fixedKeys(2)]);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ready;
      expect(handshaker.performCalls, 1);

      relay.presence(false);
      relay.presence(true);

      // Rekey runs the handshaker again on the SAME (live) socket.
      for (var i = 0; i < 50 && handshaker.performCalls < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(handshaker.performCalls, 2);

      await session.dispose();
      await relay.closeStreams();
    });

    test(
      'make-before-break: the OLD keys keep decrypting live traffic while a '
      'rekey is in flight, and are zeroized only after the new keys swap in',
      () async {
        final relay = FakePairedRelay();
        final oldKeys = fixedKeys(1);
        final newKeys = fixedKeys(9);
        final handshaker = FakeHandshaker.sequence([oldKeys, newKeys])
          ..delayFor = (i) =>
              i == 1 ? const Duration(milliseconds: 150) : Duration.zero;
        final session = MachineSession(
          relay: relay,
          machineDeviceId: 'm1',
          handshaker: handshaker,
        );
        session.start();
        await session.ready;
        expect(handshaker.performCalls, 1);
        // The FakeHandshaker returns the SAME SessionKeys instance each call
        // (no cloning), so oldKeys is exactly what MachineSession zeroizes.
        expect(_isZeroized(oldKeys), isFalse);

        final control = session.streamFor(kControlStreamId);
        final seen = <Map<String, dynamic>>[];
        final sub = control.messages.listen((m) => seen.add(m.json));

        // Trigger the rekey (peer bounce) — the new handshake attempt takes
        // 150ms per delayFor above, so there is a real in-flight window.
        relay.presence(false);
        relay.presence(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(handshaker.performCalls, 2,
            reason: 'the rekey attempt must already be running');

        // While the new handshake is still in flight, traffic sealed under
        // the OLD keys must still decrypt and dispatch.
        relay.inject(IncomingRouteMessage(
          from: 'm1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(
              oldKeys, jsonEncode({'m': {'type': 'still-old-keys'}})),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(seen.map((j) => j['type']), contains('still-old-keys'),
            reason: 'old keys must remain live until the new confirm lands '
                '(make-before-break)');
        expect(_isZeroized(oldKeys), isFalse,
            reason: 'not swapped out yet — still mid-handshake');

        // Let the rekey finish.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(_isZeroized(oldKeys), isTrue,
            reason: 'the superseded key set is zeroized once the new one '
                'is confirmed');

        // New traffic must now be sealed under the NEW keys — the old ones
        // no longer decrypt anything (they're zero bytes).
        seen.clear();
        relay.inject(IncomingRouteMessage(
          from: 'm1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(
              newKeys, jsonEncode({'m': {'type': 'new-keys'}})),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(seen.map((j) => j['type']), ['new-keys']);

        await sub.cancel();
        await session.dispose();
        await relay.closeStreams();
      },
    );
  });
}
