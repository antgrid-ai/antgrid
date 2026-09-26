import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

class _UploadServer {
  late final HttpServer _server;
  final received = <Map<String, dynamic>>[];

  /// Set to answer the next `file:upload-local` with a `file:upload-result`;
  /// `null` sends nothing back, so a case can drive TIMEOUT itself.
  Map<String, dynamic>? Function(Map<String, dynamic> request)? onUploadLocal;

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
                case 'file:upload-local':
                  received.add(m);
                  final reply = onUploadLocal?.call(m);
                  if (reply != null) ws.add(jsonEncode(reply));
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
    'openUpload sends one file:upload-local naming a temp file and settles '
    'from the result, which never reaches messages',
    () async {
      final leaked = <InboundMessage>[];
      final sub = transport.messages.listen(leaked.add);
      final bytes = Uint8List.fromList(List<int>.generate(600000, (i) => i % 251));
      final progress = <int>[];
      String? sourcePath;
      List<int>? sourceBytes;

      server.onUploadLocal = (m) {
        sourcePath = m['sourcePath'] as String?;
        sourceBytes = File(sourcePath!).readAsBytesSync();
        return {
          'type': 'file:upload-result',
          'requestId': m['requestId'],
          'ok': true,
          'path': '/abs/up-1-a.bin',
          'relPath': '.antgrid/uploads/up-1-a.bin',
        };
      };

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
      expect(server.received.map((m) => m['type']), ['file:upload-local']);
      expect(server.received.first['checkoutId'], 'main');
      expect(progress, [0, bytes.length]);
      expect(sourceBytes, bytes);
      expect(server.received.first.containsKey('data'), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        leaked.where((m) => (m.json['type'] as String).startsWith('file:upload')),
        isEmpty,
      );
      // The temp file is cleaned up only once the bridge's answer is in.
      expect(File(sourcePath!).existsSync(), isFalse);
      await sub.cancel();
    },
  );

  // Waits out the real `kUploadResultTimeout` — the exchange has no injectable
  // clock, unlike the RPC-health tests' constructor-supplied duration.
  test('openUpload fails TIMEOUT when the bridge never answers', () async {
    server.onUploadLocal = (_) => null;
    final exchange = transport.openUpload(
      requestId: 'req-timeout',
      projectId: 'proj-a',
      checkoutId: 'main',
      fileName: 'a.bin',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    await expectLater(
      exchange.result,
      throwsA(isA<UploadFailure>().having((f) => f.code, 'code', 'TIMEOUT')),
    );
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('cancel() settles CANCELLED without waiting for the bridge', () async {
    server.onUploadLocal = (_) => null;
    final exchange = transport.openUpload(
      requestId: 'req-cancel',
      projectId: 'proj-a',
      checkoutId: 'main',
      fileName: 'a.bin',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    exchange.cancel();
    await expectLater(
      exchange.result,
      throwsA(isA<UploadFailure>().having((f) => f.code, 'code', 'CANCELLED')),
    );
  });

  test('dispose() fails every in-flight upload TRANSPORT_CLOSED', () async {
    server.onUploadLocal = (_) => null;
    final exchange = transport.openUpload(
      requestId: 'req-dispose',
      projectId: 'proj-a',
      checkoutId: 'main',
      fileName: 'a.bin',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    await transport.dispose();
    await expectLater(
      exchange.result,
      throwsA(
        isA<UploadFailure>().having((f) => f.code, 'code', 'TRANSPORT_CLOSED'),
      ),
    );
  });
}
