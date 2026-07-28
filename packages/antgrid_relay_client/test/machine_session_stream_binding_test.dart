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

import 'support/fake_live_relay.dart';

Future<String?> _openFromPhone(SessionKeys keys, Uint8List payload) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).open(payload);

Future<Uint8List> _sealFromAgent(SessionKeys keys, String plaintext) =>
    E2eTransportDart(sendKey: keys.a2p, recvKey: keys.p2a).seal(plaintext);

void main() {
  late FakeLiveRelay relay;
  late FakeHandshaker handshaker;
  late SessionKeys keys;
  late MachineSession session;

  setUp(() async {
    relay = FakeLiveRelay();
    keys = fixedKeys(1);
    handshaker = FakeHandshaker(keys);
    session = MachineSession(
      relay: relay,
      machineDeviceId: 'machine-1',
      handshaker: handshaker,
      projectStartMessageBuilder: (projectId) => {
        'type': 'project:start',
        'projectId': projectId,
      },
    );
    session.start();
    await session.ensureEstablished();
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
    relay.inject(
      IncomingRouteMessage(
        from: 'machine-1',
        channel: 'control',
        kind: FrameKind.sealed,
        payload: await _sealFromAgent(keys, jsonEncode({'m': m})),
      ),
    );
  }

  group('snapshot hydration', () {
    test('a state.snapshot reply carrying agent:projects{streamId} populates '
        'streamIdForProject, completes a pending bindProject, and emits '
        'streamReadyEvents', () async {
      final events = <({String projectId, String streamId})>[];
      final evSub = session.streamReadyEvents.listen(events.add);

      // Attaching the control transport auto-pulls the snapshot.
      session.streamFor(kControlStreamId);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final requestId = await snapshotRequestId();
      expect(
        requestId,
        isNotNull,
        reason: 'attaching the control stream must pull state.snapshot',
      );

      // The reconnect scenario: the live re-advert was dedup-suppressed, so
      // the app falls back to bindProject → project:start. The ONLY carrier
      // of the binding is the snapshot reply below.
      final bindF = session.bindProject('proj-a', {
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
                {'projectId': 'proj-a', 'running': true, 'streamId': 's-42'},
              ],
            },
          ],
        },
      });

      expect(
        await bindF,
        's-42',
        reason: 'bindProject must resolve from the snapshot-replayed advert',
      );
      expect(session.streamIdForProject('proj-a'), 's-42');
      // Broadcast-stream delivery lands a microtask after the completer.
      await Future<void>.delayed(Duration.zero);
      expect(
        events,
        contains((projectId: 'proj-a', streamId: 's-42')),
        reason:
            'focus resync (ProjectSession) listens on streamReadyEvents; '
            'snapshot hydration must feed it too',
      );
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
        expect(
          session.streamIdForProject('proj-old'),
          isNull,
          reason:
              'a binding the advert no longer vouches for is stale — '
              'sends to it would land on a dead stream with no feedback',
        );
      },
    );

    test(
      'an empty advert drops bindings but leaves attached streams routable',
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
        expect(
          identical(session.streamFor('s-p'), attached),
          isTrue,
          reason:
              'the wipe must cost at most a re-bind RTT; tearing the live '
              'StreamTransport down would drop a working session',
        );
      },
    );

    test('a project re-advertised under a NEW streamId (host restart) re-points '
        'its LIVE transport in place: outbound sends carry the new id and '
        'inbound frames on the new id reach the same transport', () async {
      // The phone opened the project: it learned s-old and built the stream's
      // transport (what agent_transport.dart does via streamFor).
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-r', 'running': true, 'streamId': 's-old'},
        ],
      });
      for (
        var i = 0;
        i < 50 && session.streamIdForProject('proj-r') == null;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final transport = session.streamFor('s-old');
      final inbound = <Map<String, dynamic>>[];
      final sub = transport.messages.listen((m) => inbound.add(m.json));

      final before1 = relay.sent.length;
      await transport.send({'type': 'ping-old'});
      final env1 = (await sentEnvelopes())
          .skip(before1)
          .firstWhere((e) => (e['m'] as Map)['type'] == 'ping-old');
      expect(env1['s'], 's-old', reason: 'sanity: sends target s-old first');

      // The desktop host restarted (close + reopen): the project re-attached
      // under a fresh random streamId and the control-plane snapshot re-advert
      // carries it. The bare advert alone must re-point the transport — the app
      // does NOT rebuild it on peer reconnect.
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-r', 'running': true, 'streamId': 's-new'},
        ],
      });
      for (
        var i = 0;
        i < 50 && session.streamIdForProject('proj-r') != 's-new';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // Outbound: the SAME transport now targets s-new.
      expect(
        identical(session.streamFor('s-new'), transport),
        isTrue,
        reason:
            'the transport must migrate in place, not be re-created for '
            'the new id — ProjectSession/services hold the old reference',
      );
      final before2 = relay.sent.length;
      await transport.send({'type': 'ping-new'});
      final env2 = (await sentEnvelopes())
          .skip(before2)
          .firstWhere((e) => (e['m'] as Map)['type'] == 'ping-new');
      expect(
        env2['s'],
        's-new',
        reason:
            'a host restart changes the streamId; a transport left on the '
            'dead id makes the host drop every send ("unknown streamId")',
      );

      // Inbound: a frame on s-new reaches the migrated transport.
      relay.inject(
        IncomingRouteMessage(
          from: 'machine-1',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await _sealFromAgent(
            keys,
            jsonEncode({
              's': 's-new',
              'm': {'type': 'agent:status', 'foo': 1},
            }),
          ),
        ),
      );
      for (
        var i = 0;
        i < 50 && !inbound.any((j) => j['type'] == 'agent:status');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        inbound.any((j) => j['type'] == 'agent:status'),
        isTrue,
        reason:
            'the restarted host pushes on s-new; the migrated transport '
            'must receive it',
      );
      await sub.cancel();
    });
  });

  // Regression (Phase C smoke, 2026-07-27): a bridge restart re-attaches every
  // project under fresh ids, so the phone's cached id is dead. Before the
  // bridge answered `stream-invalid` the phone replayed onto it forever —
  // "Couldn't load this project's sessions: TimeoutException" until a force
  // quit; backing out of the project and re-entering never renegotiated.
  group('stream-invalid (host restart self-heal)', () {
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('a stream-invalid for the bound id re-drives project:start and '
        'migrates the LIVE transport onto the id the restarted host '
        'answers with', () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-i', 'running': true, 'streamId': 's-dead'},
        ],
      });
      await settle();
      final transport = session.streamFor('s-dead');

      final before = relay.sent.length;
      await injectControl({'type': 'stream-invalid', 'streamId': 's-dead'});
      await settle();

      expect(
        session.streamIdForProject('proj-i'),
        isNull,
        reason:
            'a dead id must read as unbound, or a transport rebuilt off it '
            're-adopts the id the host just disowned',
      );
      final restart = (await sentEnvelopes())
          .skip(before)
          .where((e) => (e['m'] as Map)['type'] == 'project:start')
          .toList();
      expect(
        restart,
        hasLength(1),
        reason:
            'the advert carrying the new id is exactly what did not reach '
            'us — waiting for one is what stranded the phone',
      );
      expect(restart.single.containsKey('s'), isFalse);
      expect((restart.single['m'] as Map)['projectId'], 'proj-i');

      // The restarted host opens the project and answers with the fresh id.
      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-i',
        'streamId': 's-fresh',
      });
      await settle();

      expect(session.streamIdForProject('proj-i'), 's-fresh');
      expect(
        identical(session.streamFor('s-fresh'), transport),
        isTrue,
        reason:
            'ProjectSession and all 7 services hold this reference — a new '
            'transport for the new id leaves them on the dead one',
      );
      final beforeSend = relay.sent.length;
      await transport.send({'type': 'ping-healed'});
      final env = (await sentEnvelopes())
          .skip(beforeSend)
          .firstWhere((e) => (e['m'] as Map)['type'] == 'ping-healed');
      expect(env['s'], 's-fresh');
    });

    // The observed 2026-07-27 failure: the restarted host re-opened the project
    // in LOCAL mode, so the advert announcing it back said dialable:false. The
    // app forgot the binding but left the transport aimed at the dead id, and
    // every service kept sending into the void — backing out of the project and
    // re-entering never helped because ProjectSessionRegistry keeps the session
    // warm, so the transport was never rebuilt.
    test('an advert that drops a bound project\'s streamId re-drives '
        'project:start for the transport still live on the dead id', () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-l', 'running': true, 'streamId': 's-was'},
        ],
      });
      await settle();
      final transport = session.streamFor('s-was');

      final before = relay.sent.length;
      // The restart's advert: the project is back, but not dialable — no
      // replacement id for _recordProjectStream to migrate onto.
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-l', 'running': false},
        ],
      });
      await settle();

      expect(session.streamIdForProject('proj-l'), isNull);
      expect(
        (await sentEnvelopes())
            .skip(before)
            .where((e) => (e['m'] as Map)['type'] == 'project:start'),
        hasLength(1),
        reason:
            'forgetting the binding alone leaves the live transport on the '
            'dead id — the project must be re-asked for a stream',
      );

      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-l',
        'streamId': 's-now',
      });
      await settle();
      expect(identical(session.streamFor('s-now'), transport), isTrue);
    });

    test('an advert dropping a project with NO live transport just forgets the '
        'binding — nothing to re-drive', () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-m', 'running': true, 'streamId': 's-m'},
        ],
      });
      await settle();

      final before = relay.sent.length;
      await injectControl({'type': 'agent:projects', 'projects': const []});
      await settle();

      expect(session.streamIdForProject('proj-m'), isNull);
      expect(relay.sent.length, before);
    });

    test('a stream-invalid for an id we hold no binding for is ignored — no '
        'project:start storm', () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-j', 'running': true, 'streamId': 's-live'},
        ],
      });
      await settle();

      final before = relay.sent.length;
      // A notice for an id already superseded by a re-advert, or one that was
      // never ours: re-driving would restart a project nobody asked for.
      await injectControl({'type': 'stream-invalid', 'streamId': 's-stale'});
      await settle();

      expect(relay.sent.length, before);
      expect(session.streamIdForProject('proj-j'), 's-live');
    });

    test('a FAILED rebind releases the guard: the agent\'s next notice for the '
        'same dead id re-drives project:start', () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-n', 'running': true, 'streamId': 's-n'},
        ],
      });
      await settle();
      session.streamFor('s-n');

      final before = relay.sent.length;
      await injectControl({'type': 'stream-invalid', 'streamId': 's-n'});
      await settle();
      // The rebind loses: the restarted host rejects the start (or the socket
      // blips before stream-ready and the bind times out).
      await injectControl({
        'type': 'control:result',
        'ok': false,
        'verb': 'project:start',
        'projectId': 'proj-n',
        'error': {'code': 'OPEN_FAILED', 'message': 'still starting'},
      });
      await settle();

      // The phone is still replaying onto the dead id, so the agent notices
      // again. Gating the send on "already marked dead" would swallow this and
      // leave the project stranded exactly as before the fix.
      await injectControl({'type': 'stream-invalid', 'streamId': 's-n'});
      await settle();

      expect(
        (await sentEnvelopes())
            .skip(before)
            .where((e) => (e['m'] as Map)['type'] == 'project:start'),
        hasLength(2),
      );
    });

    test('a repeated stream-invalid for the same dead id does not re-send '
        'project:start while the rebind is still in flight', () async {
      await injectControl({
        'type': 'agent:projects',
        'projects': [
          {'projectId': 'proj-k', 'running': true, 'streamId': 's-k'},
        ],
      });
      await settle();

      final before = relay.sent.length;
      await injectControl({'type': 'stream-invalid', 'streamId': 's-k'});
      await injectControl({'type': 'stream-invalid', 'streamId': 's-k'});
      await settle();

      expect(
        (await sentEnvelopes())
            .skip(before)
            .where((e) => (e['m'] as Map)['type'] == 'project:start'),
        hasLength(1),
      );
    });
  });

  group('bindProject keyless window', () {
    test('a bind issued before the session establishes waits for keys and '
        'resolves once the handshake lands', () async {
      final coldRelay = FakeLiveRelay(
        initial: RelayConnectionState.disconnected,
      );
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

      final bindF = cold.bindProject('proj-d', {
        'type': 'project:start',
        'projectId': 'proj-d',
      }, timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        coldRelay.sent,
        isEmpty,
        reason:
            'project:start must not be sent into the keyless window — '
            'sendOnStream would drop it silently',
      );

      // The reconnect lands: the supervisor climbs to the established rung and
      // drives the handshake, which installs the keys.
      coldRelay.setState(
        const AppState(connectionState: RelayConnectionState.authenticated),
      );
      await cold.ensureEstablished();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      coldRelay.inject(
        IncomingRouteMessage(
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
        ),
      );

      expect(await bindF, 's-7');
    });

    test('a bind that never sees keys fails with StateError, bounded by its '
        'own timeout (instead of a blind stream-ready wait)', () async {
      final coldRelay = FakeLiveRelay(
        initial: RelayConnectionState.disconnected,
      );
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
        cold.bindProject('proj-b', {
          'type': 'project:start',
          'projectId': 'proj-b',
        }, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<StateError>()),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(milliseconds: 900)),
        reason:
            'the keys wait and the stream-ready wait share ONE deadline; '
            'they must not stack into 2x the caller timeout',
      );
    });
  });

  group('bindProject failure paths', () {
    test('a shared stream-ready waiter outlives one caller\'s timeout: a '
        'concurrent bind of the same project still resolves', () async {
      final impatient = session.bindProject('proj-e', {
        'type': 'project:start',
        'projectId': 'proj-e',
      }, timeout: const Duration(milliseconds: 100));
      final patient = session.bindProject('proj-e', {
        'type': 'project:start',
        'projectId': 'proj-e',
      }, timeout: const Duration(seconds: 2));

      await expectLater(impatient, throwsA(isA<TimeoutException>()));

      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-e',
        'streamId': 's-9',
      });

      expect(
        await patient,
        's-9',
        reason:
            'the waiter is shared via putIfAbsent; one caller giving up '
            'must not strand the other',
      );
    });

    test('an already-advertised project binds at 0 RTT — no project:start, no '
        'second stream-ready needed', () async {
      await injectControl({
        'type': 'stream-ready',
        'projectId': 'proj-z',
        'streamId': 's-z',
      });
      // Injection only queues the frame; the decrypt/dispatch is async.
      for (
        var i = 0;
        i < 50 && session.streamIdForProject('proj-z') == null;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.streamIdForProject('proj-z'), 's-z');

      final sentBefore = relay.sent.length;
      // A short timeout is the assertion: resolving at all means it never
      // waited on a `stream-ready` the agent has no reason to send again.
      expect(
        await session.bindProject('proj-z', {
          'type': 'project:start',
          'projectId': 'proj-z',
        }, timeout: const Duration(milliseconds: 200)),
        's-z',
      );
      expect(
        relay.sent.length,
        sentBefore,
        reason:
            'a known mapping must not re-ask the agent to start the '
            'project',
      );
    });

    test('a control:result{ok:false} for a DIFFERENT verb leaves the pending '
        'bindProject alone', () async {
      final bindF = session.bindProject('proj-f', {
        'type': 'project:start',
        'projectId': 'proj-f',
      }, timeout: const Duration(milliseconds: 400));

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
      final bindF = session.bindProject('proj-c', {
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
        bindF,
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

  group('StreamTransport.connect', () {
    test('attaching to a session with no keys returns without burning the '
        'snapshot RPC timeout', () async {
      final coldRelay = FakeLiveRelay(
        initial: RelayConnectionState.disconnected,
      );
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
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason:
            'the request would be dropped for want of keys; the session '
            're-pulls every attached stream on (re)establish anyway',
      );
      expect(coldRelay.sent, isEmpty);
    });
  });
}
