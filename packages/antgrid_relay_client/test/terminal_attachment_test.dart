// Coverage for `TerminalAttachment` on both paths: the socket-path
// `SocketTerminalAttachments` used by every `BufferedAgentTransport`, and the
// native-stream `_StreamTerminalAttachment` every `StreamTransport` opens
// (stage-A-A2-contract.md §4.1/§4.3).
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

    // Binds `projectId` over its own native stream (Stage A A4: the identity
    // of a project's stream IS the project, so binding requires an actual
    // `openStream` round trip — the ready notice on the control plane, then
    // the bridge's `stream-ready` as the new stream's first record — rather
    // than the old direct `streamFor(streamId)` lookup.
    Future<StreamTransport> bind({required String projectId}) async {
      session = MachineSession(
        relay: link,
        machineDeviceId: 'm1',
        handshaker: FakeHandshaker(),
      );
      session.start();
      await session.ensureEstablished();
      final opening = session.openProject(projectId, {
        'type': 'project:start',
        'projectId': projectId,
      });
      await pumpEventQueue();
      link.inject(
        IncomingSessionRecord(
          payload: Uint8List.fromList(
            utf8.encode(
              jsonEncode({'type': 'stream-ready', 'projectId': projectId}),
            ),
          ),
        ),
      );
      await pumpEventQueue();
      link.createdStreams.last.emit({
        'type': 'stream-ready',
        'projectId': projectId,
      });
      return opening;
    }

    test(
      "opens TerminalStreamOpen with the session's projectId and sends "
      'subscribe as the first record',
      () async {
        final transport = await bind(projectId: 'proj-a');
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

        // link.opens[0] is the project's own bind stream opened by `bind()`.
        expect(link.opens, hasLength(2));
        expect(
          link.opens.last.open,
          const TerminalStreamOpen(
            projectId: 'proj-a',
            requestId: 'r1',
            checkoutId: 'main',
          ),
        );
        expect(link.opens.last.maxRecordBytes, kStreamTerminalBridgeRecordMaxBytes);
        expect(link.opens.last.maxQueuedBytes, kTerminalAttachmentMaxQueuedBytes);

        final fakeStream = link.createdStreams.last;
        await pumpEventQueue();
        expect(fakeStream.sent, hasLength(1));
        expect(jsonDecode(utf8.decode(fakeStream.sent.single)), subscribe);
      },
    );

    test('records arrive on messages in record order (hazards A and B)', () async {
      final transport = await bind(projectId: 'proj-a');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.last;
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
      final transport = await bind(projectId: 'proj-a');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.last;
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
        final transport = await bind(projectId: 'proj-a');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.last;
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
        // link.opens[0] is the project's own bind stream opened by `bind()`.
        expect(link.opens, hasLength(2 + kStreamMaxTerminalAttachmentsPerPeer));
      },
    );

    test('close() finishes the send half and ends ClosedLocally', () async {
      final transport = await bind(projectId: 'proj-a');
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final fakeStream = link.createdStreams.last;
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

        final transport = await bind(projectId: 'proj-a');
        // Set only after the bind's own stream is up — an error here must
        // fail this attachment's open alone, not the project bind itself.
        final boom = Exception('boom');
        link.openError = boom;
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
        final transport = await bind(projectId: 'proj-a');
        for (var i = 0; i < kStreamMaxTerminalAttachmentsPerPeer; i++) {
          transport.openTerminalAttachment(
            requestId: 'r$i',
            checkoutId: 'main',
            subscribe: {'type': 'terminal:subscribe', 'requestId': 'r$i'},
          );
        }
        // link.opens[0] is the project's own bind stream opened by `bind()`.
        expect(link.opens, hasLength(1 + kStreamMaxTerminalAttachmentsPerPeer));

        final overflow = transport.openTerminalAttachment(
          requestId: 'r-overflow',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r-overflow'},
        );
        // Never opened: the cap check runs before the async open.
        expect(link.opens, hasLength(1 + kStreamMaxTerminalAttachmentsPerPeer));

        final end = await overflow.done;
        expect(end, isA<TerminalAttachmentFailed>());
        expect((end as TerminalAttachmentFailed).code, 'CAP_EXCEEDED');
      },
    );

    test('a send outcome other than accepted resets the stream', () async {
      final transport = await bind(projectId: 'proj-a');
      link.onOpen = (_) => _FakeStream()..sendOutcome = PeerSendOutcome.backpressured;
      final attachment = transport.openTerminalAttachment(
        requestId: 'r1',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
      );
      final end = await attachment.done;
      expect(end, isA<TerminalAttachmentFailed>());
      expect((end as TerminalAttachmentFailed).code, 'SEND_FAILED');
      expect(link.createdStreams.last.resetCalled, isTrue);
    });

    // Opens [count] fresh attachments and returns the one after them, which
    // is the probe: it fails CAP_EXCEEDED iff every slot is still taken.
    Future<TerminalAttachmentEnd?> probeAfter(
      StreamTransport transport,
      int count,
      String tag,
    ) async {
      for (var i = 0; i < count; i++) {
        transport.openTerminalAttachment(
          requestId: '$tag-$i',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': '$tag-$i'},
        );
      }
      final probe = transport.openTerminalAttachment(
        requestId: '$tag-probe',
        checkoutId: 'main',
        subscribe: {'type': 'terminal:subscribe', 'requestId': '$tag-probe'},
      );
      await pumpEventQueue();
      TerminalAttachmentEnd? end;
      unawaited(probe.done.then((e) => end = e));
      await pumpEventQueue();
      return end;
    }

    test(
      'close() while the open is in flight resets the stream once it '
      'resolves, never sends subscribe, and holds the slot until the '
      "bridge's half ends (carry-over 1)",
      () async {
        final transport = await bind(projectId: 'proj-a');
        link.openGate = Completer<void>();
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
        final fakeStream = link.createdStreams.last;
        expect(fakeStream.resetCalled, isTrue);
        expect(fakeStream.finishCalled, isFalse);
        expect(fakeStream.sent, isEmpty);

        // The reset stream still holds one slot: 63 more fill the cap.
        final held = await probeAfter(
          transport,
          kStreamMaxTerminalAttachmentsPerPeer - 1,
          'held',
        );
        expect(held, isA<TerminalAttachmentFailed>());
        expect((held as TerminalAttachmentFailed).code, 'CAP_EXCEEDED');

        await fakeStream.endPeer();
        await pumpEventQueue();
        final freed = await probeAfter(transport, 0, 'freed');
        expect(freed, isNull); // took the freed slot and is still open
      },
    );

    test(
      "a failed subscribe send holds the slot until the bridge's half ends "
      '(carry-over 1)',
      () async {
        final transport = await bind(projectId: 'proj-a');
        link.onOpen = (_) => _FakeStream()..sendOutcome = PeerSendOutcome.closed;
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final end = await attachment.done;
        expect((end as TerminalAttachmentFailed).code, 'SEND_FAILED');
        final failedStream = link.createdStreams.last;
        expect(failedStream.resetCalled, isTrue);
        link.onOpen = null;

        final held = await probeAfter(
          transport,
          kStreamMaxTerminalAttachmentsPerPeer - 1,
          'held',
        );
        expect(held, isA<TerminalAttachmentFailed>());
        expect((held as TerminalAttachmentFailed).code, 'CAP_EXCEEDED');

        await failedStream.endPeer();
        await pumpEventQueue();
        final freed = await probeAfter(transport, 0, 'freed');
        expect(freed, isNull);
      },
    );

    test(
      'a record that is not a JSON map resets the stream and ends '
      'Failed(INVALID_RECORD)',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.last;
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
        final transport = await bind(projectId: 'proj-a');
        final attachment = transport.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final fakeStream = link.createdStreams.last;
        await pumpEventQueue();
        expect(fakeStream.sent, hasLength(1));
        fakeStream.sendOutcome = PeerSendOutcome.backpressured;

        await attachment.send({'type': 'terminal:ack', 'sequence': 1});
        expect(fakeStream.resetCalled, isTrue);
      },
    );

    test(
      'opening a terminal attachment on the control transport ends '
      'Failed(NO_PROJECT) — since A4 every project-bound StreamTransport '
      'carries its projectId from birth, so only the control-plane '
      'transport (projectId == null) can hit this any more',
      () async {
        session = MachineSession(
          relay: link,
          machineDeviceId: 'm1',
          handshaker: FakeHandshaker(),
        );
        session.start();
        await session.ensureEstablished();

        final attachment = session.control.openTerminalAttachment(
          requestId: 'r1',
          checkoutId: 'main',
          subscribe: {'type': 'terminal:subscribe', 'requestId': 'r1'},
        );
        final end = await attachment.done;
        expect(end, isA<TerminalAttachmentFailed>());
        expect((end as TerminalAttachmentFailed).code, 'NO_PROJECT');
        expect(link.opens, isEmpty);
      },
    );
  });
}

/// Lets an unawaited async chain (every `_StreamTerminalAttachment._start()`
/// call, `openTerminalAttachment`'s contract, `MachineSession`'s send
/// scheduler drain loop) settle before the next assertion. A real duration,
/// not `Duration.zero`: the scheduler's drain isn't a fixed number of
/// microtasks away.
Future<void> pumpEventQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

class _FakeMultiStreamLink implements PeerLink {
  final _messages = StreamController<IncomingSessionRecord>.broadcast();
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
  Stream<IncomingSessionRecord> get messageStream => _messages.stream;
  @override
  Stream<PeerLinkState> get payloadStateStream => _states.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => _failures.stream;
  @override
  PeerLinkDiagnostic? get netTap => null;

  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async =>
      PeerSendOutcome.accepted;

  @override
  Future<void> close() async {}

  void inject(IncomingSessionRecord frame) => _messages.add(frame);

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
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

  /// Terminal attachments never enter the raw read phase, so nothing exercises
  /// this — it exists only to satisfy [PeerStream].
  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) async => sendOutcome;

  /// Resets the send half only, as `NativePeerStream.reset` does: the
  /// records keep flowing until the bridge ends its own half ([endPeer]).
  @override
  Future<void> reset() async {
    resetCalled = true;
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
