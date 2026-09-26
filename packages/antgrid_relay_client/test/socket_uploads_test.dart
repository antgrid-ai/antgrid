// Coverage for `SocketUploads` (the loopback `file:upload-start/ready/chunk/
// ack/done/result` exchange in `upload_stream.dart`) — the socket-path sibling
// of the native-stream `_StreamUploadExchange` covered by `upload_stream_test.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  late List<Map<String, dynamic>> sent;
  late SocketUploads uploads;

  setUp(() {
    sent = [];
    uploads = SocketUploads((message) async {
      sent.add(message);
    });
  });

  Map<String, dynamic> sentOfType(String type) =>
      sent.singleWhere((m) => m['type'] == type);

  test(
    'the happy path: start, one chunk, done, each answered in turn, with '
    'progress reported on the ack',
    () async {
      final progress = <List<int>>[];
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: bytes,
        onProgress: (s, t) => progress.add([s, t]),
      );

      await pumpEventQueue();
      final start = sentOfType('file:upload-start');
      expect(start['requestId'], 'r1');
      expect(start['fileName'], 'hi.txt');
      expect(start['size'], bytes.length);

      expect(
        uploads.dispatch({
          'type': 'file:upload-ready',
          'requestId': 'r1',
          'uploadId': 'up-1',
        }),
        isTrue,
      );
      await pumpEventQueue();
      final chunk = sentOfType('file:upload-chunk');
      expect(chunk['uploadId'], 'up-1');
      expect(chunk['seq'], 0);
      expect(base64Decode(chunk['data'] as String), bytes);

      expect(
        uploads.dispatch({
          'type': 'file:upload-ack',
          'uploadId': 'up-1',
          'seq': 0,
        }),
        isTrue,
      );
      await pumpEventQueue();
      expect(progress, [
        [bytes.length, bytes.length],
      ]);
      final done = sentOfType('file:upload-done');
      expect(done['uploadId'], 'up-1');

      expect(
        uploads.dispatch({
          'type': 'file:upload-result',
          'requestId': 'r1',
          'uploadId': 'up-1',
          'ok': true,
          'path': '/abs/hi.txt',
        }),
        isTrue,
      );

      final result = await exchange.result;
      expect(result.ok, isTrue);
      expect(result.path, '/abs/hi.txt');
    },
  );

  test(
    'a reply that lands before its send has resolved still wakes the step '
    'waiting on it',
    () async {
      late SocketUploads replying;
      replying = SocketUploads((message) async {
        sent.add(message);
        // The loopback socket can deliver the bridge's answer before the
        // send future's continuation runs.
        switch (message['type']) {
          case 'file:upload-start':
            replying.dispatch({
              'type': 'file:upload-ready',
              'requestId': message['requestId'],
              'uploadId': 'up-1',
            });
          case 'file:upload-chunk':
            replying.dispatch({
              'type': 'file:upload-ack',
              'uploadId': message['uploadId'],
              'seq': message['seq'],
            });
          case 'file:upload-done':
            replying.dispatch({
              'type': 'file:upload-result',
              'requestId': 'r1',
              'uploadId': 'up-1',
              'ok': true,
              'path': '/abs/hi.txt',
            });
        }
      });
      final exchange = replying.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      final result = await exchange.result.timeout(const Duration(seconds: 2));
      expect(result.ok, isTrue);
      expect(result.path, '/abs/hi.txt');
    },
  );

  test(
    'every socket-path message carries an id and a timestamp, like any '
    'other outbound AbMessage',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List(0),
      );
      await pumpEventQueue();
      final start = sentOfType('file:upload-start');
      expect(start['id'], isA<String>());
      expect(start['timestamp'], isA<int>());
      exchange.cancel();
      await expectLater(exchange.result, throwsA(isA<UploadFailure>()));
    },
  );

  test(
    'dispatch consumes only a ready/ack/result for an in-flight upload, '
    'never a frame naming an unknown requestId or uploadId',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List(0),
      );
      await pumpEventQueue();

      expect(
        uploads.dispatch({'type': 'file:upload-ready', 'requestId': 'other'}),
        isFalse,
      );
      expect(
        uploads.dispatch({
          'type': 'file:upload-ack',
          'uploadId': 'no-such-upload',
          'seq': 0,
        }),
        isFalse,
      );
      expect(
        uploads.dispatch({
          'type': 'file:upload-result',
          'requestId': 'other',
          'uploadId': 'no-such-upload',
          'ok': true,
        }),
        isFalse,
      );
      expect(uploads.dispatch({'type': 'terminal:output'}), isFalse);

      // Settles the exchange this test opened, so it does not leave a real
      // 30-second reply timer running past the end of the test.
      exchange.cancel();
      await expectLater(
        exchange.result,
        throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'CANCELLED')),
      );
    },
  );

  test(
    'a result naming only the uploadId (requestId:"") wakes the exchange '
    'that started it, via the uploadId learned from the ready reply',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await pumpEventQueue();
      uploads.dispatch({
        'type': 'file:upload-ready',
        'requestId': 'r1',
        'uploadId': 'up-dead',
      });
      await pumpEventQueue();
      uploads.dispatch({
        'type': 'file:upload-ack',
        'uploadId': 'up-dead',
        'seq': 0,
      });
      await pumpEventQueue();

      // The bridge names only the uploadId once the requestId is no longer
      // meaningful to it (a swept or otherwise dead upload).
      expect(
        uploads.dispatch({
          'type': 'file:upload-result',
          'requestId': '',
          'uploadId': 'up-dead',
          'ok': false,
          'error': 'DEAD',
        }),
        isTrue,
      );

      final result = await exchange.result;
      expect(result.ok, isFalse);
      expect(result.error, 'DEAD');
    },
  );

  test(
    'an immediate ok:false start reply completes result with that reply, '
    'never as a failure',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List.fromList([1]),
      );
      await pumpEventQueue();

      uploads.dispatch({
        'type': 'file:upload-ready',
        'requestId': 'r1',
        'ok': false,
        'error': 'TOO_LARGE',
        'message': 'file exceeds the limit',
      });

      final result = await exchange.result;
      expect(result.ok, isFalse);
      expect(result.error, 'TOO_LARGE');
      expect(result.message, 'file exceeds the limit');
      // Only the start reply went out — no chunk was ever attempted.
      expect(sent.where((m) => m['type'] == 'file:upload-chunk'), isEmpty);
    },
  );

  test(
    'a ready reply with no string uploadId fails PROTOCOL',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List.fromList([1]),
      );
      await pumpEventQueue();

      uploads.dispatch({'type': 'file:upload-ready', 'requestId': 'r1'});

      await expectLater(
        exchange.result,
        throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'PROTOCOL')),
      );
    },
  );

  test(
    'cancel() while an ack is pending fails result with CANCELLED at once, '
    'without waiting out the reply',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await pumpEventQueue();
      uploads.dispatch({
        'type': 'file:upload-ready',
        'requestId': 'r1',
        'uploadId': 'up-1',
      });
      await pumpEventQueue();

      exchange.cancel();

      await expectLater(
        exchange.result,
        throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'CANCELLED')),
      );

      // The ack this upload was waiting on no longer claims anything.
      expect(
        uploads.dispatch({
          'type': 'file:upload-ack',
          'uploadId': 'up-1',
          'seq': 0,
        }),
        isFalse,
      );
    },
  );

  test(
    'cancel() while the start reply is pending fails result with CANCELLED '
    'without waiting for the reply, and a late ready reply then claims '
    'nothing',
    () async {
      final exchange = uploads.open(
        requestId: 'r1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'hi.txt',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      await pumpEventQueue();

      exchange.cancel();
      await expectLater(
        exchange.result,
        throwsA(isA<UploadFailure>().having((e) => e.code, 'code', 'CANCELLED')),
      );

      expect(
        uploads.dispatch({
          'type': 'file:upload-ready',
          'requestId': 'r1',
          'uploadId': 'up-1',
        }),
        isFalse,
      );
    },
  );
}

Future<void> pumpEventQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
