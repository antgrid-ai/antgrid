// Coverage for the native-stream tunnel implementations
// (`_StreamTunnelHttpExchange` / `_StreamTunnelWsChannel` in
// `machine_session.dart`) plus the socket-path NOT_SUPPORTED fallback
// (stage-A-A3-contract.md §4). The fake `MultiStreamPeerLink` below is written
// fresh for this file rather than imported from `terminal_attachment_test.dart`
// — the two suites drift independently on purpose.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

void main() {
  group('_StreamTunnelHttpExchange (native-stream path)', () {
    late _FakeMultiStreamLink link;
    late MachineSession session;

    setUp(() {
      link = _FakeMultiStreamLink();
    });

    tearDown(() async {
      await session.dispose();
    });

    // Binds `projectId` over its own native stream (Stage A A4: a stream's
    // identity IS its project, so binding is a real `openStream` round trip
    // — the ready notice on the control plane, then the bridge's
    // `stream-ready` as the new stream's first record) and then clears the
    // link's tracking so every count below reflects only what THIS test
    // drives, exactly as it did when `bind()` was a direct `streamFor`
    // lookup with no native stream of its own.
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
        IncomingPeerFrame(
          kind: kPeerFrameMessage,
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
      return transport;
    }

    TunnelHttpExchange openExchange(
      StreamTransport transport, {
      String requestId = 'r1',
      int bodyLength = 0,
      Stream<List<int>>? body,
    }) => transport.openTunnelHttp(
      requestId: requestId,
      checkoutId: 'main',
      head: {
        'type': 'tunnel:http-request',
        'requestId': requestId,
        'method': 'GET',
        'path': '/',
      },
      bodyLength: bodyLength,
      body: body,
    );

    test('the open head carries bodyLength and checkoutId; the body follows '
        'as raw writes', () async {
      final transport = await bind(projectId: 'proj-a');
      final bytes = Uint8List.fromList(utf8.encode('hello'));
      openExchange(transport, bodyLength: bytes.length, body: Stream.value(bytes));

      expect(link.opens, hasLength(1));
      expect(
        link.opens.single.open,
        const TunnelHttpStreamOpen(projectId: 'proj-a', requestId: 'r1'),
      );
      expect(link.opens.single.maxRecordBytes, kStreamTunnelRecordMaxBytes);
      expect(link.opens.single.maxQueuedBytes, kTunnelStreamMaxQueuedBytes);

      final fakeStream = link.createdStreams.single;
      await pumpEventQueue();
      final headJson = jsonDecode(utf8.decode(fakeStream.sent.single)) as Map;
      expect(headJson['bodyLength'], 5);
      expect(headJson['checkoutId'], 'main');
      expect(utf8.decode(fakeStream.sentRaw.single), 'hello');
    });

    test(
      'a body over the 262144-byte slice ceiling is split into two raw '
      'writes',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final big = Uint8List(262144 + 10);
        openExchange(transport, bodyLength: big.length, body: Stream.value(big));
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        expect(fakeStream.sent, hasLength(1));
        expect(fakeStream.sentRaw, hasLength(2));
        expect(fakeStream.sentRaw[0].length, 262144);
        expect(fakeStream.sentRaw[1].length, 10);
      },
    );

    test(
      'a refusal as the first record fails REFUSED and calls finish()',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        const refusal = StreamRefused(
          code: StreamRefusedCode.notReady,
          message: 'project core not started',
        );
        fakeStream.emit(refusal.toJson());

        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'REFUSED'),
          ),
        );
        expect(fakeStream.finishCalled, isTrue);
      },
    );

    test(
      'head and raw body chunks complete the exchange; finish() waits '
      'for the peer FIN',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        fakeStream.emit({
          'type': 'tunnel:http-head',
          'requestId': 'r1',
          'status': 200,
          'headers': {'content-type': 'text/plain'},
        });
        final head = await exchange.head;
        expect(head.status, 200);
        expect(head.headers['content-type'], 'text/plain');

        final chunks = <int>[];
        final bodyDone = exchange.body.listen(chunks.addAll).asFuture<void>();
        fakeStream.emitRaw(Uint8List.fromList(utf8.encode('abc')));
        await pumpEventQueue();

        // The read loop only calls finish() once the peer's own FIN arrives.
        expect(fakeStream.finishCalled, isFalse);
        await fakeStream.endPeer();
        await bodyDone;

        expect(utf8.decode(chunks), 'abc');
        await pumpEventQueue();
        expect(fakeStream.finishCalled, isTrue);
      },
    );

    test(
      'the stream resetting after a head fails TRUNCATED',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        fakeStream.emit({
          'type': 'tunnel:http-head',
          'requestId': 'r1',
          'status': 200,
          'headers': <String, String>{},
        });
        await exchange.head;

        final bodyError = expectLater(
          exchange.body.toList(),
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'TRUNCATED'),
          ),
        );
        await fakeStream.endWithReset();
        await bodyError;
      },
    );

    test(
      'raw bytes as the first record are PROTOCOL and reset the stream',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        fakeStream.emitRaw(Uint8List.fromList(utf8.encode('early')));

        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'PROTOCOL'),
          ),
        );
        expect(fakeStream.resetCalled, isTrue);
      },
    );

    test(
      'a backpressured head send fails SEND_FAILED, resets, and never '
      'calls finish()',
      () async {
        link.onOpen = (_) =>
            _FakeStream()..sendOutcome = PeerSendOutcome.backpressured;
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);

        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'SEND_FAILED'),
          ),
        );
        final fakeStream = link.createdStreams.single;
        expect(fakeStream.resetCalled, isTrue);
        expect(fakeStream.finishCalled, isFalse);
      },
    );

    test(
      'cancel() after open resets the send half and releases the slot only '
      'once records drain',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++) {
          openExchange(transport, requestId: 'fill-$i');
        }
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        openExchange(transport, requestId: 'waiter');
        await pumpEventQueue();
        expect(
          link.opens,
          hasLength(kStreamMaxTunnelStreamsPerPeer),
          reason: 'the 129th open must wait for a slot',
        );

        exchange.cancel();
        await pumpEventQueue();

        expect(fakeStream.resetCalled, isTrue);
        expect(
          link.opens,
          hasLength(kStreamMaxTunnelStreamsPerPeer),
          reason: 'the bridge still counts the stream until it answers',
        );

        await fakeStream.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having(
              (e) => e.code,
              'code',
              'CANCELLED',
            ),
          ),
        );
      },
    );

    test(
      'cancel() while the open is in flight resets once it resolves and '
      'holds the slot until records drain',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final gate = Completer<void>();
        link.openGate = gate;
        final exchange = openExchange(transport);
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++) {
          openExchange(transport, requestId: 'fill-$i');
        }
        openExchange(transport, requestId: 'waiter');
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        exchange.cancel();
        gate.complete();
        await pumpEventQueue();

        final opened = link.createdStreams.last;
        expect(opened.resetCalled, isTrue);
        expect(opened.sent, isEmpty);
        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'CANCELLED'),
          ),
        );
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        await opened.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
      },
    );

    test(
      'a SEND_FAILED head holds its slot until records drain',
      () async {
        link.onOpen = (open) => _FakeStream()
          ..sendOutcome = open == const TunnelHttpStreamOpen(
                projectId: 'proj-a',
                requestId: 'bad',
              )
              ? PeerSendOutcome.backpressured
              : PeerSendOutcome.accepted;
        final transport = await bind(projectId: 'proj-a');
        final bad = openExchange(transport, requestId: 'bad');
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++) {
          openExchange(transport, requestId: 'fill-$i');
        }
        openExchange(transport, requestId: 'waiter');
        await expectLater(
          bad.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'SEND_FAILED'),
          ),
        );
        await pumpEventQueue();
        final badStream = link.createdStreams.first;
        expect(badStream.resetCalled, isTrue);
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        await badStream.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
      },
    );

    test(
      'a refusal that lands while the request body is still being written '
      'fails REFUSED at once, not SEND_FAILED once the write gives up',
      () async {
        final gate = Completer<void>();
        final transport = await bind(projectId: 'proj-a');
        link.onOpen = (_) => _FakeStream()
          ..rawGate = gate
          ..sendRawOutcome = PeerSendOutcome.closed;
        final exchange = openExchange(
          transport,
          bodyLength: 3,
          body: Stream.value(Uint8List.fromList([1, 2, 3])),
        );
        final fakeStream = link.createdStreams.single;
        Object? failure;
        exchange.head.then<void>((_) {}, onError: (Object e) {
          failure = e;
        });
        await pumpEventQueue();
        expect(fakeStream.sentRaw, hasLength(1), reason: 'write in flight');

        const refusal = StreamRefused(
          code: StreamRefusedCode.capExceeded,
          message: 'too many tunnels',
        );
        fakeStream.emit(refusal.toJson());
        await fakeStream.endPeer();
        await pumpEventQueue();

        expect(
          failure,
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'REFUSED'),
        );
        gate.complete();
        await pumpEventQueue();
        expect(
          failure,
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'REFUSED'),
        );
      },
    );

    test(
      'a response that ends while the request body is still being written '
      'is delivered at once, and the send half FINs only once the body is out',
      () async {
        final gate = Completer<void>();
        final transport = await bind(projectId: 'proj-a');
        link.onOpen = (_) => _FakeStream()..rawGate = gate;
        final exchange = openExchange(
          transport,
          bodyLength: 3,
          body: Stream.value(Uint8List.fromList([1, 2, 3])),
        );
        final fakeStream = link.createdStreams.single;
        final chunks = <int>[];
        var bodyDone = false;
        exchange.body.listen(chunks.addAll, onDone: () => bodyDone = true);
        await pumpEventQueue();

        fakeStream.emit({
          'type': 'tunnel:http-head',
          'requestId': 'r1',
          'status': 413,
          'headers': <String, String>{},
        });
        fakeStream.emitRaw(Uint8List.fromList(utf8.encode('no')));
        await fakeStream.endPeer();
        await pumpEventQueue();

        final head = await exchange.head.timeout(const Duration(seconds: 1));
        expect(head.status, 413);
        expect(utf8.decode(chunks), 'no');
        expect(bodyDone, isTrue);
        expect(
          fakeStream.finishCalled,
          isFalse,
          reason: 'a FIN now would end the request body short',
        );

        gate.complete();
        await pumpEventQueue();
        expect(fakeStream.finishCalled, isTrue);
        expect(fakeStream.resetCalled, isFalse);
      },
    );

    test(
      'a SEND_FAILED body slice holds its slot until records drain',
      () async {
        link.onOpen = (open) {
          final s = _FakeStream();
          if (open ==
              const TunnelHttpStreamOpen(projectId: 'proj-a', requestId: 'bad')) {
            s.failAfterRawSends = 0; // the head goes, the first raw slice fails
          }
          return s;
        };
        final transport = await bind(projectId: 'proj-a');
        final bad = openExchange(
          transport,
          requestId: 'bad',
          bodyLength: 3,
          body: Stream.value(Uint8List.fromList([1, 2, 3])),
        );
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++) {
          openExchange(transport, requestId: 'fill-$i');
        }
        openExchange(transport, requestId: 'waiter');
        await expectLater(
          bad.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'SEND_FAILED'),
          ),
        );
        await pumpEventQueue();
        final badStream = link.createdStreams.first;
        expect(badStream.sent, hasLength(1));
        expect(badStream.sentRaw, hasLength(1));
        expect(badStream.resetCalled, isTrue);
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        await badStream.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
      },
    );

    test(
      'the 129th concurrent open waits for a slot and opens once one is '
      'released by a clean end',
      () async {
        final transport = await bind(projectId: 'proj-a');
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer; i++) {
          openExchange(transport, requestId: 'r$i');
        }
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        openExchange(transport, requestId: 'r-wait');
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        final firstStream = link.createdStreams.first;
        firstStream.emit({
          'type': 'tunnel:http-head',
          'requestId': 'r0',
          'status': 200,
          'headers': <String, String>{},
        });
        await firstStream.endPeer();
        await pumpEventQueue();

        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
      },
    );

    test('cancel() while waiting for a slot never opens a stream', () async {
      final transport = await bind(projectId: 'proj-a');
      for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer; i++) {
        openExchange(transport, requestId: 'r$i');
      }
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

      final waiter = openExchange(transport, requestId: 'r-wait');
      await pumpEventQueue();
      waiter.cancel();

      await expectLater(
        waiter.head,
        throwsA(
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));
    });

    test(
      'disposing the session fails a waiting exchange with TRANSPORT_CLOSED',
      () async {
        final transport = await bind(projectId: 'proj-a');
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer; i++) {
          openExchange(transport, requestId: 'r$i');
        }
        final waiter = openExchange(transport, requestId: 'r-wait');
        await pumpEventQueue();

        final failure = expectLater(
          waiter.head,
          throwsA(
            isA<TunnelExchangeFailure>().having(
              (e) => e.code,
              'code',
              'TRANSPORT_CLOSED',
            ),
          ),
        );
        await session.dispose();
        await failure;
      },
    );
  });

  group('_StreamTunnelWsChannel (native-stream path)', () {
    late _FakeMultiStreamLink link;
    late MachineSession session;

    setUp(() {
      link = _FakeMultiStreamLink();
    });

    tearDown(() async {
      await session.dispose();
    });

    // See the HTTP group's `bind()` above for why the link's tracking is
    // cleared before returning.
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
        IncomingPeerFrame(
          kind: kPeerFrameMessage,
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
      return transport;
    }

    TunnelWsChannel openChannel(
      StreamTransport transport, {
      String tunnelId = 'ws1',
    }) => transport.openTunnelWs(
      tunnelId: tunnelId,
      checkoutId: 'main',
      open: {
        'type': 'tunnel:ws-open',
        'port': 3000,
        'scheme': 'http',
        'path': '/',
      },
    );

    test('frames arrive on frames in record order', () async {
      final transport = await bind(projectId: 'proj-a');
      final channel = openChannel(transport);
      final fakeStream = link.createdStreams.single;
      await pumpEventQueue();

      fakeStream.emitData(
        kTunnelRecordTagWsText,
        Uint8List.fromList(utf8.encode('one')),
      );
      fakeStream.emitData(kTunnelRecordTagWsBinary, Uint8List.fromList([9, 8, 7]));

      final frames = await channel.frames.take(2).toList();
      expect(frames[0].binary, isFalse);
      expect(utf8.decode(frames[0].bytes), 'one');
      expect(frames[1].binary, isTrue);
      expect(frames[1].bytes, [9, 8, 7]);
    });

    test(
      'close() writes tunnel:ws-close after every queued frame, then '
      'finishes',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final channel = openChannel(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        final send1 = channel.send(
          TunnelWsFrame(binary: false, bytes: Uint8List.fromList(utf8.encode('a'))),
        );
        channel.close(code: 1000, reason: 'done');
        await send1;
        await pumpEventQueue();

        // sent[0] is the tunnel:ws-open head; sent[1] is the queued frame;
        // sent[2] is the close record — in that order, since close() chains
        // behind the same send serialization as every frame ahead of it.
        expect(fakeStream.sent, hasLength(3));
        expect(fakeStream.sent[1][0], kTunnelRecordTagWsText);
        final closeJson = jsonDecode(utf8.decode(fakeStream.sent[2])) as Map;
        expect(closeJson['type'], 'tunnel:ws-close');
        expect(closeJson['code'], 1000);
        expect(closeJson['reason'], 'done');
        expect(fakeStream.finishCalled, isTrue);
      },
    );

    test("the peer's close record surfaces its code/reason in done", () async {
      final transport = await bind(projectId: 'proj-a');
      final channel = openChannel(transport);
      final fakeStream = link.createdStreams.single;
      await pumpEventQueue();

      fakeStream.emit({'type': 'tunnel:ws-close', 'code': 4010, 'reason': 'bye'});
      await fakeStream.endPeer();

      final end = await channel.done;
      expect(end, isA<TunnelWsClosedByPeer>());
      final closed = end as TunnelWsClosedByPeer;
      expect(closed.code, 4010);
      expect(closed.reason, 'bye');
    });

    test(
      'a peer FIN with no close record gives TunnelWsClosedByPeer(null, null)',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final channel = openChannel(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        await fakeStream.endPeer();

        final end = await channel.done;
        expect(end, isA<TunnelWsClosedByPeer>());
        final closed = end as TunnelWsClosedByPeer;
        expect(closed.code, isNull);
        expect(closed.reason, isNull);
      },
    );

    test(
      'a frame over kStreamTunnelDataMaxBytes resets the stream and its '
      'send resolves false',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final channel = openChannel(transport);
        final fakeStream = link.createdStreams.single;
        await pumpEventQueue();

        final oversized = Uint8List(kStreamTunnelDataMaxBytes + 1);
        final accepted = await channel.send(
          TunnelWsFrame(binary: true, bytes: oversized),
        );

        expect(accepted, isFalse);
        expect(fakeStream.resetCalled, isTrue);
      },
    );

    test(
      'abort() while the open is in flight resets once it resolves and '
      'holds the slot until records drain',
      () async {
        final transport = await bind(projectId: 'proj-a');
        final gate = Completer<void>();
        link.openGate = gate;
        final channel = openChannel(transport);
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++) {
          openChannel(transport, tunnelId: 'fill-$i');
        }
        openChannel(transport, tunnelId: 'waiter');
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        channel.abort();
        gate.complete();
        await pumpEventQueue();

        final opened = link.createdStreams.last;
        expect(opened.resetCalled, isTrue);
        expect(opened.sent, isEmpty);
        expect(await channel.done, isA<TunnelWsFailed>());
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        await opened.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
      },
    );

    test(
      'a SEND_FAILED open record holds its slot until records drain',
      () async {
        link.onOpen = (open) => _FakeStream()
          ..sendOutcome =
              open == const TunnelWsStreamOpen(projectId: 'proj-a', wsId: 'bad')
              ? PeerSendOutcome.backpressured
              : PeerSendOutcome.accepted;
        final transport = await bind(projectId: 'proj-a');
        final bad = openChannel(transport, tunnelId: 'bad');
        for (var i = 0; i < kStreamMaxTunnelStreamsPerPeer - 1; i++) {
          openChannel(transport, tunnelId: 'fill-$i');
        }
        openChannel(transport, tunnelId: 'waiter');
        final end = await bad.done;
        expect(
          end,
          isA<TunnelWsFailed>().having(
            (e) => e.failure.code,
            'code',
            'SEND_FAILED',
          ),
        );
        await pumpEventQueue();
        final badStream = link.createdStreams.first;
        expect(badStream.resetCalled, isTrue);
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer));

        await badStream.endPeer();
        await pumpEventQueue();
        expect(link.opens, hasLength(kStreamMaxTunnelStreamsPerPeer + 1));
      },
    );
  });

  group('StreamTransport over a non-multi-stream link', () {
    test(
      'openTunnelHttp and openTunnelWs both fall back to NOT_SUPPORTED',
      () async {
        // Since A4, a project's own transport only ever exists over a
        // MultiStreamPeerLink (openProject requires one), so the only
        // reachable non-multi-stream transport left is session.control.
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
        final exchange = transport.openTunnelHttp(
          requestId: 'r1',
          checkoutId: 'main',
          head: const {'type': 'tunnel:http-request'},
          bodyLength: 0,
        );
        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having(
              (e) => e.code,
              'code',
              'NOT_SUPPORTED',
            ),
          ),
        );

        final channel = transport.openTunnelWs(
          tunnelId: 'ws1',
          checkoutId: 'main',
          open: const {'type': 'tunnel:ws-open'},
        );
        final end = await channel.done;
        expect(end, isA<TunnelWsFailed>());
        expect((end as TunnelWsFailed).failure.code, 'NOT_SUPPORTED');
      },
    );
  });
}

/// Lets an unawaited async chain (`_start()`, the send scheduler's drain loop)
/// settle before the next assertion. A real duration, not `Duration.zero`: the
/// scheduler's drain isn't a fixed number of microtasks away.
Future<void> pumpEventQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

/// A [PeerLink] that does NOT also implement [MultiStreamPeerLink] —
/// `FakeLiveRelay` implements both (every native link does), so this stands
/// in for an older relay to exercise the NOT_SUPPORTED fallback.
class _PlainPeerLink implements PeerLink {
  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _failures = StreamController<PeerLinkFailure>.broadcast();

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
  Future<PeerSendOutcome> sendFrame(String kind, Uint8List payload) async =>
      PeerSendOutcome.accepted;

  @override
  Future<void> close() async {}
}

class _FakeMultiStreamLink implements PeerLink, MultiStreamPeerLink {
  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  final _states = StreamController<PeerLinkState>.broadcast();
  final _failures = StreamController<PeerLinkFailure>.broadcast();

  final List<({StreamOpen open, int maxRecordBytes, int maxQueuedBytes})>
  opens = [];
  final List<_FakeStream> createdStreams = [];

  /// Overrides the stream a successful [openStream] returns; defaults to a
  /// fresh [_FakeStream] recorded in [createdStreams].
  _FakeStream Function(StreamOpen open)? onOpen;

  /// When set, [openStream] throws this instead of returning.
  Object? openError;

  /// When set, the next [openStream] is recorded but does not resolve until
  /// this completes. One-shot.
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
  Future<PeerSendOutcome> sendFrame(String kind, Uint8List payload) async =>
      PeerSendOutcome.accepted;

  @override
  Future<void> close() async {}

  void inject(IncomingPeerFrame frame) => _messages.add(frame);

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
    openGate = null;
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
  final List<Uint8List> sentRaw = [];
  bool resetCalled = false;
  bool finishCalled = false;
  PeerSendOutcome sendOutcome = PeerSendOutcome.accepted;
  PeerSendOutcome sendRawOutcome = PeerSendOutcome.accepted;

  /// When set, every framed send after this many answers `backpressured`.
  int? failAfterSends;

  /// When set, every raw send after this many answers `backpressured`.
  int? failAfterRawSends;

  /// When set, the FIRST raw send waits on this before it settles — one
  /// request-body write still in flight.
  Completer<void>? rawGate;

  @override
  Stream<Uint8List> get records => _records.stream;

  @override
  Future<PeerSendOutcome> send(Uint8List record) async {
    sent.add(record);
    final limit = failAfterSends;
    if (limit != null && sent.length > limit) {
      return PeerSendOutcome.backpressured;
    }
    return sendOutcome;
  }

  @override
  Future<PeerSendOutcome> sendRaw(Uint8List bytes) async {
    sentRaw.add(bytes);
    final gate = rawGate;
    if (gate != null && sentRaw.length == 1) await gate.future;
    final limit = failAfterRawSends;
    if (limit != null && sentRaw.length > limit) {
      return PeerSendOutcome.backpressured;
    }
    return sendRawOutcome;
  }

  /// Leaves [records] open: a real [PeerStream]'s records end only on the
  /// peer's end, never because this side reset (see `peer_link.dart`), and
  /// the slot rules depend on exactly that.
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

  /// A raw body chunk, as it arrives once the stream is past its framed head
  /// — no tag, no framing, straight bytes.
  void emitRaw(Uint8List bytes) {
    if (_records.isClosed) return;
    _records.add(bytes);
  }

  /// One tagged binary data record — still how the WS channel's frames work.
  void emitData(int tag, Uint8List payload) {
    if (_records.isClosed) return;
    final out = Uint8List(payload.length + 1);
    out[0] = tag;
    out.setRange(1, out.length, payload);
    _records.add(out);
  }

  Future<void> endPeer() async {
    if (!_records.isClosed) await _records.close();
  }

  /// Ends the peer's send half with a reset rather than a clean FIN — only
  /// distinguishable once the stream has moved past its framed head.
  Future<void> endWithReset() async {
    if (_records.isClosed) return;
    _records.addError(const PeerStreamReset());
    await _records.close();
  }
}
