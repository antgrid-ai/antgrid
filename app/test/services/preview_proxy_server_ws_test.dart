import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/services/preview_proxy_server.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/free_port.dart';

/// Drives a raw upgrade at the proxy and returns the response head (status
/// line + headers). Raw on purpose: `dart:io`'s client tolerates a 101 with no
/// subprotocol echo, Chromium does not, so only the bytes on the wire prove it.
Future<String> _upgrade(int port, {String? protocols}) async {
  final socket = await Socket.connect('localhost', port);
  socket.write(
    'GET /?token=abc HTTP/1.1\r\n'
    'Host: localhost:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    'Sec-WebSocket-Version: 13\r\n'
    '${protocols == null ? '' : 'Sec-WebSocket-Protocol: $protocols\r\n'}'
    '\r\n',
  );
  await socket.flush();

  final buffer = StringBuffer();
  final head = Completer<String>();
  final sub = socket.listen(
    (chunk) {
      buffer.write(latin1.decode(chunk));
      final text = buffer.toString();
      final end = text.indexOf('\r\n\r\n');
      if (end >= 0 && !head.isCompleted) head.complete(text.substring(0, end));
    },
    onDone: () {
      if (!head.isCompleted) head.complete(buffer.toString());
    },
  );
  final result = await head.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  socket.destroy();
  return result;
}

Iterable<String> _headerLines(String head, String name) => head
    .split('\r\n')
    .where((l) => l.toLowerCase().startsWith('${name.toLowerCase()}:'));

void main() {
  late PreviewProxyServer proxy;
  late int bound;
  Map<String, String>? forwarded;

  setUp(() async {
    forwarded = null;
    proxy = PreviewProxyServer(
      targetPort: await freePort(),
      onRequest: (_) async => const TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: {},
        body: '',
        bodyEncoding: 'utf8',
      ),
      onWebSocketConnect: (channel, path, headers) {
        forwarded = headers;
        // The test tears the raw socket down; nothing upstream to relay to.
        channel.sink.close();
      },
    );
    bound = await proxy.start();
  });

  tearDown(() => proxy.stop());

  test('echoes the requested subprotocol on the 101', () async {
    final head = await _upgrade(bound, protocols: 'vite-hmr');

    expect(head, startsWith('HTTP/1.1 101'));
    expect(_headerLines(head, 'sec-websocket-protocol'), hasLength(1));
    expect(head.toLowerCase(), contains('sec-websocket-protocol: vite-hmr'));
  });

  test('echoes the first choice when several are requested', () async {
    final head = await _upgrade(bound, protocols: 'graphql-ws, vite-hmr');

    expect(head, startsWith('HTTP/1.1 101'));
    expect(head.toLowerCase(), contains('sec-websocket-protocol: graphql-ws'));
    expect(head.toLowerCase(), isNot(contains('vite-hmr')));
  });

  test('answers an upgrade with no subprotocol with no echo', () async {
    final head = await _upgrade(bound);

    expect(head, startsWith('HTTP/1.1 101'));
    expect(_headerLines(head, 'sec-websocket-protocol'), isEmpty);
  });

  test('still forwards the full requested list to the tunnel', () async {
    await _upgrade(bound, protocols: 'graphql-ws, vite-hmr');

    // The bridge negotiates upstream from this header; the echo above is the
    // browser's half and must not have consumed it.
    expect(forwarded, isNotNull);
    final key = forwarded!.keys.singleWhere(
      (k) => k.toLowerCase() == 'sec-websocket-protocol',
    );
    expect(forwarded![key], 'graphql-ws, vite-hmr');
  });
}
