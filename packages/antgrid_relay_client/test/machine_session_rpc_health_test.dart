// `StreamTransport.request`'s `countsTowardHealth` flag, and what it does to
// `MachineSession`'s consecutive-timeout link-close trigger.
//
// A caller that re-issues the SAME pull on every re-establishment —
// including the one closing the link itself causes — must be able to opt its
// own timeouts out of the trigger, or a run of timeouts on a link that cannot
// carry the pull closes the link, the supervisor redials, the redial
// re-drives the same pull, and the loop never breaks (see
// `AgentTransport.request`'s doc comment, and `TerminalService`'s use of it
// for `terminal.snapshot`).

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  test(
    'countsTowardHealth: false timeouts never advance the close-trigger '
    'counter',
    () async {
      final relay = FakeLiveRelay();
      final handshaker = FakeHandshaker();
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ensureEstablished();
      expect(handshaker.performCalls, 1);

      final control = session.streamFor(kControlStreamId);
      // Three consecutive timeouts is the close trigger — none of these count,
      // so running past it must still leave the link open.
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

      // Give a wrongly-triggered close room to happen before asserting it
      // didn't.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        relay.closeCalled,
        isFalse,
        reason: 'a timeout that does not count toward health must not close '
            'the link',
      );
      expect(session.isEstablished, isTrue);

      await session.dispose();
      await relay.closeStreams();
    },
  );

  test(
    'countsTowardHealth: true (the default) still closes the link after '
    'three consecutive timeouts',
    () async {
      final relay = FakeLiveRelay();
      final handshaker = FakeHandshaker();
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

      for (var i = 0; i < 50 && !relay.closeCalled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        relay.closeCalled,
        isTrue,
        reason: 'three consecutive counted timeouts must still close the link',
      );
      expect(
        handshaker.performCalls,
        1,
        reason: 'no in-place repair — the supervisor owns the redial',
      );

      await session.dispose();
      await relay.closeStreams();
    },
  );
}
