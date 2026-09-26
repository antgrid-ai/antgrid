// MachineSession session-lifecycle coverage: nothing dispatches before the
// first hello establishes, and a session with no application-layer key to
// rotate cannot repair itself in place — every "this session is dead"
// trigger (missed liveness pongs, a failed hello) closes the whole link
// instead, and the supervisor (outside this package) redials. RPC-timeout
// accounting is per PROJECT STREAM now, not session-wide — see
// `machine_session_rpc_health_test.dart`.
import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  group('no app traffic before the first handshake establishes', () {
    test('sendOnSession is a silent no-op before the hello confirms', () async {
      final relay = FakeLiveRelay(
        initial: RelayConnectionState.authenticated,
      ); // NOT yet established
      final handshaker = FakeHandshaker();
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      // start() never handshakes — the supervisor calls ensureEstablished().
      expect(handshaker.performCalls, 0);

      await session.sendOnSession({'type': 'ping'}, 'control');
      expect(
        relay.sent,
        isEmpty,
        reason:
            'not established yet — the send must be dropped, not '
            'queued or sent early',
      );

      await session.dispose();
      await relay.closeStreams();
    });

    test('an inbound frame arriving before establishment is dropped '
        '(pre-establishment traffic is never dispatched)', () async {
      final relay = FakeLiveRelay();
      // A handshaker that never resolves during this test's window — models
      // "hello still in flight".
      final handshaker = FakeHandshaker()
        ..delayFor = (_) => const Duration(milliseconds: 500);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      // Handshake genuinely in flight (the 500ms attempt has not confirmed).
      final establishing = session.ensureEstablished();

      final control = session.control;
      final seen = <Map<String, dynamic>>[];
      final sub = control.messages.listen((m) => seen.add(m.json));

      // MachineSession has no session installed yet — `_onPeerFrame` must
      // drop this on the floor without attempting to dispatch it.
      relay.injectFrame(
        encodeFromAgent(jsonEncode({'type': 'agent:projects'})),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen, isEmpty);

      await sub.cancel();
      await establishing;
      await session.dispose();
      await relay.closeStreams();
    });
  });

  // Replaces the former "grant revocation" case. Trust is account-derived now:
  // there is no grant, so a paired→authenticated transition carries no meaning
  // and tearing the session down on it would drop a perfectly good session
  // (and every live project stream) for nothing. Only the SOCKET dying
  // invalidates a per-connection session.
  group('non-disconnect state churn', () {
    test('an established session survives a state transition that is not a '
        'disconnect', () async {
      final relay = FakeLiveRelay();
      final handshaker = FakeHandshaker.sequence([true, true]);
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ensureEstablished();
      expect(session.isEstablished, isTrue);

      relay.setState(
        const AppState(connectionState: RelayConnectionState.authenticated),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        session.isEstablished,
        isTrue,
        reason: 'a session is per-connection; the socket never went down',
      );
      expect(handshaker.performCalls, 1, reason: 'nothing to re-handshake');

      await session.dispose();
      await relay.closeStreams();
    });
  });

  group('session teardown fails in-flight RPCs', () {
    test(
      'G1: a control-plane send chained behind a pending write is dropped, '
      'not written, when the session generation changes before its turn',
      () async {
        final relay = FakeLiveRelay();
        final session = await establishSession(relay, handshaker: FakeHandshaker());

        // Holds the first write's own `sendFrame` in flight so the second one
        // is still queued behind it (on `_sessionSendChain`) when the
        // generation changes underneath both of them.
        final gate = Completer<void>();
        relay.sendGate = gate;
        final first = session.sendOnSession({'type': 'ping'}, 'control');
        final second = session.sendOnSession({
          'type': 'terminal:input',
          'data': 'must-not-send',
        }, 'control');

        // A takeover tears the session down (nulling its generation) without
        // touching `relay.isDispatchAllowed` — the socket stays up, only the
        // session does not, which is what isolates the generation fence from
        // the separate `isDispatchAllowed` gate.
        relay.injectFrame(
          encodeFromAgent(jsonEncode({'type': 'session-takeover'})),
          kind: kPeerFrameSession,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        gate.complete();
        await first;
        await second;

        final sentTypes = relay.sent
            .map((f) => jsonDecode(decodeFromPhone(f.payload))['type'])
            .toList();
        expect(
          sentTypes,
          contains('ping'),
          reason: 'the first write had already passed its generation check',
        );
        expect(
          sentTypes,
          isNot(contains('terminal:input')),
          reason: 'its turn on the chain came after the generation changed',
        );

        await session.dispose();
        await relay.closeStreams();
      },
    );

    test(
      'G2: sendOnSession over kStreamProjectAppRecordMaxBytes drops '
      'message-too-large, writes nothing, and emits one MessageTooLarge',
      () async {
        final relay = FakeLiveRelay();
        final session = await establishSession(relay, handshaker: FakeHandshaker());

        final tooLarge = <MessageTooLarge>[];
        final sub = session.messageTooLarge.listen(tooLarge.add);
        final blob = 'a' * (kStreamProjectAppRecordMaxBytes + 1);
        await session.sendOnSession({
          'type': 'config:write',
          'body': blob,
        }, 'control');

        expect(relay.sent, isEmpty);
        expect(tooLarge, hasLength(1));
        expect(tooLarge.single.type, 'config:write');

        await sub.cancel();
        await session.dispose();
        await relay.closeStreams();
      },
    );

    test('a socket-down fails per-stream pending RPCs fast (no full-timeout '
        'hang)', () async {
      final relay = FakeLiveRelay();
      final handshaker = FakeHandshaker();
      final session = MachineSession(
        relay: relay,
        machineDeviceId: 'm1',
        handshaker: handshaker,
      );
      session.start();
      await session.ensureEstablished();

      final control = session.control;
      // In-flight RPC: sent, now awaiting a reply that will never come because
      // the socket drops. Give it a long timeout so a fail-SLOW implementation
      // would visibly hang past this test's patience.
      final pending = control.request(
        'config:read',
        timeout: const Duration(seconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      relay.setState(
        const AppState(connectionState: RelayConnectionState.disconnected),
      );

      Object? caught;
      try {
        await pending.timeout(const Duration(seconds: 2));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<RpcException>());
      expect(
        (caught as RpcException).code,
        'E_SESSION_DOWN',
        reason:
            'the drop fails the RPC fast with a session-down reason, '
            'not by eventually timing out (E_TIMEOUT)',
      );

      await session.dispose();
      await relay.closeStreams();
    });
  });

  group('closing the link on failure', () {
    test('a stalled session stream closes the link', () async {
      final relay = FakeLiveRelay();
      final session = await establishSession(
        relay,
        handshaker: FakeHandshaker(),
        pingSilence: const Duration(milliseconds: 30),
      );

      // The fake relay never answers a ping, so silence never resets.
      for (var i = 0; i < 50 && !relay.closeCalled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(relay.closeCalled, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.isEstablished, isFalse);

      await session.dispose();
      await relay.closeStreams();
    });

    test(
      'a wedged bridge is declared dead by the ping while project records '
      'keep flowing',
      () async {
        // A bridge whose event loop is stuck can still have a QUIC stack that
        // acks (and, on a stream it already had open, a backlog that keeps
        // draining) — only the app's own wedge-probe ping notices, never a
        // project stream staying busy.
        final relay = FakeLiveRelay();
        final session = await establishSession(
          relay,
          handshaker: FakeHandshaker(),
          pingSilence: const Duration(milliseconds: 30),
          projectStartMessageBuilder: (pid) => {
            'type': 'project:start',
            'projectId': pid,
          },
        );

        // Session pongs keep the ping quiet while the project binds, so the
        // close below can only come from the silence that follows.
        final setupPongs = Timer.periodic(const Duration(milliseconds: 5), (_) {
          relay.injectFrame(
            encodeFromAgent(jsonEncode({'type': 'pong'})),
            kind: kPeerFrameSession,
          );
        });
        relay.injectFrame(
          encodeFromAgent(
            jsonEncode({'type': 'stream-ready', 'projectId': 'X'}),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final opening = session.openProject('X', {
          'type': 'project:start',
          'projectId': 'X',
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final streamX = relay.openedStreams.firstWhere(
          (s) => s.open == const ProjectStreamOpen('X'),
        );
        streamX.injectStreamReady('X');
        await opening;
        expect(relay.closeCalled, isFalse);

        final feed = Timer.periodic(const Duration(milliseconds: 10), (_) {
          streamX.injectJson({
            'type': 'agent:status',
            'checkoutId': 'main',
            'terminals': <Object?>[],
          });
        });

        setupPongs.cancel();

        for (var i = 0; i < 50 && !relay.closeCalled; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        feed.cancel();
        expect(
          relay.closeCalled,
          isTrue,
          reason: 'project records must never refresh the session-stream '
              'liveness clock',
        );

        await session.dispose();
        await relay.closeStreams();
      },
    );
  });
}
