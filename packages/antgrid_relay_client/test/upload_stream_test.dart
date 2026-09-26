// Coverage for `_StreamUploadExchange` (the native-stream path in
// `machine_session.dart`).
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/native_stream_link.dart';

void main() {
  group('_StreamUploadExchange (native-stream path)', () {
    late NativeStreamLink link;

    setUp(() {
      link = NativeStreamLink();
    });

    tearDown(() async {
      // Every created stream still holding a result timer must see its
      // records end, or that real 30-second Timer keeps the test process
      // alive well past this file's own assertions.
      for (final s in link.createdStreams) {
        expect(s.sent, isEmpty, reason: 'an upload never writes a framed record');
        unawaited(s.endPeer());
      }
      await pump();
      await link.session.dispose();
    });

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
        final transport = await link.bind('proj-a');
        final big = Uint8List(kStreamRawSliceBytes + 100);
        final gate = Completer<void>();
        link.onOpen = (_) => NativeTestStream()..rawGate = gate;
        final progress = <List<int>>[];
        final exchange = transport.openUpload(
          requestId: 'r-progress',
          projectId: 'proj-a',
          checkoutId: 'main',
          fileName: 'hi.bin',
          bytes: big,
          onProgress: (s, t) => progress.add([s, t]),
        );
        await pump();

        expect(progress, isEmpty, reason: 'the first slice write is still gated');
        final fakeStream = link.createdStreams.single;
        expect(
          fakeStream.sentRaw,
          hasLength(1),
          reason: 'the write was attempted, just not yet resolved',
        );

        gate.complete();
        await pump();

        expect(progress, [
          [kStreamRawSliceBytes, big.length],
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
      'a result record arriving before every slice is sent completes result '
      'at once and stops the send loop before it ever calls finish()',
      () async {
        final transport = await link.bind('proj-a');
        final gate = Completer<void>();
        link.onOpen = (_) => NativeTestStream()..rawGateAt = 1;
        final bytes = Uint8List(kStreamRawSliceBytes * 2 + 50);
        final exchange = openExchange(transport, bytes: bytes);
        final fakeStream = link.createdStreams.single;
        fakeStream.rawGate = gate;
        await pump();

        // The first slice went out and resolved; the second is now in
        // flight, gated. A result arriving in that window must win the race.
        expect(fakeStream.sentRaw, hasLength(2));
        fakeStream.emit({
          'type': 'file:upload-result',
          'requestId': 'r1',
          'ok': true,
          'path': '/abs/hi.bin',
        });
        await pump();
        gate.complete();
        await pump();

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
        final transport = await link.bind('proj-a');
        final gate = Completer<void>();
        link.onOpen = (_) => NativeTestStream()
          ..rawGateAt = 1
          ..throwAfterGate = true;
        final bytes = Uint8List(kStreamRawSliceBytes * 2 + 50);
        final exchange = openExchange(transport, bytes: bytes);
        final fakeStream = link.createdStreams.single;
        fakeStream.rawGate = gate;
        await pump();

        fakeStream.emit({
          'type': 'file:upload-result',
          'requestId': 'r1',
          'ok': false,
          'error': 'TOO_LARGE',
        });
        await pump();
        gate.complete();
        await pump();

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
      final transport = await link.bind('proj-a');
      final exchange = openExchange(transport, bytes: Uint8List.fromList([1]));
      final fakeStream = link.createdStreams.single;
      await pump();

      expect(fakeStream.finishCalled, isTrue);
      await fakeStream.endPeer();

      await expectLater(
        exchange.result,
        throwsA(
          isA<UploadFailure>().having((e) => e.code, 'code', 'STREAM_ENDED'),
        ),
      );
    });

  });
}
