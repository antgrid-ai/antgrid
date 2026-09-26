// D2: loopback never tunnels. `LocalTransport` declares no
// `openTunnelHttp`/`openTunnelWs` override, so both inherit
// `BufferedAgentTransport`'s NOT_SUPPORTED stub — this pins that neither call
// writes anything to the local socket. Server fixture modeled on
// `local_transport_terminal_attachment_test.dart`'s `_EchoServer`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  test('openTunnelHttp fails NOT_SUPPORTED and writes nothing to the socket', () async {
    final exchange = transport.openTunnelHttp(
      requestId: 'r1',
      checkoutId: 'main',
      head: const {'type': 'tunnel:http-request'},
      bodyLength: 0,
    );

    await expectLater(
      exchange.head,
      throwsA(
        isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'NOT_SUPPORTED'),
      ),
    );
    await expectLater(
      exchange.body,
      emitsError(
        isA<TunnelExchangeFailure>().having((e) => e.code, 'code', 'NOT_SUPPORTED'),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.received, isEmpty);
  });

  test('openTunnelWs fails NOT_SUPPORTED and writes nothing to the socket', () async {
    final channel = transport.openTunnelWs(
      tunnelId: 'ws1',
      checkoutId: 'main',
      open: const {'type': 'tunnel:ws-open'},
    );

    final end = await channel.done;
    expect(end, isA<TunnelWsFailed>());
    expect((end as TunnelWsFailed).failure.code, 'NOT_SUPPORTED');
    expect(await channel.frames.isEmpty, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.received, isEmpty);
  });
}
