// `MachineSession.openProject` coverage: a project's native stream identity
// IS the project itself (`StreamTransport.projectId`, fixed for its
// lifetime) — there is no bridge-issued streamId, and no `{s, m}` envelope,
// on a project's own stream. Readiness-gating and
// snapshot-hydration coverage live in `machine_session_stream_binding_test.dart`
// and `machine_session_snapshot_retry_test.dart`; this file is the bind
// sequence itself — caps, refusals, protocol errors, reopen,
// `projectStreamEvents`, and the record-size caps on a bound project stream.
import 'dart:async';
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  late FakeLiveRelay relay;
  late MachineSession session;

  setUp(() async {
    relay = FakeLiveRelay();
  });

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  /// Establishes [session] over [relay] and marks [projectId] ready via a
  /// live `stream-ready` notice, so a caller can drive `openProject`'s
  /// native-stream leg directly through [relay.openedStreams].
  Future<void> establishReady(
    String projectId, {
    Map<String, dynamic> Function(String)? projectStartMessageBuilder,
  }) async {
    session = await establishSession(
      relay,
      handshaker: FakeHandshaker(),
      projectStartMessageBuilder: projectStartMessageBuilder,
    );
    relay.injectRecord(
      encodeFromAgent(
        jsonEncode({'type': 'stream-ready', 'projectId': projectId}),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  /// Rejects a pending `project:start` the way the bridge would (NOT_ALLOWED,
  /// project unknown, …) — used here to settle a filler project's
  /// still-pending open before a test ends.
  void rejectStart(String projectId) {
    relay.injectRecord(
      encodeFromAgent(
        jsonEncode({
          'type': 'control:result',
          'ok': false,
          'verb': 'project:start',
          'projectId': projectId,
          'error': {'code': 'CANCELLED', 'message': 'test cleanup'},
        }),
      ),
    );
  }

  /// `project:start` frames for [projectId] the app has sent so far.
  int startsSent(String projectId) => relay.sent
      .map((f) => decodeFromPhone(f.payload))
      .where(
        (t) =>
            t.contains('"type":"project:start"') &&
            t.contains('"projectId":"$projectId"'),
      )
      .length;

  void injectReadyNotice(String projectId) => relay.injectRecord(
    encodeFromAgent(
      jsonEncode({'type': 'stream-ready', 'projectId': projectId}),
    ),
  );

  group('the happy-path bind', () {
    test('opens a ProjectStreamOpen and binds on the stream\'s own '
        'stream-ready first record', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(relay.openedStreams, hasLength(1));
      expect(relay.openedStreams.single.open, const ProjectStreamOpen('proj-a'));
      relay.openedStreams.single.injectStreamReady('proj-a');

      final transport = await opening;
      expect(transport.projectId, 'proj-a');
      expect(transport.isProjectBound, isTrue);
      expect(identical(session.projectTransport('proj-a'), transport), isTrue);
    });
  });

  group('CAP_EXCEEDED', () {
    test('the (N+1)th distinct project fails synchronously, before any '
        'stream is opened', () async {
      session = await establishSession(relay, handshaker: FakeHandshaker());
      // Each one waits on its own stream-ready, which never comes — but the
      // cap check happens before that wait, so every call below returns
      // (occupying a slot) without ever touching relay.openedStreams.
      final fillers = <Future<StreamTransport>>[
        for (var i = 0; i < kStreamMaxProjectsPerPeer; i++)
          session.openProject('proj-$i', {
            'type': 'project:start',
            'projectId': 'proj-$i',
          }),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await expectLater(
        session.openProject('proj-overflow', {
          'type': 'project:start',
          'projectId': 'proj-overflow',
        }),
        throwsA(
          isA<ProjectBindException>().having(
            (e) => e.code,
            'code',
            'CAP_EXCEEDED',
          ),
        ),
      );
      expect(
        relay.openedStreams,
        isEmpty,
        reason:
            'none of the N ready-waits ever reached the point of opening a '
            'native stream, and the overflow must never even try',
      );

      // Settle every filler before the test ends. The expectations attach
      // before the rejections land, so no filler's error goes unhandled.
      final settled = [
        for (final f in fillers)
          expectLater(f, throwsA(isA<ProjectBindException>())),
      ];
      for (var i = 0; i < kStreamMaxProjectsPerPeer; i++) {
        rejectStart('proj-$i');
      }
      await Future.wait(settled);
    });
  });

  group('a NOT_READY refusal', () {
    test('is retried once, then fails if refused again', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(relay.openedStreams, hasLength(1));
      final startsBefore = startsSent('proj-a');
      relay.openedStreams[0].injectRefusal(StreamRefusedCode.notReady);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The refusal proves the ready mark stale: the retry re-sends
      // project:start and waits for a fresh ready notice before reopening.
      expect(startsSent('proj-a'), startsBefore + 1);
      expect(relay.openedStreams, hasLength(1));
      injectReadyNotice('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Dart cannot read a QUIC reset code, so the retry is a brand new
      // stream, not a re-read of the first one.
      expect(relay.openedStreams, hasLength(2));
      relay.openedStreams[1].injectRefusal(StreamRefusedCode.notReady);

      await expectLater(
        opening,
        throwsA(
          isA<ProjectBindException>().having(
            (e) => e.code,
            'code',
            'NOT_READY',
          ),
        ),
      );
      expect(
        relay.openedStreams,
        hasLength(2),
        reason: 'one retry only — a second NOT_READY must not retry again',
      );
    });

    test('a stream-ready on the retry\'s stream still binds', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.openedStreams[0].injectRefusal(StreamRefusedCode.notReady);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      injectReadyNotice('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.openedStreams[1].injectStreamReady('proj-a');

      final transport = await opening;
      expect(transport.isProjectBound, isTrue);
    });
  });

  group('a non-notReady refusal', () {
    test('fails at once, with no retry', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.openedStreams.single.injectRefusal(
        StreamRefusedCode.notAllowed,
        'phone not allowlisted',
      );

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
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(relay.openedStreams, hasLength(1));
    });
  });

  group('a protocol-violating first record', () {
    test('resets the stream and fails INVALID_RECORD', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stream = relay.openedStreams.single;
      // Neither a refusal nor this project's own stream-ready.
      stream.injectJson({'type': 'terminal:frame', 'seq': 1});

      await expectLater(
        opening,
        throwsA(
          isA<ProjectBindException>().having(
            (e) => e.code,
            'code',
            'INVALID_RECORD',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(stream.resetCalled, isTrue);
    });
  });

  group('projectStreamEvents', () {
    test('fires open:true once bound and open:false once the peer ends the '
        'stream', () async {
      await establishReady('proj-a');
      final events = <ProjectStreamEvent>[];
      final sub = session.projectStreamEvents.listen(events.add);

      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stream = relay.openedStreams.single;
      stream.injectStreamReady('proj-a');
      await opening;
      await Future<void>.delayed(Duration.zero);

      expect(events, [(projectId: 'proj-a', open: true)]);

      stream.end();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, [
        (projectId: 'proj-a', open: true),
        (projectId: 'proj-a', open: false),
      ]);
      await sub.cancel();
    });
  });

  group('reopen', () {
    test('a stream that ends while still wanted backs off, then re-asks and '
        'rebinds the SAME transport once a fresh ready notice answers it',
        () async {
      await establishReady(
        'proj-a',
        projectStartMessageBuilder: (pid) => {
          'type': 'project:start',
          'projectId': pid,
        },
      );
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.openedStreams.single.injectStreamReady('proj-a');
      final transport = await opening;

      final sentBefore = relay.sent.length;
      relay.openedStreams.single.end();
      // Well under kProjectStreamReopenInitialBackoff (1s): the reopen must
      // not have re-asked yet — it is backed off, not instant.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        relay.sent.length,
        sentBefore,
        reason: 'a mid-life end backs off; only a fresh establishment skips that',
      );
      expect(transport.isProjectBound, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(
        relay.sent.length,
        greaterThan(sentBefore),
        reason: 'the backoff elapsed — project:start is resent on its own',
      );

      relay.injectRecord(
        encodeFromAgent(
          jsonEncode({'type': 'stream-ready', 'projectId': 'proj-a'}),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        relay.openedStreams,
        hasLength(2),
        reason: 'the fresh ready notice lets the reopen open a new native '
            'stream — Dart cannot read a QUIC reset code, so this is never '
            'the same PeerStream as the one that ended',
      );
      relay.openedStreams[1].injectStreamReady('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        transport.isProjectBound,
        isTrue,
        reason: 'the SAME StreamTransport rebinds — a reopen never mints a '
            'new one for callers already holding a reference',
      );
    });
  });

  group('a superseded stream', () {
    test('ending after a re-establishment reopened the project leaves the '
        'new stream bound', () async {
      await establishReady(
        'proj-a',
        projectStartMessageBuilder: (pid) => {
          'type': 'project:start',
          'projectId': pid,
        },
      );
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final first = relay.openedStreams.single;
      first.injectStreamReady('proj-a');
      final transport = await opening;

      relay.setState(
        const AppState(connectionState: RelayConnectionState.disconnected),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.isProjectBound, isFalse);
      relay.setState(
        const AppState(connectionState: RelayConnectionState.authenticated),
      );
      await session.ensureEstablished();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      injectReadyNotice('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(relay.openedStreams, hasLength(2));
      final second = relay.openedStreams[1];
      second.injectStreamReady('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.isProjectBound, isTrue);

      // The old connection's stream only now reports its end.
      first.end();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.isProjectBound, isTrue);
    });

    test('a stream-ready arriving after the bind gave up resets that stream '
        'instead of binding it', () async {
      await establishReady(
        'proj-a',
        projectStartMessageBuilder: (pid) => {
          'type': 'project:start',
          'projectId': pid,
        },
      );
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      relay.openedStreams.single.injectStreamReady('proj-a');
      final transport = await opening;

      // The stream ends; a caller re-opening the same transport under a
      // short deadline gets a stream whose first record never comes in time.
      relay.openedStreams.single.end();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final rebinding = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      }, timeout: const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      injectReadyNotice('proj-a');
      await expectLater(
        rebinding,
        throwsA(
          isA<ProjectBindException>().having((e) => e.code, 'code', 'E_TIMEOUT'),
        ),
      );
      expect(relay.openedStreams, hasLength(2));
      final gaveUp = relay.openedStreams[1];
      expect(gaveUp.resetCalled, isTrue);

      gaveUp.injectStreamReady('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.isProjectBound, isFalse);
    });
  });

  group('openProject racing a dispose', () {
    test('waits out the draining transport and hands back a fresh, live one',
        () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final first = relay.openedStreams.single;
      first.injectStreamReady('proj-a');
      final old = await opening;

      final disposing = old.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      StreamTransport? fresh;
      final reopening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      }).then((t) => fresh = t);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fresh, isNull, reason: 'a disposing transport is never handed out');

      first.end();
      await disposing;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      injectReadyNotice('proj-a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(relay.openedStreams, hasLength(2));
      relay.openedStreams[1].injectStreamReady('proj-a');
      await reopening;
      expect(identical(fresh, old), isFalse);
      expect(fresh!.isProjectBound, isTrue);
      expect(identical(session.projectTransport('proj-a'), fresh), isTrue);
    });
  });

  group('disposing a bound transport', () {
    test('holds its cap slot until the bridge\'s own FIN drains the stream',
        () async {
      session = await establishSession(relay, handshaker: FakeHandshaker());
      relay.injectRecord(
        encodeFromAgent(
          jsonEncode({'type': 'stream-ready', 'projectId': 'proj-a'}),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stream = relay.openedStreams.single;
      stream.injectStreamReady('proj-a');
      final transport = await opening;

      final fillers = <Future<StreamTransport>>[
        for (var i = 0; i < kStreamMaxProjectsPerPeer - 1; i++)
          session.openProject('proj-fill-$i', {
            'type': 'project:start',
            'projectId': 'proj-fill-$i',
          }),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final disposing = transport.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(stream.finishCalled, isTrue);

      await expectLater(
        session.openProject('proj-overflow', {
          'type': 'project:start',
          'projectId': 'proj-overflow',
        }),
        throwsA(
          isA<ProjectBindException>().having(
            (e) => e.code,
            'code',
            'CAP_EXCEEDED',
          ),
        ),
        reason:
            'the disposed transport still counts against the cap until its '
            'records drain',
      );

      stream.end();
      await disposing;

      // The slot is free again — proj-overflow now gets far enough to wait
      // on its OWN readiness (never answered here), so it times out rather
      // than drawing CAP_EXCEEDED. That is the proof the slot freed: a still
      //-held slot would have failed CAP_EXCEEDED synchronously instead.
      await expectLater(
        session.openProject('proj-overflow', {
          'type': 'project:start',
          'projectId': 'proj-overflow',
        }, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );

      // Settle the fillers before the test ends. The expectations attach
      // before the rejections land, so no filler's error goes unhandled.
      final settled = [
        for (final f in fillers)
          expectLater(f, throwsA(isA<ProjectBindException>())),
      ];
      for (var i = 0; i < kStreamMaxProjectsPerPeer - 1; i++) {
        rejectStart('proj-fill-$i');
      }
      await Future.wait(settled);
    });
  });

  group('record-size caps on a bound project stream', () {
    test(
      'S1: the project stream is opened with '
      'maxRecordBytes: kStreamProjectBridgeRecordMaxBytes',
      () async {
        await establishReady('proj-a');
        session.openProject('proj-a', {
          'type': 'project:start',
          'projectId': 'proj-a',
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          relay.openedStreams.single.maxRecordBytes,
          kStreamProjectBridgeRecordMaxBytes,
        );
      },
    );

    test('S2: a 20 MB inbound project record dispatches as one message', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stream = relay.openedStreams.single;
      stream.injectStreamReady('proj-a');
      final transport = await opening;

      final seen = <Map<String, dynamic>>[];
      final sub = transport.messages.listen((m) => seen.add(m.json));
      final blob = 'a' * (20 * 1024 * 1024);
      stream.injectJson({'type': 'file:content', 'content': blob});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, hasLength(1));
      expect(seen.single['content'], blob);
      await sub.cancel();
    });

    test(
      'S3: a project send over kStreamProjectAppRecordMaxBytes drops '
      'message-too-large and emits MessageTooLarge',
      () async {
        await establishReady('proj-a');
        final opening = session.openProject('proj-a', {
          'type': 'project:start',
          'projectId': 'proj-a',
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final stream = relay.openedStreams.single;
        stream.injectStreamReady('proj-a');
        final transport = await opening;

        final tooLarge = <MessageTooLarge>[];
        final sub = session.messageTooLarge.listen(tooLarge.add);
        final blob = 'a' * (kStreamProjectAppRecordMaxBytes + 1);
        await transport.send({'type': 'git:diff', 'path': blob});
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // The bind's own hydration request may share the stream; the
        // oversized verb must not.
        final sentTypes = stream.sent
            .map((b) => (jsonDecode(utf8.decode(b)) as Map)['type'])
            .toList();
        expect(sentTypes, isNot(contains('git:diff')));
        expect(tooLarge, hasLength(1));
        expect(tooLarge.single.type, 'git:diff');
        await sub.cancel();
      },
    );
  });
}
