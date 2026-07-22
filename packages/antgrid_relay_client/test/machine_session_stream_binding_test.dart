// Project→stream binding hydration coverage (design §7.4): a reconnecting
// phone must be able to bind a project stream from PULLED state (the
// `state.snapshot` reply), not only from live `stream-ready` /
// `agent:projects` pushes — the bridge's replay-cache dedup can legally
// suppress a byte-identical re-advert after an app kill+reopen, so the live
// push is best-effort and the snapshot is the reconnect contract.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_paired_relay.dart';

Future<String?> _openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

void main() {
  late FakePairedRelay relay;
  late FakeHandshaker handshaker;
  late SessionKeys keys;
  late MachineSession session;

  setUp(() async {
    relay = FakePairedRelay();
    keys = fixedKeys(1);
    handshaker = FakeHandshaker(keys);
    session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
    );
    session.start();
    await session.ready;
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  Future<List<Map<String, dynamic>>> sentEnvelopes() async {
    final out = <Map<String, dynamic>>[];
    for (final f in relay.sent) {
      final pt = await _openFromPhone(keys, f.payload);
      if (pt != null) out.add(jsonDecode(pt) as Map<String, dynamic>);
    }
    return out;
  }

  /// The requestId of the first control-plane `state.snapshot` RPC sent.
  Future<String?> snapshotRequestId() async {
    for (final e in await sentEnvelopes()) {
      final m = e['m'];
      if (m is Map &&
          m['type'] == 'request' &&
          m['method'] == 'state.snapshot' &&
          !e.containsKey('s')) {
        return m['requestId'] as String?;
      }
    }
    return null;
  }

  Future<void> injectControl(Map<String, dynamic> m) async {
    relay.inject(IncomingRouteMessage(
      from: 'machine-1',
      channel: 'control',
      kind: FrameKind.sealed,
      payload: await _sealFromAgent(keys, jsonEncode({'m': m})),
    ));
  }

  group('snapshot hydration', () {
    test(
        'a state.snapshot reply carrying agent:projects{streamId} populates '
        'streamIdForProject, completes a pending bindProject, and emits '
        'streamReadyEvents', () async {
      final events = <({String projectId, String streamId})>[];
      final evSub = session.streamReadyEvents.listen(events.add);

      // Attaching the control transport auto-pulls the snapshot.
      session.streamFor(kControlStreamId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final requestId = await snapshotRequestId();
      expect(requestId, isNotNull,
          reason: 'attaching the control stream must pull state.snapshot');

      // The reconnect scenario: the live re-advert was dedup-suppressed, so
      // the app falls back to bindProject → project:start. The ONLY carrier
      // of the binding is the snapshot reply below.
      final bindF = session.bindProject(
        'proj-a',
        {'type': 'project:start', 'projectId': 'proj-a'},
        timeout: const Duration(milliseconds: 500),
      );

      await injectControl({
        'type': 'response',
        'requestId': requestId,
        'ok': true,
        'result': {
          'frames': [
            {
              'type': 'agent:projects',
              'projects': [
                {'projectId': 'proj-a', 'running': true, 'streamId': 's-42'},
              ],
            },
          ],
        },
      });

      expect(await bindF, 's-42',
          reason: 'bindProject must resolve from the snapshot-replayed advert');
      expect(session.streamIdForProject('proj-a'), 's-42');
      // Broadcast-stream delivery lands a microtask after the completer.
      await Future<void>.delayed(Duration.zero);
      expect(events, contains((projectId: 'proj-a', streamId: 's-42')),
          reason: 'focus resync (ProjectSession) listens on streamReadyEvents; '
              'snapshot hydration must feed it too');
      await evSub.cancel();
    });
  });

  group('advert replace semantics', () {
    test(
        'an agent:projects advert is the complete dialable catalog: a stale '
        'binding for a project no longer advertised with a streamId is dropped',
        () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-old', 'running': true, 'streamId': 's-old'},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.streamIdForProject('proj-old'), 's-old');

      // The agent restarted: proj-old is no longer dialable, proj-new is.
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-old', 'running': false},
          {'projectId': 'proj-new', 'running': true, 'streamId': 's-new'},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.streamIdForProject('proj-new'), 's-new');
      expect(session.streamIdForProject('proj-old'), isNull,
          reason: 'a binding the advert no longer vouches for is stale — '
              'sends to it would land on a dead stream with no feedback');
    });

    test('an empty advert drops bindings but leaves attached streams routable',
        () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-p', 'running': true, 'streamId': 's-p'},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final attached = session.streamFor('s-p');

      // buildProjectsAdvertisement returns [] for a phone it can't resolve —
      // reachable transiently (handshake push before the phone is upserted).
      await injectControl({'type': 'agent:projects', 'projects': const []});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(session.streamIdForProject('proj-p'), isNull);
      expect(identical(session.streamFor('s-p'), attached), isTrue,
          reason: 'the wipe must cost at most a re-bind RTT; tearing the live '
              'StreamTransport down would drop a working session');
    });
  });

  group('bindProject keyless window', () {
    test('a bind issued before the session establishes waits for keys and '
        'resolves once the handshake lands', () async {
      final coldRelay =
          FakePairedRelay(initial: RelayConnectionState.disconnected);
      final coldKeys = fixedKeys(3);
      final cold = MachineSession(
        relay: coldRelay,
        machineDeviceId: 'machine-3',
        handshaker: FakeHandshaker(coldKeys),
      );
      cold.start();
      addTearDown(() async {
        await cold.dispose();
        await coldRelay.closeStreams();
      });

      final bindF = cold.bindProject(
        'proj-d',
        {'type': 'project:start', 'projectId': 'proj-d'},
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coldRelay.sent, isEmpty,
          reason: 'project:start must not be sent into the keyless window — '
              'sendOnStream would drop it silently');

      // The reconnect lands: paired → handshake → keys installed.
      coldRelay.setState(
          const AppState(connectionState: RelayConnectionState.paired));
      await cold.ready;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      coldRelay.inject(IncomingRouteMessage(
        from: 'machine-3',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(
          coldKeys,
          jsonEncode({
            'm': {
              'type': 'stream-ready',
              'projectId': 'proj-d',
              'streamId': 's-7',
            },
          }),
        ),
      ));

      expect(await bindF, 's-7');
    });

    test('a bind that never sees keys fails with StateError, bounded by its '
        'own timeout (instead of a blind stream-ready wait)', () async {
      final coldRelay =
          FakePairedRelay(initial: RelayConnectionState.disconnected);
      final cold = MachineSession(
        relay: coldRelay,
        machineDeviceId: 'machine-2',
        handshaker: FakeHandshaker(fixedKeys(2)),
      );
      cold.start();
      addTearDown(() async {
        await cold.dispose();
        await coldRelay.closeStreams();
      });

      final started = DateTime.now();
      await expectLater(
        cold.bindProject(
          'proj-b',
          {'type': 'project:start', 'projectId': 'proj-b'},
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<StateError>()),
      );
      expect(DateTime.now().difference(started),
          lessThan(const Duration(milliseconds: 900)),
          reason: 'the keys wait and the stream-ready wait share ONE deadline; '
              'they must not stack into 2x the caller timeout');
    });
  });

  group('bindProject failure paths', () {
    test('a shared stream-ready waiter outlives one caller\'s timeout: a '
        'concurrent bind of the same project still resolves', () async {
      final impatient = session.bindProject(
        'proj-e',
        {'type': 'project:start', 'projectId': 'proj-e'},
        timeout: const Duration(milliseconds: 100),
      );
      final patient = session.bindProject(
        'proj-e',
        {'type': 'project:start', 'projectId': 'proj-e'},
        timeout: const Duration(seconds: 2),
      );

      await expectLater(impatient, throwsA(isA<TimeoutException>()));

      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-e',
        'streamId': 's-9',
      });

      expect(await patient, 's-9',
          reason: 'the waiter is shared via putIfAbsent; one caller giving up '
              'must not strand the other');
    });

    test('an already-advertised project binds at 0 RTT — no project:start, no '
        'second stream-ready needed', () async {
      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-z',
        'streamId': 's-z',
      });
      // Injection only queues the frame; the decrypt/dispatch is async.
      for (var i = 0; i < 50 && session.streamIdForProject('proj-z') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.streamIdForProject('proj-z'), 's-z');

      final sentBefore = relay.sent.length;
      // A short timeout is the assertion: resolving at all means it never
      // waited on a `stream-ready` the agent has no reason to send again.
      expect(
        await session.bindProject(
          'proj-z',
          {'type': 'project:start', 'projectId': 'proj-z'},
          timeout: const Duration(milliseconds: 200),
        ),
        's-z',
      );
      expect(relay.sent.length, sentBefore,
          reason: 'a known mapping must not re-ask the agent to start the '
              'project');
    });

    test('a control:result{ok:false} for a DIFFERENT verb leaves the pending '
        'bindProject alone', () async {
      final bindF = session.bindProject(
        'proj-f',
        {'type': 'project:start', 'projectId': 'proj-f'},
        timeout: const Duration(milliseconds: 400),
      );

      // The bridge echoes `projectId` on EVERY failed control-plane verb,
      // including the UNKNOWN_VERB fallthrough (host-server.ts). Only the
      // project:start rejection says anything about this bind.
      await injectControl({
        'type': 'control:result',
        'ok': false,
        'verb': 'sessions.delete',
        'projectId': 'proj-f',
        'error': {'code': 'UNKNOWN_VERB', 'message': 'unsupported verb'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-f',
        'streamId': 's-f',
      });
      expect(await bindF, 's-f');
    });

    test('a control:result{ok:false, projectId} fails the pending bindProject '
        'with the agent\'s error code instead of timing out', () async {
      final bindF = session.bindProject(
        'proj-c',
        {'type': 'project:start', 'projectId': 'proj-c'},
        timeout: const Duration(milliseconds: 500),
      );

      await injectControl({
        'type': 'control:result',
        'ok': false,
        'verb': 'project:start',
        'projectId': 'proj-c',
        'error': {'code': 'NOT_ALLOWED', 'message': 'phone not allowlisted'},
      });

      await expectLater(
        bindF,
        throwsA(isA<ProjectBindException>()
            .having((e) => e.code, 'code', 'NOT_ALLOWED')),
      );
    });
  });

  group('StreamTransport.connect', () {
    test('attaching to a session with no keys returns without burning the '
        'snapshot RPC timeout', () async {
      final coldRelay =
          FakePairedRelay(initial: RelayConnectionState.disconnected);
      final cold = MachineSession(
        relay: coldRelay,
        machineDeviceId: 'machine-4',
        handshaker: FakeHandshaker(fixedKeys(4)),
      );
      cold.start();
      addTearDown(() async {
        await cold.dispose();
        await coldRelay.closeStreams();
      });

      final started = DateTime.now();
      await cold.streamFor('s-1').connect();
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 1)),
          reason: 'the request would be dropped for want of keys; the session '
              're-pulls every attached stream on (re)establish anyway');
      expect(coldRelay.sent, isEmpty);
    });
  });
}
