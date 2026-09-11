// `StreamTransport.request`'s `countsTowardHealth` flag, and what it does to
// `MachineSession`'s consecutive-timeout rekey trigger.
//
// A caller that re-issues the SAME pull on every re-establishment —
// including the one a rekey itself causes — must be able to opt its own
// timeouts out of the trigger, or a run of timeouts on a link that cannot
// carry the pull forces a rekey, the rekey re-establishes, the
// re-establish re-drives the same pull, and the loop never breaks (see
// `AgentTransport.request`'s doc comment, and `TerminalService`'s use of it
// for `terminal.snapshot`).

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  test(
    'countsTowardHealth: false timeouts never advance the rekey counter',
    () async {
      final relay = FakeLiveRelay();
      final handshaker = FakeHandshaker.sequence([fixedKeys(1), fixedKeys(2)]);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ensureEstablished();
      expect(handshaker.performCalls, 1);

      final control = session.streamFor(kControlStreamId);
      // Three consecutive timeouts is the rekey trigger — none of these count,
      // so running past it must still leave the session on its first handshake.
      for (var i = 0; i < 4; i++) {
        await expectLater(
          control.request(
            'terminal.snapshot',
            timeout: const Duration(milliseconds: 10),
            countsTowardHealth: false,
          ),
          throwsA(isA<RpcException>()),
        );
      }

      // Give a wrongly-triggered rekey room to start before asserting it didn't.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        handshaker.performCalls,
        1,
        reason: 'a timeout that does not count toward health must not rekey',
      );
      expect(session.isEstablished, isTrue);

      await session.dispose();
      await relay.closeStreams();
    },
  );

  test(
    'countsTowardHealth: true (the default) still triggers a rekey after '
    'three consecutive timeouts',
    () async {
      final relay = FakeLiveRelay();
      final handshaker = FakeHandshaker.sequence([fixedKeys(1), fixedKeys(2)]);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ensureEstablished();
      expect(handshaker.performCalls, 1);

      final control = session.streamFor(kControlStreamId);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          control.request(
            'config:read',
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(isA<RpcException>()),
        );
      }

      for (var i = 0; i < 50 && handshaker.performCalls < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        handshaker.performCalls,
        2,
        reason: 'three consecutive counted timeouts must still trigger a rekey',
      );

      await session.dispose();
      await relay.closeStreams();
    },
  );
}
