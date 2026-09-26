// Coverage for `_StreamUploadExchange` (the native-stream path in
// `machine_session.dart`) plus the socket-path NOT_SUPPORTED fallback. The
// fake `MultiStreamPeerLink` below is written fresh for this file rather than
// shared with `tunnel_stream_test.dart` — the two suites drift independently
// on purpose.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

/// A capture that just collects, standing in for `app/lib/util/netwatch.dart`.
class _Capture {
  final events = <Map<String, Object?>>[];
  PeerLinkDiagnostic get tap => events.add;

  bool has(String streamKind, String streamId, String reason) => events.any(
    (e) =>
        e['kind'] == 'lifecycle' &&
        e['streamKind'] == streamKind &&
        e['streamId'] == streamId &&
        e['reason'] == reason,
  );
}

void main() {
  group('_StreamUploadExchange (native-stream path)', () {
    late _FakeMultiStreamLink link;
    late _Capture capture;
    late MachineSession session;

    setUp(() {
      capture = _Capture();
      link = _FakeMultiStreamLink(netTap: capture.tap);
    });

    tearDown(() async {
      // Every created stream still holding a result timer must see its
      // records end, or that real 30-second Timer keeps the test process
      // alive well past this file's own assertions.
      for (final s in link.createdStreams) {
        unawaited(s.endPeer());
      }
      await pumpEventQueue();
      await session.dispose();
    });

    // See tunnel_stream_test.dart's `bind()` for why the link's tracking is
    // cleared before returning: binding is itself a native stream open this
    // test is not exercising.
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
      final transport = await opening;
      link.opens.clear();
      link.createdStreams.clear();
      capture.events.clear(); // binding traffic is not what is under test
      return transport;
    }

    UploadExchange openExchange(
      StreamTransport transport, {
      String requestId = 'r1',
      Uint8List? bytes,
    }) => transport.openUpload(
      requestId: requestId,
      projectId: 'proj-a',
      checkoutId: 'main',
      fileName: 'hi.bin',
      bytes: bytes ?? Uint8List.fromList([1, 2, 3]),
    );

    test(
      'progress advances only once a slice write actually resolves, never '
      'while it is still in flight',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final big = Uint8List(kUploadStreamSliceBytes + 100);
        final gate = Completer<void>();
        link.onOpen = (_) => _FakeStream()..gateFirstSendRaw = gate;
        final progress = <List<int>>[];
        final exchange = transport.openUpload(
          requestId: 'r-progress',
          projectId: 'proj-a',
          checkoutId: 'main',
          fileName: 'hi.bin',
          bytes: big,
          onProgress: (s, t) => progress.add([s, t]),
        );
        await pumpEventQueue();

        expect(progress, isEmpty, reason: 'the first slice write is still gated');
        final fakeStream = link.createdStreams.single;
        expect(
          fakeStream.sentRaw,
          hasLength(1),
          reason: 'the write was attempted, just not yet resolved',
        );

        gate.complete();
        await pumpEventQueue();

        expect(progress, [
          [kUploadStreamSliceBytes, big.length],
          [big.length, big.length],
        ]);
        expect(fakeStream.finishCalled, isTrue);

        fakeStream.emit({
          'type': 'file:upload-result',
          'requestId': 'r-progress',
          'ok': true,
          'path': '/abs/hi.bin',
        });
        final result = await exchange.result;
        expect(result.ok, isTrue);
      },
    );

    test(
      'a refusal as the first record fails REFUSED and finishes the stream',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        const refusal = StreamRefused(
          code: StreamRefusedCode.capExceeded,
          message: 'too many uploads',
        );
        fakeStream.emit(refusal.toJson());

        await expectLater(
          exchange.result,
          throwsA(
            isA<UploadFailure>()
                .having((e) => e.code, 'code', 'REFUSED')
                .having(
                  (e) => e.refusedCode,
                  'refusedCode',
                  StreamRefusedCode.capExceeded,
                ),
          ),
        );
        expect(fakeStream.finishCalled, isTrue);
      },
    );

    test(
      'cancel() resets the send half and fails CANCELLED, holding the slot '
      'until records drain',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport, requestId: 'r1');
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        for (var i = 0; i < kStreamMaxUploadStreamsPerPeer - 1; i++) {
          openExchange(transport, requestId: 'fill-$i');
        }
        expect(link.opens, hasLength(kStreamMaxUploadStreamsPerPeer));

        openExchange(transport, requestId: 'waiter');
        await pumpEventQueue();
        expect(
          link.opens,
          hasLength(kStreamMaxUploadStreamsPerPeer),
          reason: 'the upload past the cap must wait for a slot',
        );

        exchange.cancel();
        await pumpEventQueue();

        expect(fakeStream.resetCalled, isTrue);
        expect(
          link.opens,
          hasLength(kStreamMaxUploadStreamsPerPeer),
          reason: 'the bridge still counts the stream until it answers',
        );

        await fakeStream.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxUploadStreamsPerPeer + 1));
        await expectLater(
          exchange.result,
          throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'CANCELLED')),
        );
      },
    );

    test(
      'a result record arriving before every slice is sent completes result '
      'at once and stops the send loop before it ever calls finish()',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final gate = Completer<void>();
        link.onOpen = (_) => _FakeStream()..gateFirstSendRawAt = 1;
        final bytes = Uint8List(kUploadStreamSliceBytes * 2 + 50);
        final exchange = openExchange(transport, bytes: bytes);
        final fakeStream = link.createdStreams.single;
        fakeStream.gate = gate;
        await pumpEventQueue();

        // The first slice went out and resolved; the second is now in
        // flight, gated. A result arriving in that window must win the race.
        expect(fakeStream.sentRaw, hasLength(2));
        fakeStream.emit({
          'type': 'file:upload-result',
          'requestId': 'r1',
          'ok': true,
          'path': '/abs/hi.bin',
        });
        await pumpEventQueue();
        gate.complete();
        await pumpEventQueue();

        final result = await exchange.result;
        expect(result.ok, isTrue);
        // Never a third slice, and never finish() — the exchange already
        // ended once the result landed, and the unfinished send half is
        // reset rather than left to FIN as if the body were complete.
        expect(fakeStream.sentRaw, hasLength(2));
        expect(fakeStream.finishCalled, isFalse);
        expect(fakeStream.resetCalled, isTrue);
      },
    );

    test(
      'a slice write that throws after the result already settled the '
      'exchange still resets the unfinished send half',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final gate = Completer<void>();
        link.onOpen = (_) => _FakeStream()
          ..gateFirstSendRawAt = 1
          ..throwAfterGate = true;
        final bytes = Uint8List(kUploadStreamSliceBytes * 2 + 50);
        final exchange = openExchange(transport, bytes: bytes);
        final fakeStream = link.createdStreams.single;
        fakeStream.gate = gate;
        await pumpEventQueue();

        fakeStream.emit({
          'type': 'file:upload-result',
          'requestId': 'r1',
          'ok': false,
          'error': 'TOO_LARGE',
        });
        await pumpEventQueue();
        gate.complete();
        await pumpEventQueue();

        final result = await exchange.result;
        expect(result.ok, isFalse);
        expect(fakeStream.finishCalled, isFalse);
        expect(
          fakeStream.resetCalled,
          isTrue,
          reason: 'a send half dropped mid-body must never read as a FIN',
        );
      },
    );

    test('the stream ending with no result fails STREAM_ENDED', () async {
      final transport = await bind(projectId: 'proj-a');
      final exchange = openExchange(transport, bytes: Uint8List.fromList([1]));
      final fakeStream = link.createdStreams.single;
      await pumpEventQueue();

      expect(fakeStream.finishCalled, isTrue);
      await fakeStream.endPeer();

      await expectLater(
        exchange.result,
        throwsA(
          isA<UploadFailure>().having((e) => e.code, 'code', 'STREAM_ENDED'),
        ),
      );
    });

    test(
      'the 5th concurrent upload waits for a slot and opens once one is '
      'released by a clean end',
      () async {
        final transport = await bind(projectId: 'proj-a');
        for (var i = 0; i < kStreamMaxUploadStreamsPerPeer; i++) {
          openExchange(transport, requestId: 'r$i');
        }
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxUploadStreamsPerPeer));

        openExchange(transport, requestId: 'r-wait');
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxUploadStreamsPerPeer));

        final firstStream = link.createdStreams.first;
        await firstStream.endPeer();
        await pumpEventQueue();

        expect(link.opens, hasLength(kStreamMaxUploadStreamsPerPeer + 1));
      },
    );

    test('lifecycle tap events tag every step streamKind:upload, '
        'streamId: requestId', () async {
      final transport = await bind(projectId: 'proj-a');
      final exchange = openExchange(transport, requestId: 'r9');
      final fakeStream = link.createdStreams.single;
      await pumpEventQueue();

      expect(capture.has('upload', 'r9', 'stream-open'), isTrue);

      exchange.cancel();
      await pumpEventQueue();
      expect(capture.has('upload', 'r9', 'stream-reset'), isTrue);

      await fakeStream.endPeer();
      await pumpEventQueue();
      expect(capture.has('upload', 'r9', 'stream-ended'), isTrue);

      await expectLater(
        exchange.result,
        throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'CANCELLED')),
      );
    });
  });

  group('StreamTransport.openUpload over a non-multi-stream link', () {
    test('falls back to NOT_SUPPORTED', () async {
      // Mirrors tunnel_stream_test.dart: since A4 a project's own transport
      // only ever exists over a MultiStreamPeerLink, so the only reachable
      // non-multi-stream transport left is session.control.
      final link = _PlainPeerLink();
      final session = MachineSession(
        relay: link,
        machineDeviceId: 'm1',
        handshaker: FakeHandshaker(),
      );
      session.start();
      await session.ensureEstablished();
      addTearDown(() async {
        await session.dispose();
      });

      final transport = session.control;
      final exchange = transport.openUpload(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.bin',
        bytes: Uint8List.fromList([1]),
      );
      await expectLater(
        exchange.result,
        throwsA(
          isA<UploadFailure>().having((e) => e.code, 'code', 'NOT_SUPPORTED'),
        ),
      );
    });
  });
}

Future<void> pumpEventQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

/// A [PeerLink] that does NOT also implement [MultiStreamPeerLink] — see
/// `tunnel_stream_test.dart`'s identical fixture.
class _PlainPeerLink implements PeerLink {
  final _messages = StreamController<IncomingSessionRecord>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _failures = StreamController<PeerLinkFailure>.broadcast();

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
}

class _FakeMultiStreamLink implements PeerLink, MultiStreamPeerLink {
  _FakeMultiStreamLink({PeerLinkDiagnostic? netTap}) : _netTap = netTap;

  final _messages = StreamController<IncomingSessionRecord>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _failures = StreamController<PeerLinkFailure>.broadcast();
  final PeerLinkDiagnostic? _netTap;

  final List<({StreamOpen open, int maxRecordBytes, int maxQueuedBytes})>
  opens = [];
  final List<_FakeStream> createdStreams = [];

  /// Overrides the stream a successful [openStream] returns; defaults to a
  /// fresh [_FakeStream] recorded in [createdStreams].
  _FakeStream Function(StreamOpen open)? onOpen;

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
  PeerLinkDiagnostic? get netTap => _netTap;

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
    final stream = onOpen != null ? onOpen!(open) : _FakeStream();
    createdStreams.add(stream);
    return stream;
  }
}

class _FakeStream implements PeerStream {
  final _records = StreamController<Uint8List>();
  final List<Uint8List> sentRaw = [];
  bool resetCalled = false;
  bool finishCalled = false;
  PeerSendOutcome sendRawOutcome = PeerSendOutcome.accepted;

  /// When set, the FIRST `sendRaw` call awaits this before resolving — models
  /// one write still in flight (backpressure or a slow native binding).
  Completer<void>? gateFirstSendRaw;

  /// When set, the call at this zero-based index (not the first) is the one
  /// that gates on [gate].
  int? gateFirstSendRawAt;
  Completer<void>? gate;

  /// When true, the gated write at [gateFirstSendRawAt] throws once its gate
  /// releases, as a native write does when the peer stopped the stream.
  bool throwAfterGate = false;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    throw UnimplementedError('an upload exchange never writes a framed record');
  }

  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) async {
    final index = sentRaw.length;
    sentRaw.add(bytes);
    if (index == 0 && gateFirstSendRaw != null) {
      await gateFirstSendRaw!.future;
    }
    if (gateFirstSendRawAt != null && index == gateFirstSendRawAt && gate != null) {
      await gate!.future;
      if (throwAfterGate) throw StateError('stream stopped by peer');
    }
    return sendRawOutcome;
  }

  /// Leaves [records] open: a real [PeerStream]'s records end only on the
  /// peer's end, never because this side reset.
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

  Future<void> endPeer() async {
    if (!_records.isClosed) await _records.close();
  }
}
