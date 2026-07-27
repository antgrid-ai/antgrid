// Task 9 cutover coverage for MachineSession's handshake ownership.
//
// The E2E handshake is no longer triggered by a `paired` socket transition —
// pairing is gone. The connection supervisor drives it explicitly via
// [MachineSession.ensureEstablished], which is a SINGLE attempt (the supervisor
// owns retry) and must never resolve ahead of [MachineSession.isEstablished].
// A sealed `session-takeover` is reported, not repaired.
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

void main() {
  group('handshake trigger', () {
    test(
      'no socket state drives a handshake; ensureEstablished does',
      () async {
        final relay = FakeLiveRelay(
          initial: RelayConnectionState.connecting,
        );
        final handshaker = FakeHandshaker(fixedKeys(1));
        final session = MachineSession(
          relay: relay,
          machineDeviceId: 'm1',
          handshaker: handshaker,
        );
        session.start();

        // Climbing the socket all the way to `authenticated` (the terminal
        // socket state) must still be inert — an agent's presence is what the
        // supervisor climbs on, and it calls ensureEstablished().
        relay.setState(
          const AppState(connectionState: RelayConnectionState.authenticated),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          handshaker.performCalls,
          0,
          reason: 'socket state must not trigger the E2E handshake',
        );

        await session.ensureEstablished();
        expect(session.isEstablished, isTrue);
        expect(handshaker.performCalls, 1);

        await session.dispose();
        await relay.closeStreams();
      },
    );

    test(
      'ensureEstablished is a no-op on an already-established session',
      () async {
        final relay = FakeLiveRelay(
          initial: RelayConnectionState.authenticated,
        );
        final handshaker = FakeHandshaker.sequence([
          fixedKeys(1),
          fixedKeys(2),
        ]);
        final session = MachineSession(
          relay: relay,
          machineDeviceId: 'm1',
          handshaker: handshaker,
        );
        session.start();
        await session.ensureEstablished();
        await session.ensureEstablished();
        expect(handshaker.performCalls, 1);

        await session.dispose();
        await relay.closeStreams();
      },
    );

    test('ensureEstablished re-establishes after a teardown and only resolves '
        'once isEstablished reads true', () async {
      final relay = FakeLiveRelay(
        initial: RelayConnectionState.authenticated,
      );
      final handshaker = FakeHandshaker.sequence([fixedKeys(1), fixedKeys(2)])
        ..delayFor = (i) =>
            i == 1 ? const Duration(milliseconds: 150) : Duration.zero;
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ensureEstablished();
      expect(session.isEstablished, isTrue);
      // `ready` is one-shot: it is already complete here, so awaiting it on
      // the re-establishment below would resolve instantly with the session
      // down — the trap ensureEstablished exists to avoid.
      await session.ready;

      relay.setState(
        const AppState(connectionState: RelayConnectionState.disconnected),
      );
      // The state stream is a broadcast controller — delivery is async.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.isEstablished, isFalse);

      final startedAt = DateTime.now();
      await session.ensureEstablished();
      final waited = DateTime.now().difference(startedAt).inMilliseconds;

      expect(
        session.isEstablished,
        isTrue,
        reason: 'must not resolve before the NEW establishment lands',
      );
      expect(
        waited,
        greaterThanOrEqualTo(100),
        reason: 'it waited out the in-flight 150ms attempt, not a stale ready',
      );
      expect(handshaker.performCalls, 2);

      await session.dispose();
      await relay.closeStreams();
    });

    test('a failed handshake is exactly ONE attempt and throws', () async {
      final relay = FakeLiveRelay(
        initial: RelayConnectionState.authenticated,
      );
      // A handshaker that never confirms — the peer is there but the attempt
      // fails. The supervisor owns retry, so the session must not loop.
      final handshaker = FakeHandshaker.sequence(<SessionKeys?>[null]);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();

      await expectLater(
        session.ensureEstablished(),
        throwsA(isA<HandshakeException>()),
      );
      expect(
        handshaker.performCalls,
        1,
        reason: 'no inner retry loop — the supervisor backs off and re-calls',
      );
      expect(session.isEstablished, isFalse);

      await session.dispose();
      await relay.closeStreams();
    });

    test('concurrent ensureEstablished calls share one attempt', () async {
      final relay = FakeLiveRelay(
        initial: RelayConnectionState.authenticated,
      );
      final handshaker = FakeHandshaker.sequence([fixedKeys(1), fixedKeys(2)])
        ..delayFor = (_) => const Duration(milliseconds: 60);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();

      await Future.wait([
        session.ensureEstablished(),
        session.ensureEstablished(),
      ]);
      expect(handshaker.performCalls, 1);
      expect(session.isEstablished, isTrue);

      await session.dispose();
      await relay.closeStreams();
    });
  });

  group('session-takeover', () {
    test(
      'tears the session down, reports on takeoverEvents, and never rekeys',
      () async {
        final relay = FakeLiveRelay(
          initial: RelayConnectionState.authenticated,
        );
        final keys = fixedKeys(1);
        final handshaker = FakeHandshaker.sequence([keys, fixedKeys(2)]);
        final session = MachineSession(
          relay: relay,
          machineDeviceId: 'm1',
          handshaker: handshaker,
        );
        session.start();
        await session.ensureEstablished();
        expect(handshaker.performCalls, 1);

        final takeovers = <void>[];
        final sub = session.takeoverEvents.listen(takeovers.add);

        relay.inject(
          IncomingRouteMessage(
            from: 'm1',
            channel: 'control',
            kind: FrameKind.sealed,
            payload: await _sealFromAgent(
              keys,
              jsonEncode({'type': 'session-takeover'}),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(takeovers, hasLength(1));
        expect(
          session.isEstablished,
          isFalse,
          reason: 'the agent handed the session to another device',
        );

        // Every rekey trigger must stay silent: reclaiming the session would
        // make the two devices evict each other forever.
        relay.presence(false);
        relay.presence(true);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          handshaker.performCalls,
          1,
          reason: 'a takeover is reported, never auto-repaired',
        );

        await sub.cancel();
        await session.dispose();
        await relay.closeStreams();
      },
    );
  });
}
