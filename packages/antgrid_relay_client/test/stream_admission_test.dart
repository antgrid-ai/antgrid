// Table-driven admission coverage for `_StreamExchange`
// (`machine_session.dart`): the four non-project kinds share one
// open/record/teardown skeleton, so each rule runs once per
// `streamKindCases()` entry. The project stream keeps its own bind machinery
// but obeys the same rules; those rows are marked (P) below.
//
// Every rule that resets a stream (send failure, cancel during open, protocol
// breach) asserts `resetCalled` inline, so error-path resets need no group of
// their own.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';
import 'support/native_stream_link.dart' show pump;
import 'support/stream_kind_cases.dart';

/// A record that fails the kind's own `onRecord` check — everything else
/// about the exchange (open, slot, first record) already succeeded.
void injectProtocolBreach(FakePeerStream stream, String kind) {
  switch (kind) {
    case 'tunnel-tcp':
      stream.injectJson({'type': 'not-a-reply'});
    case 'upload':
      stream.injectJson({'type': 'not-a-result'});
    default: // terminal: does not decode non-JSON text.
      stream.injectRecord(Uint8List.fromList(utf8.encode('not json')));
  }
}

void main() {
  late FakeLiveRelay relay;
  late MachineSession session;

  setUp(() => relay = FakeLiveRelay());

  tearDown(() async {
    await session.dispose();
    await relay.closeStreams();
  });

  /// Establishes [session] and binds `proj-a`'s project transport, so every
  /// kind under test opens on top of a real project stream exactly as the
  /// app does.
  Future<StreamTransport> bindProject() async {
    session = await establishSession(relay, handshaker: FakeHandshaker());
    final opening = session.openProject('proj-a', {
      'type': 'project:start',
      'projectId': 'proj-a',
    });
    await pump();
    relay.injectRecord(
      encodeFromAgent(jsonEncode({'type': 'stream-ready', 'projectId': 'proj-a'})),
    );
    await pump();
    relay.openedStreams.last.injectStreamReady('proj-a');
    final transport = await opening;
    relay.openedStreams.clear(); // binding traffic is not what is under test
    return transport;
  }

  for (final c in streamKindCases()) {
    group(c.kind, () {
      test('open frame fields', () async {
        final transport = await bindProject();
        c.open(transport, 0);
        await pump();
        final opened = relay.openedStreams.single;
        expect(opened.open.toJson()['projectId'], 'proj-a');
        expect(opened.maxRecordBytes, c.maxRecordBytes);
        expect(opened.maxQueuedBytes, c.maxQueuedBytes);
      });

      test('openStream throws fails STREAM_OPEN_FAILED; no reset; nothing '
          'reaches failureStream', () async {
        final transport = await bindProject();
        final failures = <PeerLinkFailure>[];
        final sub = relay.failureStream.listen(failures.add);
        relay.openStreamError = StateError('native open failed');
        final handle = c.open(transport, 0);
        expect(await c.failureCode(handle), 'STREAM_OPEN_FAILED');
        expect(relay.openedStreams, isEmpty);
        expect(failures, isEmpty);
        await sub.cancel();
      });

      test('a refusal as the first record fails REFUSED and finishes the '
          'stream', () async {
        final transport = await bindProject();
        final handle = c.open(transport, 0);
        await pump();
        final stream = relay.openedStreams.single;
        stream.injectRefusal(StreamRefusedCode.capExceeded, 'too many');
        expect(await c.failureCode(handle), 'REFUSED');
        expect(stream.finishCalled, isTrue);
      });

      test('cap exceeded then freed', () async {
        final transport = await bindProject();
        final fillers = [for (var i = 0; i < c.cap; i++) c.open(transport, i)];
        // Listen before any filler can end, or a kind whose end is a future
        // error (tunnel-tcp's ready) surfaces it as unhandled.
        for (final f in fillers) {
          unawaited(c.failureCode(f));
        }
        await pump();
        expect(relay.openedStreams, hasLength(c.cap));

        final waiter = c.open(transport, c.cap);
        if (c.failsFastAtCap) {
          expect(await c.failureCode(waiter), 'CAP_EXCEEDED');
          expect(relay.openedStreams, hasLength(c.cap));
        } else {
          await pump();
          expect(
            relay.openedStreams,
            hasLength(c.cap),
            reason: 'the over-cap open must wait for a slot',
          );
          relay.openedStreams.first.end();
          await pump();
          expect(relay.openedStreams, hasLength(c.cap + 1));
          unawaited(c.failureCode(waiter));
        }

        for (final s in relay.openedStreams) {
          s.end();
        }
        await pump();
      });

      test('cancel before open never opens a stream; slot freed', () async {
        if (c.failsFastAtCap) return; // fail-fast has no queueing phase
        final transport = await bindProject();
        final fillers = [for (var i = 0; i < c.cap; i++) c.open(transport, i)];
        for (final f in fillers) {
          unawaited(c.failureCode(f));
        }
        await pump();
        final waiter = c.open(transport, c.cap);
        await pump();
        c.cancel(waiter);
        await pump();
        expect(
          relay.openedStreams,
          hasLength(c.cap),
          reason: 'a cancelled waiter never opens a stream',
        );

        final next = c.open(transport, c.cap + 1);
        await pump();
        relay.openedStreams.first.end();
        await pump();
        expect(
          relay.openedStreams,
          hasLength(c.cap + 1),
          reason: 'the cancelled waiter freed its slot for the next one',
        );

        unawaited(c.failureCode(waiter));
        unawaited(c.failureCode(next));
        for (final s in relay.openedStreams) {
          s.end();
        }
        await pump();
      });

      test('cancel during open resets once it resolves; slot held until '
          'drain', () async {
        final transport = await bindProject();
        final gate = relay.gateOpen();
        final handle = c.open(transport, 0);
        c.cancel(handle);
        gate.complete();
        await pump();
        final opened = relay.openedStreams.single;
        expect(opened.resetCalled, isTrue);
        expect(opened.sent, isEmpty);
        opened.end();
        await pump();
      });

      test('send failure resets and holds the slot until drain', () async {
        final transport = await bindProject();
        final handle = c.open(transport, 0);
        final stream = relay.openedStreams.single;
        if (c.sendsFirstRecord) {
          stream.failNextSend(PeerSendOutcome.backpressured);
        } else {
          stream.sendRawOutcome = PeerSendOutcome.backpressured;
        }
        expect(await c.failureCode(handle), 'SEND_FAILED');
        await pump();
        expect(stream.resetCalled, isTrue);
        expect(stream.finishCalled, isFalse);
        stream.end();
        await pump();
      });

      test('protocol breach resets, fails the kind\'s protocol code, and '
          'holds the slot until the bridge half ends', () async {
        final transport = await bindProject();
        final handles = [for (var i = 0; i < c.cap; i++) c.open(transport, i)];
        final ends = [for (final h in handles) c.failureCode(h)];
        await pump();
        final stream = relay.openedStreams.first;
        injectProtocolBreach(stream, c.kind);
        expect(
          await ends.first,
          c.kind == 'terminal' ? 'INVALID_RECORD' : 'PROTOCOL',
        );
        await pump();
        expect(stream.resetCalled, isTrue);

        final overEnd = c.failureCode(c.open(transport, c.cap));
        await pump();
        if (c.failsFastAtCap) {
          expect(await overEnd, 'CAP_EXCEEDED');
        } else {
          expect(relay.openedStreams, hasLength(c.cap),
              reason: 'the breached stream has not drained yet');
        }
        stream.end();
        await pump();
        if (c.failsFastAtCap) unawaited(c.failureCode(c.open(transport, c.cap + 1)));
        await pump();
        expect(relay.openedStreams, hasLength(c.cap + 1));
        for (final s in relay.openedStreams) {
          s.end();
        }
        await pump();
      });

      if (c.kind == 'terminal') {
        test('a verb whose send is not accepted resets the stream', () async {
          final transport = await bindProject();
          final handle = c.open(transport, 0) as TerminalAttachment;
          await pump();
          final stream = relay.openedStreams.single;
          stream.failNextSend(PeerSendOutcome.backpressured);
          await handle.send({'type': 'terminal:ack', 'sequence': 1});
          await pump();
          expect(stream.resetCalled, isTrue);
          stream.end();
          await pump();
        });
      }

      test('cancel after open ${c.kind == 'terminal' ? 'finishes' : 'resets'} '
          'the stream and holds the slot until the bridge half ends', () async {
        final transport = await bindProject();
        final handles = [for (var i = 0; i < c.cap; i++) c.open(transport, i)];
        await pump();
        for (final h in handles) {
          unawaited(c.failureCode(h));
        }
        final stream = relay.openedStreams.first;
        c.cancel(handles.first);
        await pump();
        if (c.kind == 'terminal') {
          // A local close is graceful: the bridge answers the unsubscribe the
          // caller already sent, so there is nothing in flight to abort.
          expect(stream.finishCalled, isTrue);
          expect(stream.resetCalled, isFalse);
        } else {
          // The reset is the only cancel signal the bridge sees; without it
          // the upstream fetch, socket or upload keeps running.
          expect(stream.resetCalled, isTrue);
        }

        final overEnd = c.failureCode(c.open(transport, c.cap));
        await pump();
        if (c.failsFastAtCap) {
          expect(await overEnd, 'CAP_EXCEEDED');
        } else {
          expect(relay.openedStreams, hasLength(c.cap),
              reason: 'the cancelled stream has not drained yet');
        }
        stream.end();
        await pump();
        if (c.failsFastAtCap) unawaited(c.failureCode(c.open(transport, c.cap + 1)));
        await pump();
        expect(relay.openedStreams, hasLength(c.cap + 1));
        for (final s in relay.openedStreams) {
          s.end();
        }
        await pump();
      });

      test('the peer ending with no data at all delivers the kind\'s own '
          'ended outcome', () async {
        final transport = await bindProject();
        final handle = c.open(transport, 0);
        await pump();
        relay.openedStreams.single.end();
        final expected = c.kind == 'tunnel-tcp'
            ? 'STREAM_LOST'
            : c.kind == 'upload'
            ? 'STREAM_ENDED'
            : null;
        expect(await c.failureCode(handle), expected);
      });

      test('lifecycle taps tag every step streamKind:<kind>', () async {
        final captured = <Map<String, Object?>>[];
        relay = FakeLiveRelay(netTap: captured.add);
        final transport = await bindProject();
        captured.clear(); // binding traffic is not what is under test

        final gate = relay.gateOpen();
        final handle = c.open(transport, 0);
        c.cancel(handle);
        gate.complete();
        await pump();

        bool has(String reason) => captured.any(
          (e) => e['kind'] == 'lifecycle' && e['streamKind'] == c.kind && e['reason'] == reason,
        );
        expect(has('stream-open'), isTrue);
        expect(has('stream-reset'), isTrue);

        relay.openedStreams.single.end();
        await pump();
        expect(has('stream-ended'), isTrue);
      });

      if (!c.failsFastAtCap) {
        test('transport dispose fails a waiting exchange with '
            'TRANSPORT_CLOSED', () async {
          final transport = await bindProject();
          final fillers = [for (var i = 0; i < c.cap; i++) c.open(transport, i)];
          await pump();
          final waiter = c.open(transport, c.cap);
          await pump();
          for (final f in fillers) {
            unawaited(c.failureCode(f));
          }
          final failure = c.failureCode(waiter);
          await session.dispose();
          expect(await failure, 'TRANSPORT_CLOSED');
        });
      }
    });
  }

  // The project stream's bind machinery is unchanged (frozen), but the same
  // admission rules apply to it — these five replace what used to be direct
  // rows in machine_session_project_stream_test.dart.
  group('project (P)', () {
    void injectReadyNotice(String projectId) => relay.injectRecord(
      encodeFromAgent(jsonEncode({'type': 'stream-ready', 'projectId': projectId})),
    );

    void rejectStart(String projectId) => relay.injectRecord(
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

    Future<void> establishReady(String projectId) async {
      session = await establishSession(relay, handshaker: FakeHandshaker());
      injectReadyNotice(projectId);
      await pump();
    }

    test('open frame fields', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await pump();
      expect(relay.openedStreams.single.open, const ProjectStreamOpen('proj-a'));
      expect(
        relay.openedStreams.single.maxRecordBytes,
        kStreamProjectBridgeRecordMaxBytes,
      );
      relay.openedStreams.single.injectStreamReady('proj-a');
      expect((await opening).isProjectBound, isTrue);
    });

    test('the (cap+1)th distinct project fails synchronously, before any '
        'stream opens', () async {
      session = await establishSession(relay, handshaker: FakeHandshaker());
      final fillers = [
        for (var i = 0; i < kStreamMaxProjectsPerPeer; i++)
          session.openProject('proj-$i', {
            'type': 'project:start',
            'projectId': 'proj-$i',
          }),
      ];
      await pump();
      await expectLater(
        session.openProject('proj-overflow', {
          'type': 'project:start',
          'projectId': 'proj-overflow',
        }),
        throwsA(isA<ProjectBindException>().having((e) => e.code, 'code', 'CAP_EXCEEDED')),
      );
      expect(relay.openedStreams, isEmpty);
      final settled = [
        for (final f in fillers) expectLater(f, throwsA(isA<ProjectBindException>())),
      ];
      for (var i = 0; i < kStreamMaxProjectsPerPeer; i++) {
        rejectStart('proj-$i');
      }
      await Future.wait(settled);
    });

    test('a NOT_READY refusal is retried once, then fails if refused again',
        () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await pump();
      relay.openedStreams[0].injectRefusal(StreamRefusedCode.notReady);
      await pump();
      expect(
        relay.openedStreams,
        hasLength(1),
        reason: 'the retry waits for a fresh ready notice before reopening',
      );
      injectReadyNotice('proj-a');
      await pump();
      expect(
        relay.openedStreams,
        hasLength(2),
        reason: 'Dart cannot read a QUIC reset code, so the retry opens a '
            'brand new stream',
      );
      relay.openedStreams[1].injectRefusal(StreamRefusedCode.notReady);
      await expectLater(
        opening,
        throwsA(isA<ProjectBindException>().having((e) => e.code, 'code', 'NOT_READY')),
      );
      expect(relay.openedStreams, hasLength(2), reason: 'one retry only');
    });

    test("a stream-ready on the retry's stream still binds", () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await pump();
      relay.openedStreams[0].injectRefusal(StreamRefusedCode.notReady);
      await pump();
      injectReadyNotice('proj-a');
      await pump();
      relay.openedStreams[1].injectStreamReady('proj-a');
      expect((await opening).isProjectBound, isTrue);
    });

    test('a non-notReady refusal fails at once, with no retry', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await pump();
      relay.openedStreams.single.injectRefusal(
        StreamRefusedCode.notAllowed,
        'phone not allowlisted',
      );
      await expectLater(
        opening,
        throwsA(isA<ProjectBindException>().having((e) => e.code, 'code', 'NOT_ALLOWED')),
      );
      await pump();
      expect(relay.openedStreams, hasLength(1));
    });

    test('a protocol-violating first record resets the stream and fails '
        'INVALID_RECORD', () async {
      await establishReady('proj-a');
      final opening = session.openProject('proj-a', {
        'type': 'project:start',
        'projectId': 'proj-a',
      });
      await pump();
      final stream = relay.openedStreams.single;
      stream.injectJson({'type': 'terminal:frame', 'seq': 1});
      await expectLater(
        opening,
        throwsA(isA<ProjectBindException>().having((e) => e.code, 'code', 'INVALID_RECORD')),
      );
      await pump();
      expect(stream.resetCalled, isTrue);
    });
  });
}
