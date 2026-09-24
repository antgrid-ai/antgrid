// Coverage for `TerminalAttachment` on both paths: the socket-path
// `SocketTerminalAttachments` used by every `BufferedAgentTransport`, and the
// native-stream `_StreamTerminalAttachment` `StreamTransport` opens when its
// session's link is a `MultiStreamPeerLink` (stage-A-A2-contract.md §4.1/§4.3).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  group('SocketTerminalAttachments (socket path)', () {
    test(
      'sends subscribe through send and diverts subscribed, frames, statuses '
      'and pages for its attachment only',
      () async {
        final sent = <Map<String, dynamic>>[];
        final atts = SocketTerminalAttachments((m) async => sent.add(m));

        final a = atts.open(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final b = atts.open(
          requestId: 'r2',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r2'},
        );
        expect(sent, [
          {'type': 'terminal:subscribe', 'requestId': 'r1'},
          {'type': 'terminal:subscribe', 'requestId': 'r2'},
        ]);

        final aMsgs = <Map<String, dynamic>>[];
        final bMsgs = <Map<String, dynamic>>[];
        a.messages.listen(aMsgs.add);
        b.messages.listen(bMsgs.add);

        expect(
          atts.divert({
            'type': 'terminal:subscribed',
            'requestId': 'r1',
            'attachmentId': 'att-1',
          }),
          isTrue,
        );
        expect(
          atts.divert({
            'type': 'terminal:frame',
            'attachmentId': 'att-1',
            'seq': 1,
          }),
          isTrue,
        );
        expect(
          atts.divert({
            'type': 'terminal:history:page',
            'attachmentId': 'att-1',
            'page': 0,
          }),
          isTrue,
        );
        // b's attachmentId never arrived, so a frame naming another
        // attachment reaches neither handle.
        expect(
          atts.divert({'type': 'terminal:frame', 'attachmentId': 'att-2'}),
          isFalse,
        );

        await pumpEventQueue();
        expect(aMsgs, hasLength(3));
        expect(bMsgs, isEmpty);
      },
    );

    test(
      'a requestId-addressed status reaches the attachment before subscribed',
      () async {
        final atts = SocketTerminalAttachments((_) async {});
        final a = atts.open(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final msgs = <Map<String, dynamic>>[];
        a.messages.listen(msgs.add);

        expect(
          atts.divert({
            'type': 'terminal:display:status',
            'requestId': 'r1',
            'status': 'UPGRADE_REQUIRED',
          }),
          isTrue,
        );

        await pumpEventQueue();
        expect(msgs, hasLength(1));
        expect(msgs.single['status'], 'UPGRADE_REQUIRED');
      },
    );

    test('after close() a late reply is not diverted', () async {
      final atts = SocketTerminalAttachments((_) async {});
      final a = atts.open(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      expect(
        atts.divert({
          'type': 'terminal:subscribed',
          'requestId': 'r1',
          'attachmentId': 'att-1',
        }),
        isTrue,
      );
      await a.close();
      expect(await a.done, isA<TerminalAttachmentClosedLocally>());

      // A late frame for the now-forgotten attachmentId reaches nobody.
      expect(
        atts.divert({'type': 'terminal:frame', 'attachmentId': 'att-1'}),
        isFalse,
      );
    });

    test('closeAll ends every open attachment TransportClosed', () async {
      final atts = SocketTerminalAttachments((_) async {});
      final a = atts.open(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final b = atts.open(
        requestId: 'r2',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r2'},
      );
      atts.closeAll();
      expect(await a.done, isA<TerminalAttachmentTransportClosed>());
      expect(await b.done, isA<TerminalAttachmentTransportClosed>());
    });

    test(
      'StreamTransport over a PeerLink that is not multi-stream uses the '
      'socket path',
      () async {
        final relay = FakeLiveRelay();
        final session = await establishSession(
          relay,
          handshaker: FakeHandshaker(),
        );
        addTearDown(() async {
          await session.dispose();
          await relay.closeStreams();
        });

        final transport = session.streamFor('s-p');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {
            'type': 'terminal:subscribe',
            'requestId': 'r1',
            'checkoutId': 'main',
          },
        );
        expect(attachment.isStream, isFalse);

        await pumpEventQueue();
        final envelopes = relay.sent
            .map((f) => jsonDecode(decodeFromPhone(f.payload)) as Map)
            .toList();
        expect(
          envelopes.any(
            (e) =>
                e['s'] == 's-p' &&
                (e['m'] as Map)['type'] == 'terminal:subscribe' &&
                (e['m'] as Map)['requestId'] == 'r1',
          ),
          isTrue,
          reason: 'the socket path sends subscribe over the ordinary stream',
        );
      },
    );
  });

  group('_StreamTerminalAttachment (native-stream path)', () {
    late _FakeMultiStreamLink link;
    late MachineSession session;

    setUp(() {
      link = _FakeMultiStreamLink();
    });

    tearDown(() async {
      await session.dispose();
    });

    Future<StreamTransport> bind({
      required String projectId,
      required String streamId,
    }) async {
      session = MachineSession(
        relay: link,
        machineDeviceId: 'm1',
        handshaker: FakeHandshaker(),
      );
      session.start();
      await session.ensureEstablished();
      link.inject(
        IncomingPeerFrame(
          channel: 'control',
          payload: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'm': {
                  'type': 'stream-ready',
                  'projectId': projectId,
                  'streamId': streamId,
                },
              }),
            ),
          ),
        ),
      );
      await pumpEventQueue();
      return session.streamFor(streamId);
    }

    test(
      "opens TerminalStreamOpen with the session's projectId and sends "
      'subscribe as the first record',
      () async {
        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        final subscribe = {
          'type': 'terminal:subscribe',
          'requestId': 'r1',
          'checkoutId': 'main',
        };
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: subscribe,
        );
        expect(attachment.isStream, isTrue);

        expect(link.opens, hasLength(1));
        expect(
          link.opens.single.open,
          const TerminalStreamOpen(
            projectId: 'proj-a',
            requestId: 'r1',
            checkoutId: 'main',
          ),
        );
        expect(link.opens.single.maxRecordBytes, kStreamTerminalBridgeRecordMaxBytes);
        expect(link.opens.single.maxQueuedBytes, kTerminalAttachmentMaxQueuedBytes);

        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();
        expect(fakeStream.sent, hasLength(1));
        expect(jsonDecode(utf8.decode(fakeStream.sent.single)), subscribe);
      },
    );

    test('records arrive on messages in record order (hazards A and B)', () async {
      final transport = await bind(projectId: 'proj-a', streamId: 's-term');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.single;
      fakeStream.emit({
        'type': 'terminal:subscribed',
        'requestId': 'r1',
        'attachmentId': 'att-1',
      });
      fakeStream.emit({
        'type': 'terminal:frame',
        'attachmentId': 'att-1',
        'seq': 1,
      });
      fakeStream.emit({
        'type': 'terminal:frame',
        'attachmentId': 'att-1',
        'seq': 2,
      });

      final received = await attachment.messages.take(3).toList();
      expect(received[0]['type'], 'terminal:subscribed');
      expect(received[1]['seq'], 1);
      expect(received[2]['seq'], 2);
    });

    test('a stream:refused first record ends Refused', () async {
      final transport = await bind(projectId: 'proj-a', streamId: 's-term');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.single;
      const refusal = StreamRefused(
        code: StreamRefusedCode.notReady,
        message: 'project core not started',
      );
      fakeStream.emit(refusal.toJson());

      final end = await attachment.done;
      expect(end, isA<TerminalAttachmentRefused>());
      expect((end as TerminalAttachmentRefused).refusal, refusal);
      expect(fakeStream.finishCalled, isTrue);
    });

    test(
      'bridge FIN ends PeerEnded, finishes the send half and releases the '
      'slot',
      () async {
        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.single;
        fakeStream.emit({'type': 'terminal:subscribed', 'requestId': 'r1'});
        await pumpEventQueue();
        await fakeStream.endPeer();

        final end = await attachment.done;
        expect(end, isA<TerminalAttachmentPeerEnded>());
        expect(fakeStream.finishCalled, isTrue);

        // The slot the ended attachment held must be reclaimed: a fresh
        // batch of kStreamMaxTerminalAttachmentsPerPeer opens must all
        // succeed in taking a slot (none locally fail CAP_EXCEEDED).
        final fresh = <TerminalAttachment>[];
        for (var i = 0; i < kStreamMaxTerminalAttachmentsPerPeer; i++) {
          fresh.add(
            transport.openTerminalAttachment(
              requestId: 'fresh-$i',
              checkoutId: 'main',
              subscribe: {'type': 'terminal:subscribe', 'requestId': 'fresh-$i'},
            ),
          );
        }
        expect(link.opens, hasLength(1 + kStreamMaxTerminalAttachmentsPerPeer));
      },
    );

    test('close() finishes the send half and ends ClosedLocally', () async {
      final transport = await bind(projectId: 'proj-a', streamId: 's-term');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.single;
      fakeStream.emit({'type': 'terminal:subscribed', 'requestId': 'r1'});
      await pumpEventQueue();

      final delivered = <Map<String, dynamic>>[];
      attachment.messages.listen(delivered.add);
      await pumpEventQueue();

      await attachment.close();
      expect(await attachment.done, isA<TerminalAttachmentClosedLocally>());
      expect(fakeStream.finishCalled, isTrue);

      // Draining continues after close, but nothing more is delivered.
      fakeStream.emit({'type': 'terminal:frame', 'attachmentId': 'att-1'});
      await fakeStream.endPeer();
      await pumpEventQueue();
      expect(delivered, hasLength(1));
      expect(delivered.single['type'], 'terminal:subscribed');
    });

    test(
      'an openStream throw ends Failed(STREAM_OPEN_FAILED) and never '
      'reaches failureStream (carry-over 4)',
      () async {
        final failures = <PeerLinkFailure>[];
        link.failureStream.listen(failures.add);
        final boom = Exception('boom');
        link.openError = boom;

        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final end = await attachment.done;
        expect(end, isA<TerminalAttachmentFailed>());
        final failed = end as TerminalAttachmentFailed;
        expect(failed.code, 'STREAM_OPEN_FAILED');
        expect(failed.error, boom);

        await pumpEventQueue();
        expect(failures, isEmpty);
      },
    );

    test(
      'the 65th concurrent attachment ends Failed(CAP_EXCEEDED) without '
      'opening',
      () async {
        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        for (var i = 0; i < kStreamMaxTerminalAttachmentsPerPeer; i++) {
          transport.openTerminalAttachment(
            requestId: 'r$i',
            checkoutId: 'main',
            subscribe: {'type': 'terminal:subscribe', 'requestId': 'r$i'},
          );
        }
        expect(link.opens, hasLength(kStreamMaxTerminalAttachmentsPerPeer));

        final overflow = transport.openTerminalAttachment(
          requestId: 'r-overflow',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r-overflow'},
        );
        // Never opened: the cap check runs before the async open.
        expect(link.opens, hasLength(kStreamMaxTerminalAttachmentsPerPeer));

        final end = await overflow.done;
        expect(end, isA<TerminalAttachmentFailed>());
        expect((end as TerminalAttachmentFailed).code, 'CAP_EXCEEDED');
      },
    );

    test('a send outcome other than accepted resets the stream', () async {
      link.onOpen = (_) => _FakeStream()..sendOutcome = PeerSendOutcome.backpressured;
      final transport = await bind(projectId: 'proj-a', streamId: 's-term');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final end = await attachment.done;
      expect(end, isA<TerminalAttachmentFailed>());
      expect((end as TerminalAttachmentFailed).code, 'SEND_FAILED');
      expect(link.createdStreams.single.resetCalled, isTrue);
    });

    test(
      'close() while the open is in flight resets the stream once it '
      'resolves, never sends subscribe, and releases the slot',
      () async {
        link.openGate = Completer<void>();
        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        await pumpEventQueue();
        await attachment.close();
        link.openGate!.complete();
        link.openGate = null;

        expect(await attachment.done, isA<TerminalAttachmentClosedLocally>());
        final fakeStream = link.createdStreams.single;
        expect(fakeStream.resetCalled, isTrue);
        expect(fakeStream.finishCalled, isFalse);
        expect(fakeStream.sent, isEmpty);

        for (var i = 0; i < kStreamMaxTerminalAttachmentsPerPeer; i++) {
          transport.openTerminalAttachment(
            requestId: 'fresh-$i',
            checkoutId: 'main',
            subscribe: {'type': 'terminal:subscribe', 'requestId': 'fresh-$i'},
          );
        }
        expect(link.opens, hasLength(1 + kStreamMaxTerminalAttachmentsPerPeer));
      },
    );

    test(
      'a record that is not a JSON map resets the stream and ends '
      'Failed(INVALID_RECORD)',
      () async {
        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.single;
        fakeStream.emit({'type': 'terminal:subscribed', 'requestId': 'r1'});
        fakeStream.emitRaw(utf8.encode('[1, 2, 3]'));

        final end = await attachment.done;
        expect(end, isA<TerminalAttachmentFailed>());
        expect((end as TerminalAttachmentFailed).code, 'INVALID_RECORD');
        expect(fakeStream.resetCalled, isTrue);
      },
    );

    test(
      'a verb whose send outcome is not accepted resets the stream',
      () async {
        final transport = await bind(projectId: 'proj-a', streamId: 's-term');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();
        expect(fakeStream.sent, hasLength(1));
        fakeStream.sendOutcome = PeerSendOutcome.backpressured;

        await attachment.send({'type': 'terminal:ack', 'sequence': 1});
        expect(fakeStream.resetCalled, isTrue);
      },
    );

    test('an unknown projectId for the stream ends Failed(NO_PROJECT)', () async {
      session = MachineSession(
        relay: link,
        machineDeviceId: 'm1',
        handshaker: FakeHandshaker(),
      );
      session.start();
      await session.ensureEstablished();
      // No stream-ready was ever injected for 's-unbound'.
      final transport = session.streamFor('s-unbound');

      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final end = await attachment.done;
      expect(end, isA<TerminalAttachmentFailed>());
      expect((end as TerminalAttachmentFailed).code, 'NO_PROJECT');
      expect(link.opens, isEmpty);
    });
  });
}

/// Lets an unawaited async chain (every `_StreamTerminalAttachment._start()`
/// call, `openTerminalAttachment`'s contract, `MachineSession`'s send
/// scheduler drain loop) settle before the next assertion. A real duration,
/// not `Duration.zero`: the scheduler's drain isn't a fixed number of
/// microtasks away.
Future<void> pumpEventQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

class _FakeMultiStreamLink implements PeerLink, MultiStreamPeerLink {
  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _failures = StreamController<PeerLinkFailure>.broadcast();

  final List<
    ({StreamOpen open, int maxRecordBytes, int maxQueuedBytes})
  >
  opens = [];
  final List<_FakeStream> createdStreams = [];

  /// Overrides the stream a successful [openStream] returns; defaults to a
  /// fresh [_FakeStream] recorded in [createdStreams].
  _FakeStream Function(StreamOpen open)? onOpen;

  /// When set, [openStream] throws this instead of returning.
  Object? openError;

  /// When set, [openStream] waits on it before resolving.
  Completer<void>? openGate;

  @override
  bool get isDispatchAllowed => true;

  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => _failures.stream;
  @override
  PeerLinkDiagnostic? get netTap => null;

  @override
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async =>
      PeerSendOutcome.accepted;

  @override
  Future<void> close() async {}

  void inject(IncomingPeerFrame frame) => _messages.add(frame);

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
  }) async {
    opens.add((
      open: open,
      maxRecordBytes: maxRecordBytes,
      maxQueuedBytes: maxQueuedBytes,
    ));
    final gate = openGate;
    if (gate != null) await gate.future;
    final err = openError;
    if (err != null) throw err;
    final stream = onOpen != null ? onOpen!(open) : _FakeStream();
    createdStreams.add(stream);
    return stream;
  }
}

class _FakeStream implements PeerStream {
  final _records = StreamController<Uint8List>();
  final List<Uint8List> sent = [];
  bool resetCalled = false;
  bool finishCalled = false;
  PeerSendOutcome sendOutcome = PeerSendOutcome.accepted;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    sent.add(record);
    return sendOutcome;
  }

  @override
  Future<void> reset() async {
    resetCalled = true;
    if (!_records.isClosed) await _records.close();
  }

  @override
  Future<void> finish() async {
    finishCalled = true;
  }

  void emit(Map<String, dynamic> json) {
    if (_records.isClosed) return;
    _records.add(Uint8List.fromList(utf8.encode(jsonEncode(json))));
  }

  void emitRaw(List<int> bytes) {
    if (_records.isClosed) return;
    _records.add(Uint8List.fromList(bytes));
  }

  Future<void> endPeer() async {
    if (!_records.isClosed) await _records.close();
  }
}
