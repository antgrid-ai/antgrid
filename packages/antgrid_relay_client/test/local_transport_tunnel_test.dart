// Loopback never tunnels. `LocalTransport` declares no
// `openTunnelTcp` override, so it inherits
// `BufferedAgentTransport`'s NOT_SUPPORTED stub — this pins that the call never
// writes anything to the local socket. Server fixture modeled on
// `local_transport_terminal_attachment_test.dart`'s `_EchoServer`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

class _EchoServer {
  late final HttpServer _server;
  final hello = Completer<Map<String, dynamic>>();
  final received = <Map<String, dynamic>>[];

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
                  if (!hello.isCompleted) hello.complete(m);
                  ws.add(jsonEncode({'type': 'ready'}));
                case 'request':
                  ws.add(
                    jsonEncode({
                      'type': 'response',
                      'requestId': m['requestId'],
                      'ok': false,
                      'error': {'code': 'E_UNSUPPORTED', 'message': 'no snapshot'},
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
  late _EchoServer server;
  late LocalTransport transport;

  setUp(() async {
    server = _EchoServer();
    await server.start();
    transport = LocalTransport(port: server.port, token: 't', appPid: 1);
    await transport.connect();
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  test('openTunnelTcp fails NOT_SUPPORTED and writes nothing to the socket', () async {
    final channel = transport.openTunnelTcp(connId: 'c1', port: 3000);

    await expectLater(
      channel.ready,
      throwsA(
        isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'NOT_SUPPORTED'),
      ),
    );
    expect(await channel.incoming.isEmpty, isTrue);
    expect(await channel.send(Uint8List.fromList([1])), isFalse);
    await channel.finish();
    channel.abort();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.received, isEmpty);
  });
}
