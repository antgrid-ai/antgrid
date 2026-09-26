// D2: loopback keeps the socket upload exchange. `LocalTransport` inherits
// `BufferedAgentTransport.openUpload`, so an upload through it must speak
// `file:upload-start/chunk/done` on the local socket and settle from the
// bridge's ready/ack/result replies, none of which may leak onto `messages`.
// Server fixture modeled on `local_transport_tunnel_test.dart`'s `_EchoServer`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

class _UploadServer {
  late final HttpServer _server;
  final received = <Map<String, dynamic>>[];
  final chunks = BytesBuilder();

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      _server
          .listen((req) async {
            final ws = await WebSocketTransformer.upgrade(req);
            ws.listen((data) {
              final m = jsonDecode(data as String) as Map<String, dynamic>;
              switch (m['type']) {
                case 'hello':
                  ws.add(jsonEncode({'type': 'ready'}));
                case 'request':
                  ws.add(
                    jsonEncode({
                      'type': 'response',
                      'requestId': m['requestId'],
                      'ok': false,
                      'error': {'code': 'E_UNSUPPORTED', 'message': 'no'},
                    }),
                  );
                case 'file:upload-start':
                  received.add(m);
                  ws.add(
                    jsonEncode({
                      'channel': 'control',
                      'type': 'file:upload-ready',
                      'requestId': m['requestId'],
                      'uploadId': 'up-1',
                      'checkoutId': m['checkoutId'],
                    }),
                  );
                case 'file:upload-chunk':
                  received.add(m);
                  chunks.add(base64Decode(m['data'] as String));
                  ws.add(
                    jsonEncode({
                      'channel': 'control',
                      'type': 'file:upload-ack',
                      'uploadId': m['uploadId'],
                      'seq': m['seq'],
                    }),
                  );
                case 'file:upload-done':
                  received.add(m);
                  ws.add(
                    jsonEncode({
                      'channel': 'control',
                      'type': 'file:upload-result',
                      'requestId': 'req-1',
                      'uploadId': m['uploadId'],
                      'ok': true,
                      'path': '/abs/up-1-a.bin',
                      'relPath': '.antgrid/uploads/up-1-a.bin',
                    }),
                  );
                default:
                  received.add(m);
              }
            });
          })
          .asFuture<void>()
          .catchError((Object _) {}),
    );
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _UploadServer server;
  late LocalTransport transport;

  setUp(() async {
    server = _UploadServer();
    await server.start();
    transport = LocalTransport(port: server.port, token: 't', appPid: 1);
    await transport.connect();
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  test(
    'openUpload rides the socket exchange in chunks and settles from the '
    'replies, which never reach messages',
    () async {
      final leaked = <InboundMessage>[];
      final sub = transport.messages.listen(leaked.add);
      final bytes = Uint8List.fromList(
        List<int>.generate(kSocketUploadChunkBytes + 5, (i) => i % 251),
      );
      final progress = <int>[];

      final exchange = transport.openUpload(
        requestId: 'req-1',
        projectId: 'proj-a',
        checkoutId: 'main',
        fileName: 'a.bin',
        bytes: bytes,
        onProgress: (sent, _) => progress.add(sent),
      );
      final result = await exchange.result.timeout(const Duration(seconds: 5));

      expect(result.ok, isTrue);
      expect(result.path, '/abs/up-1-a.bin');
      expect(server.chunks.takeBytes(), bytes);
      expect(
        server.received.map((m) => m['type']),
        [
          'file:upload-start',
          'file:upload-chunk',
          'file:upload-chunk',
          'file:upload-done',
        ],
      );
      expect(server.received.first['checkoutId'], 'main');
      expect(progress, [kSocketUploadChunkBytes, bytes.length]);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        leaked.where((m) => (m.json['type'] as String).startsWith('file:upload')),
        isEmpty,
      );
      await sub.cancel();
    },
  );
}
