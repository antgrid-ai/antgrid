// Project readiness coverage: a reconnecting phone must be able to learn a
// project is dialable from PULLED state (the `state.snapshot` reply), not
// only from live `stream-ready` / `agent:projects` pushes — the bridge's
// replay-cache dedup can legally suppress a byte-identical re-advert after an
// app kill+reopen, so the live push is best-effort and the snapshot is the
// reconnect contract.
//
// Since Stage A A4 a project's native stream identity IS the project
// (`StreamTransport.projectId`, fixed for its lifetime) — there is no more
// bridge-issued streamId to migrate on a host restart, so the old
// `stream-invalid` self-heal and "re-advert under a NEW streamId re-points
// the live transport" groups have no A4 equivalent and are gone. What
// survives is readiness itself: `openProject` must resolve from a ready
// notice seen live OR replayed from a snapshot, and a rejected `project:start`
// must fail the pending open with the agent's own reason.
import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  late FakeLiveRelay relay;
  late FakeHandshaker handshaker;
  late MachineSession session;

  setUp(() async {
    relay = FakeLiveRelay();
    handshaker = FakeHandshaker();
    session = await establishSession(relay, handshaker: handshaker);
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  /// Every control-plane message sent so far, decoded. There is no envelope
  /// any more — a session-stream record with the `message` kind is exactly
  /// one bare `AbMessage` (§1.1).
  Future<List<Map<String, dynamic>>> sentEnvelopes() async {
    final out = <Map<String, dynamic>>[];
    for (final f in relay.sent) {
      if (f.kind != kPeerFrameMessage) continue;
      out.add(jsonDecode(decodeFromPhone(f.payload)) as Map<String, dynamic>);
    }
    return out;
  }

  /// The requestId of the first control-plane `state.snapshot` RPC sent.
  Future<String?> snapshotRequestId() async {
    for (final m in await sentEnvelopes()) {
      if (m['type'] == 'request' && m['method'] == 'state.snapshot') {
        return m['requestId'] as String?;
      }
    }
    return null;
  }

  Future<void> injectControl(Map<String, dynamic> m) async {
    relay.injectFrame(encodeFromAgent(jsonEncode(m)));
  }

  /// Completes `openProject`'s native-stream leg: takes the just-opened
  /// [FakePeerStream] and hands it the bridge's `stream-ready` first record.
  void bindOpenedStream(String projectId) {
    relay.openedStreams.last.injectStreamReady(projectId);
  }

  group('readiness via a live stream-ready', () {
    test('an already-advertised project binds with one native stream open — '
        'no second stream-ready needed on the control plane', () async {
      await injectControl({'type': 'stream-ready', 'projectId': 'proj-z'});
      // Injection only queues the frame; the decrypt/dispatch is async.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sentBefore = relay.sent.length;
      final opening = session.openProject('proj-z', {
        'type': 'project:start',
        'projectId': 'proj-z',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bindOpenedStream('proj-z');
      final transport = await opening;

      expect(transport.projectId, 'proj-z');
      expect(
        (await sentEnvelopes())
            .skip(sentBefore)
            .where((e) => e['type'] == 'project:start'),
        isEmpty,
        reason: 'a known-ready project must not re-ask the agent to start it',
      );
    });

    test(
      'a shared ready-waiter outlives one caller\'s timeout: a concurrent '
      'open of the same project still resolves',
      () async {
        final impatient = session.openProject('proj-e', {
          'type': 'project:start',
          'projectId': 'proj-e',
        }, timeout: const Duration(milliseconds: 100));
        final patient = session.openProject('proj-e', {
          'type': 'project:start',
          'projectId': 'proj-e',
        }, timeout: const Duration(seconds: 2));

        await expectLater(impatient, throwsA(isA<TimeoutException>()));

        await injectControl({'type': 'stream-ready', 'projectId': 'proj-e'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bindOpenedStream('proj-e');

        final transport = await patient;
        expect(
          transport.projectId,
          'proj-e',
          reason:
              'the ready-waiter is shared via putIfAbsent; one caller giving '
              'up must not strand the other',
        );
      },
    );
  });

  group('readiness via agent:projects', () {
    test('an agent:projects advert is the complete dialable catalog: a '
        'project the agent stops listing as running is not ready for a '
        'fresh open — an already-BOUND transport is a separate matter '
        '(its own stream ending is what drives a reopen, not the advert)',
        () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-old', 'running': true},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The agent restarted before the phone ever opened the project: by
      // the time it does, proj-old is no longer running.
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-old', 'running': false},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sentBefore = relay.sent.length;
      final opening = session.openProject('proj-old', {
        'type': 'project:start',
        'projectId': 'proj-old',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        (await sentEnvelopes())
            .skip(sentBefore)
            .where((e) => e['type'] == 'project:start'),
        isNotEmpty,
        reason:
            'a project no longer vouched for by the advert is not ready — '
            'opening it must ask the agent to start it',
      );

      await injectControl({'type': 'stream-ready', 'projectId': 'proj-old'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bindOpenedStream('proj-old');
      final transport = await opening;
      expect(transport.projectId, 'proj-old');
    });
  });

  group('snapshot hydration', () {
    test(
      'a state.snapshot reply carrying agent:projects{running:true} marks '
      'readiness just like a live advert, so a pending openProject resolves',
      () async {
        // Attaching the control transport auto-pulls the snapshot.
        session.control;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final requestId = await snapshotRequestId();
        expect(
          requestId,
          isNotNull,
          reason: 'attaching the control stream must pull state.snapshot',
        );

        // The reconnect scenario: the live re-advert was dedup-suppressed, so
        // the app opens the project directly. Readiness must arrive from the
        // snapshot reply below — the ONLY carrier in this scenario.
        final opening = session.openProject('proj-a', {
          'type': 'project:start',
          'projectId': 'proj-a',
        }, timeout: const Duration(milliseconds: 500));

        await injectControl({
          'type': 'response',
          'requestId': requestId,
          'ok': true,
          'result': {
            'frames': [
              {
                'type': 'agent:projects',
                'projects': [
                  {'projectId': 'proj-a', 'running': true},
                ],
              },
            ],
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bindOpenedStream('proj-a');

        final transport = await opening;
        expect(
          transport.projectId,
          'proj-a',
          reason: 'openProject must resolve from the snapshot-replayed advert',
        );
      },
    );
  });

  group('a rejected project:start fails the pending open', () {
    test('a control:result{ok:false} for a DIFFERENT verb leaves the pending '
        'open alone', () async {
      final opening = session.openProject('proj-f', {
        'type': 'project:start',
        'projectId': 'proj-f',
      }, timeout: const Duration(milliseconds: 400));

      // The bridge echoes `projectId` on EVERY failed control-plane verb,
      // including the UNKNOWN_VERB fallthrough (host-server.ts). Only the
      // project:start rejection says anything about this open.
      await injectControl({
        'type': 'control:result',
        'ok': false,
        'verb': 'sessions.delete',
        'projectId': 'proj-f',
        'error': {'code': 'UNKNOWN_VERB', 'message': 'unsupported verb'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await injectControl({'type': 'stream-ready', 'projectId': 'proj-f'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bindOpenedStream('proj-f');
      final transport = await opening;
      expect(transport.projectId, 'proj-f');
    });

    test('a control:result{ok:false, projectId} fails the pending open with '
        'the agent\'s error code instead of timing out', () async {
      final opening = session.openProject('proj-c', {
        'type': 'project:start',
        'projectId': 'proj-c',
      }, timeout: const Duration(milliseconds: 500));

      await injectControl({
        'type': 'control:result',
        'ok': false,
        'verb': 'project:start',
        'projectId': 'proj-c',
        'error': {'code': 'NOT_ALLOWED', 'message': 'phone not allowlisted'},
      });

      await expectLater(
        opening,
        throwsA(
          isA<ProjectBindException>().having(
            (e) => e.code,
            'code',
            'NOT_ALLOWED',
          ),
        ),
      );
    });
  });

  group('openProject pre-establishment window', () {
    test('an open issued before the session establishes waits for the hello '
        'and resolves once it lands', () async {
      final coldRelay = FakeLiveRelay(
        initial: RelayConnectionState.disconnected,
      );
      final cold = MachineSession(
        relay: coldRelay,
        machineDeviceId: 'machine-3',
        handshaker: FakeHandshaker(),
      );
      cold.start();
      addTearDown(() async {
        await cold.dispose();
        await coldRelay.closeStreams();
      });

      final opening = cold.openProject('proj-d', {
        'type': 'project:start',
        'projectId': 'proj-d',
      }, timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        coldRelay.sent,
        isEmpty,
        reason:
            'project:start must not be sent before establishment — '
            'sendOnSession would drop it silently',
      );

      // The reconnect lands: the supervisor climbs to the established rung and
      // drives the handshake, which completes the session.
      coldRelay.setState(
        const AppState(connectionState: RelayConnectionState.authenticated),
      );
      await cold.ensureEstablished();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      coldRelay.injectFrame(
        encodeFromAgent(
          jsonEncode({'type': 'stream-ready', 'projectId': 'proj-d'}),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      coldRelay.openedStreams.last.injectStreamReady('proj-d');

      final transport = await opening;
      expect(transport.projectId, 'proj-d');
    });

    test('an open that never sees establishment fails with StateError, '
        'bounded by its own timeout (instead of a blind stream-ready '
        'wait)', () async {
      final coldRelay = FakeLiveRelay(
        initial: RelayConnectionState.disconnected,
      );
      final cold = MachineSession(
        relay: coldRelay,
        machineDeviceId: 'machine-2',
        handshaker: FakeHandshaker(),
      );
      cold.start();
      addTearDown(() async {
        await cold.dispose();
        await coldRelay.closeStreams();
      });

      final started = DateTime.now();
      await expectLater(
        cold.openProject('proj-b', {
          'type': 'project:start',
          'projectId': 'proj-b',
        }, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<StateError>()),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(milliseconds: 900)),
        reason:
            'the establishment wait and the stream-ready wait share ONE '
            'deadline; they must not stack into 2x the caller timeout',
      );
    });
  });

  group('StreamTransport.connect', () {
    test('attaching to a session with no keys returns without burning the '
        'snapshot RPC timeout', () async {
      final coldRelay = FakeLiveRelay(
        initial: RelayConnectionState.disconnected,
      );
      final cold = MachineSession(
        relay: coldRelay,
        machineDeviceId: 'machine-4',
        handshaker: FakeHandshaker(),
      );
      cold.start();
      addTearDown(() async {
        await cold.dispose();
        await coldRelay.closeStreams();
      });

      final started = DateTime.now();
      await cold.control.connect();
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason:
            'the request would be dropped for want of keys; the session '
            're-pulls the control transport on (re)establish anyway',
      );
      expect(coldRelay.sent, isEmpty);
    });
  });
}
