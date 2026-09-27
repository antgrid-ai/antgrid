// Coverage for the native-stream tunnel implementations
// (`_StreamTunnelHttpExchange` / `_StreamTunnelWsChannel` in
// `machine_session.dart`).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/native_stream_link.dart';

void main() {
  group('_StreamTunnelHttpExchange (native-stream path)', () {
    late NativeStreamLink link;

    setUp(() {
      link = NativeStreamLink();
    });

    tearDown(() async {
      await link.session.dispose();
    });

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
      final transport = await link.bind('proj-a');
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
      await pump();
      final headJson = jsonDecode(utf8.decode(fakeStream.sent.single)) as Map;
      expect(headJson['bodyLength'], 5);
      expect(headJson['checkoutId'], 'main');
      expect(utf8.decode(fakeStream.sentRaw.single), 'hello');
    });

    test(
      'a body over the 262144-byte slice ceiling is split into two raw '
      'writes',
      () async {
        final transport = await link.bind('proj-a');
        final big = Uint8List(262144 + 10);
        openExchange(transport, bodyLength: big.length, body: Stream.value(big));
        final fakeStream = link.createdStreams.single;
        await pump();

        expect(fakeStream.sent, hasLength(1));
        expect(fakeStream.sentRaw, hasLength(2));
        expect(fakeStream.sentRaw[0].length, 262144);
        expect(fakeStream.sentRaw[1].length, 10);
      },
    );

    test(
      'head and raw body chunks complete the exchange; finish() waits '
      'for the peer FIN',
      () async {
        final transport = await link.bind('proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pump();

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
        await pump();

        // The read loop only calls finish() once the peer's own FIN arrives.
        expect(fakeStream.finishCalled, isFalse);
        await fakeStream.endPeer();
        await bodyDone;

        expect(utf8.decode(chunks), 'abc');
        await pump();
        expect(fakeStream.finishCalled, isTrue);
      },
    );

    test(
      'the stream resetting after a head fails TRUNCATED',
      () async {
        final transport = await link.bind('proj-a');
        final exchange = openExchange(transport);
        final fakeStream = link.createdStreams.single;
        await pump();

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
      'a refusal that lands while the request body is still being written '
      'fails REFUSED at once, not SEND_FAILED once the write gives up',
      () async {
        final gate = Completer<void>();
        final transport = await link.bind('proj-a');
        link.onOpen = (_) => NativeTestStream()
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
        await pump();
        expect(fakeStream.sentRaw, hasLength(1), reason: 'write in flight');

        const refusal = StreamRefused(
          code: StreamRefusedCode.capExceeded,
          message: 'too many tunnels',
        );
        fakeStream.emit(refusal.toJson());
        await fakeStream.endPeer();
        await pump();

        expect(
          failure,
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'REFUSED'),
        );
        gate.complete();
        await pump();
        expect(
          failure,
          isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'REFUSED'),
        );
      },
    );

    test(
      'a body slice whose send fails ends the exchange SEND_FAILED and resets '
      'the stream without waiting for a response',
      () async {
        final transport = await link.bind('proj-a');
        link.onOpen = (_) =>
            NativeTestStream()..sendRawOutcome = PeerSendOutcome.backpressured;
        final exchange = openExchange(
          transport,
          bodyLength: 3,
          body: Stream.value(Uint8List.fromList([1, 2, 3])),
        );
        final fakeStream = link.createdStreams.single;

        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'SEND_FAILED'),
          ),
        );
        expect(fakeStream.resetCalled, isTrue);
        expect(fakeStream.finishCalled, isFalse);
        await fakeStream.endPeer();
      },
    );

    test(
      'a body source that ends short of bodyLength ends the exchange PROTOCOL '
      'and resets the stream without waiting for a response',
      () async {
        final transport = await link.bind('proj-a');
        final exchange = openExchange(
          transport,
          bodyLength: 5,
          body: Stream.value(Uint8List.fromList([1, 2, 3])),
        );
        final fakeStream = link.createdStreams.single;

        await expectLater(
          exchange.head,
          throwsA(
            isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'PROTOCOL'),
          ),
        );
        expect(fakeStream.resetCalled, isTrue);
        expect(fakeStream.finishCalled, isFalse);
        await fakeStream.endPeer();
      },
    );

    test(
      'a response that ends while the request body is still being written '
      'is delivered at once, and the send half FINs only once the body is out',
      () async {
        final gate = Completer<void>();
        final transport = await link.bind('proj-a');
        link.onOpen = (_) => NativeTestStream()..rawGate = gate;
        final exchange = openExchange(
          transport,
          bodyLength: 3,
          body: Stream.value(Uint8List.fromList([1, 2, 3])),
        );
        final fakeStream = link.createdStreams.single;
        final chunks = <int>[];
        var bodyDone = false;
        exchange.body.listen(chunks.addAll, onDone: () => bodyDone = true);
        await pump();

        fakeStream.emit({
          'type': 'tunnel:http-head',
          'requestId': 'r1',
          'status': 413,
          'headers': <String, String>{},
        });
        fakeStream.emitRaw(Uint8List.fromList(utf8.encode('no')));
        await fakeStream.endPeer();
        await pump();

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
        await pump();
        expect(fakeStream.finishCalled, isTrue);
        expect(fakeStream.resetCalled, isFalse);
      },
    );

  });

  group('_StreamTunnelWsChannel (native-stream path)', () {
    late NativeStreamLink link;

    setUp(() {
      link = NativeStreamLink();
    });

    tearDown(() async {
      await link.session.dispose();
    });

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

    test(
      'close() writes tunnel:ws-close after every queued frame, then '
      'finishes',
      () async {
        final transport = await link.bind('proj-a');
        final channel = openChannel(transport);
        final fakeStream = link.createdStreams.single;
        await pump();

        final send1 = channel.send(
          TunnelWsFrame(binary: false, bytes: Uint8List.fromList(utf8.encode('a'))),
        );
        channel.close(code: 1000, reason: 'done');
        await send1;
        await pump();

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
      final transport = await link.bind('proj-a');
      final channel = openChannel(transport);
      final fakeStream = link.createdStreams.single;
      await pump();

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
        final transport = await link.bind('proj-a');
        final channel = openChannel(transport);
        final fakeStream = link.createdStreams.single;
        await pump();

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
        final transport = await link.bind('proj-a');
        final channel = openChannel(transport);
        final fakeStream = link.createdStreams.single;
        await pump();

        final oversized = Uint8List(kStreamTunnelDataMaxBytes + 1);
        final accepted = await channel.send(
          TunnelWsFrame(binary: true, bytes: oversized),
        );

        expect(accepted, isFalse);
        expect(fakeStream.resetCalled, isTrue);
      },
    );

  });
}
