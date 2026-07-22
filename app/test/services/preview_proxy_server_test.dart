import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/services/preview_proxy_server.dart';

import '../helpers/free_port.dart';

TunnelHttpResponse _ok() => const TunnelHttpResponse(
  requestId: 'x',
  status: 200,
  headers: {'content-type': 'text/plain'},
  body: 'ok',
  bodyEncoding: 'utf8',
);

void main() {
  test('start() binds the exact target port when free', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => _ok(),
    );

    final bound = await proxy.start();

    expect(bound, port);
    expect(proxy.localPort, port);
    await proxy.stop();
  });

  test(
    'start() throws PortInUseException when the port is taken and no fallback',
    () async {
      final blocker = await ServerSocket.bind('localhost', 0);
      addTearDown(() async => blocker.close());
      final proxy = PreviewProxyServer(
        targetPort: blocker.port,
        onRequest: (_) async => _ok(),
      );

      await expectLater(
        proxy.start(allowFallback: false),
        throwsA(isA<PortInUseException>()),
      );
    },
  );

  test(
    'start(allowFallback: true) binds a different port and rewrites Host',
    () async {
      final blocker = await ServerSocket.bind('localhost', 0);
      addTearDown(() async => blocker.close());
      final targetPort = blocker.port;

      TunnelHttpRequest? captured;
      final proxy = PreviewProxyServer(
        targetPort: targetPort,
        onRequest: (req) async {
          captured = req;
          return _ok();
        },
      );

      final bound = await proxy.start(allowFallback: true);
      addTearDown(() async => proxy.stop());

      expect(bound, isNot(targetPort));

      // Drive a raw HTTP/1.1 request at the fallback origin, sending a
      // capitalized `HOST` with a different value — mimics a browser/WebView.
      // The rewrite must REPLACE it (single host header) and point it at the
      // *target* port, not the fallback bind port.
      final socket = await Socket.connect('localhost', bound);
      socket.write(
        'GET / HTTP/1.1\r\n'
        'HOST: localhost:1\r\n'
        'Connection: close\r\n'
        '\r\n',
      );
      await socket.flush();
      await socket
          .drain<
            void
          >(); // server sends response then closes (Connection: close)
      await socket.close();

      expect(captured, isNotNull);
      final hostKeys = captured!.headers.keys.where(
        (k) => k.toLowerCase() == 'host',
      );
      expect(hostKeys, hasLength(1)); // no duplicate Host/host
      expect(captured!.headers[hostKeys.single], 'localhost:$targetPort');
    },
  );

  test('fallback bind repoints an absolute localhost:<targetPort> redirect at '
      'the proxy origin', () async {
    final blocker = await ServerSocket.bind('localhost', 0);
    addTearDown(() async => blocker.close());
    final targetPort = blocker.port;

    final proxy = PreviewProxyServer(
      targetPort: targetPort,
      // Dev servers emit absolute redirects; over the tunnel the WebView must
      // be sent back through the proxy, not at the phone's own targetPort.
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 302,
        headers: {'location': 'http://localhost:$targetPort/landed'},
        body: '',
        bodyEncoding: 'utf8',
      ),
    );
    final bound = await proxy.start(allowFallback: true);
    addTearDown(() async => proxy.stop());
    expect(bound, isNot(targetPort));

    final socket = await Socket.connect('localhost', bound);
    socket.write(
      'GET / HTTP/1.1\r\n'
      'Host: localhost:$bound\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    await socket.flush();
    final raw = await socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    await socket.close();

    // The redirect must point at the proxy's bind port, not the target port.
    expect(raw, contains('location: http://localhost:$bound/landed'));
    expect(raw, isNot(contains('localhost:$targetPort')));
  });

  test('emits each Set-Cookie value as its own response header', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => const TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: {'content-type': 'text/plain'},
        // A sign-in response sets the session and clears its handoff cookie in
        // one shot — both must survive to the WebView, not just the last.
        setCookies: ['session=xyz; Path=/; HttpOnly', 'csrf=123; Path=/'],
        body: 'ok',
        bodyEncoding: 'utf8',
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final socket = await Socket.connect('localhost', bound);
    socket.write(
      'GET / HTTP/1.1\r\n'
      'Host: localhost:$bound\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    await socket.flush();
    final raw = await socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    await socket.close();

    final cookieLines = raw
        .split('\r\n')
        .where((l) => l.toLowerCase().startsWith('set-cookie:'))
        .toList();
    expect(cookieLines, hasLength(2)); // two distinct header lines, not merged
    expect(raw, contains('session=xyz'));
    expect(raw, contains('csrf=123'));
  });
}
