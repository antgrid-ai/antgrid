import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/services/preview_proxy_server.dart';

import '../helpers/free_port.dart';

TunnelHttpResponse _ok() => TunnelHttpResponse(
  requestId: 'x',
  status: 200,
  headers: const {'content-type': 'text/plain'},
  body: Stream.value(utf8.encode('ok')),
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
        body: const Stream.empty(),
      ),
    );
    final bound = await proxy.start(allowFallback: true);
    addTearDown(() async => proxy.stop());
    expect(bound, isNot(targetPort));

    final raw = await _get(bound);

    // The redirect must point at the proxy's bind port, not the target port.
    expect(raw, contains('location: http://localhost:$bound/landed'));
    expect(raw, isNot(contains('localhost:$targetPort')));
  });

  test('downgrades an https absolute redirect to the plain-http proxy origin '
      'even on an exact-port bind', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      targetScheme: 'https',
      // An https dev server redirects absolutely with its own scheme; the
      // proxy serves plain HTTP even on the exact port, so `https://` must
      // not survive — the WebView would attempt TLS against the proxy.
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 302,
        headers: {'location': 'https://localhost:$port/login'},
        body: const Stream.empty(),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());
    expect(bound, port);

    final raw = await _get(bound);

    expect(raw, contains('location: http://localhost:$port/login'));
    expect(raw, isNot(contains('https://localhost')));
  });

  test('emits each Set-Cookie value as its own response header', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: {'content-type': 'text/plain'},
        // A sign-in response sets the session and clears its handoff cookie in
        // one shot — both must survive to the WebView, not just the last.
        setCookies: ['session=xyz; Path=/; HttpOnly', 'csrf=123; Path=/'],
        body: Stream.value(utf8.encode('ok')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    final cookieLines = raw
        .split('\r\n')
        .where((l) => l.toLowerCase().startsWith('set-cookie:'))
        .toList();
    expect(cookieLines, hasLength(2)); // two distinct header lines, not merged
    expect(raw, contains('session=xyz'));
    expect(raw, contains('csrf=123'));
  });

  test('downgrades Secure cookies from an https target', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      targetScheme: 'https',
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: {'content-type': 'text/plain'},
        // What an https dev server's sign-in sets. The WebView is served plain
        // HTTP, where a Secure cookie is dropped without a word, so the session
        // would never be stored and the sign-in would loop.
        setCookies: [
          '.Session=xyz; path=/; secure; httponly',
          'handoff=; path=/; Secure; SameSite=None',
        ],
        body: Stream.value(utf8.encode('ok')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(raw.toLowerCase(), isNot(contains('secure')));
    expect(raw, contains('.Session=xyz'));
    expect(raw, contains('httponly'));
    // SameSite=None is only legal alongside Secure, so it has to move too.
    expect(raw.toLowerCase(), isNot(contains('samesite=none')));
    expect(raw, contains('SameSite=Lax'));
  });

  // The one cookie the downgrade must NOT touch: the two prefixes make Secure
  // part of the cookie's validity, so stripping it has the browser reject the
  // cookie outright — the sign-in loop the downgrade exists to prevent, now
  // caused by it.
  test('leaves a __Host-/__Secure- prefixed cookie intact', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      targetScheme: 'https',
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: {'content-type': 'text/plain'},
        setCookies: [
          '__Host-bff=abc; Path=/; Secure; HttpOnly; SameSite=None',
          '__Secure-rt=def; Path=/; Secure',
        ],
        body: Stream.value(utf8.encode('ok')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(raw, contains('__Host-bff=abc; Path=/; Secure; HttpOnly'));
    expect(raw, contains('SameSite=None'));
    expect(raw, contains('__Secure-rt=def; Path=/; Secure'));
  });

  test('passes a plain-http target cookies through untouched', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: {'content-type': 'text/plain'},
        setCookies: ['sid=1; Path=/; Secure'],
        body: Stream.value(utf8.encode('ok')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    expect(await _get(bound), contains('sid=1; Path=/; Secure'));
  });

  test('forwards the browser handshake headers on a WebSocket upgrade', () async {
    final port = await freePort();
    Map<String, String>? captured;
    final proxy = PreviewProxyServer(
      targetPort: port,
      targetScheme: 'https',
      onRequest: (_) async => _ok(),
      onWebSocketConnect: (channel, path, headers) {
        captured = headers;
        channel.sink.close();
      },
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final ws = await WebSocket.connect(
      'ws://localhost:$bound/_blazor',
      headers: {'cookie': '.Session=xyz'},
    );
    addTearDown(() async => ws.close());
    await ws.done.timeout(const Duration(seconds: 5), onTimeout: () => null);

    // A cookie-authenticated dev server reads its session off the handshake, so
    // dropping it opens the socket anonymously behind an authenticated page.
    expect(captured?['cookie'], '.Session=xyz');
    // The WebView's origin is this plain-http proxy; a dev server checking
    // Origin would read that as cross-site.
    expect(captured?['origin'], 'https://localhost:$port');
  });

  test('advertises the gzip body encoding on every tunneled request', () async {
    final port = await freePort();
    TunnelHttpRequest? captured;
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (req) async {
        captured = req;
        return _ok();
      },
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    await _get(bound);

    // The bridge only compresses when asked, so dropping this silently reverts
    // every preview to the uncompressed path.
    expect(captured!.acceptEncodings, contains(kTunnelGzipEncoding));
    expect(
      captured!.toJson()['acceptEncodings'],
      contains(kTunnelGzipEncoding),
    );
  });

  test('serves the decoded bytes without claiming an encoding', () async {
    final port = await freePort();
    const source = 'body { color: red; }\n';
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'text/css'},
        body: Stream.value(utf8.encode(source)),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(raw, contains(source));
    // The WebView is handed plain bytes, so no encoding header may claim
    // otherwise — a stale content-encoding makes WebKit gunzip twice.
    expect(raw.toLowerCase(), isNot(contains('content-encoding')));
  });

  test('restates utf-8 for charset-less text on the byte path', () async {
    final port = await freePort();
    // Non-ASCII under a charset-less text type: every body is bytes now, so
    // shelf stamps no charset of its own and this would reach the WebView as
    // latin-1 without the restatement.
    const source = '<p>héllo wörld ☃</p>';
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'text/html'},
        body: Stream.value(utf8.encode(source)),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(
      raw.toLowerCase(),
      contains('content-type: text/html; charset=utf-8'),
    );
    expect(raw, contains(source));
  });

  test('does not restate a charset the dev server already pinned', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      // A charset we cannot silently rewrite to utf-8 — and binary types must
      // not gain a charset parameter at all.
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'text/html; charset=iso-8859-1'},
        body: Stream.value(utf8.encode('<p>plain</p>')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(
      raw.toLowerCase(),
      contains('content-type: text/html; charset=iso-8859-1'),
    );
  });

  test('leaves a binary content-type without a charset', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'application/wasm'},
        body: Stream.value(utf8.encode(' asm binary')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(raw.toLowerCase(), contains('content-type: application/wasm'));
    expect(raw.toLowerCase(), isNot(contains('charset')));
  });

  // dart:io buffers an outgoing response until 8 KiB is pending or the body
  // ends, so a slice has to clear that buffer to be observable at all. A
  // production slice is 192 KiB raw and always does.
  final slice = List<int>.filled(16 * 1024, 0x61);

  test('streams the body as chunks arrive', () async {
    final port = await freePort();
    final controller = StreamController<List<int>>();
    addTearDown(() async => controller.close());
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'text/plain'},
        body: controller.stream,
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final socket = await Socket.connect('localhost', bound);
    addTearDown(() async => socket.destroy());
    socket.write('GET / HTTP/1.1\r\nHost: localhost:$bound\r\n\r\n');
    await socket.flush();

    var received = 0;
    final done = Completer<void>();
    socket.cast<List<int>>().listen((bytes) {
      received += bytes.length;
      if (received >= slice.length && !done.isCompleted) done.complete();
    }, onError: (_) {});

    controller.add(slice);
    // The point of the stream: the client has bytes while the body is still
    // open, not only once it closes.
    await done.future.timeout(const Duration(seconds: 5));
    expect(controller.isClosed, isFalse);
  });

  // Deliberately uncaught in the proxy: dart:io must destroy the connection
  // without the terminating chunk, so the browser sees an incomplete transfer
  // rather than a complete-looking truncated bundle it would cache.
  test('a body error aborts the connection without a terminating chunk',
      () async {
    final port = await freePort();
    final controller = StreamController<List<int>>();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'text/plain'},
        body: controller.stream,
      ),
    );
    // shelf_io only installs its own guard when it is started from the root
    // error zone, which a test never is, so the deliberate stream error
    // surfaces here instead of in its log line. Binding inside a guarded zone
    // is what puts it back where production has it.
    final started = Completer<int>();
    final reported = <Object>[];
    unawaited(runZonedGuarded(() async {
      started.complete(await proxy.start());
    }, (error, _) => reported.add(error)));
    final bound = await started.future;
    addTearDown(() async => proxy.stop());

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(Uri.parse('http://localhost:$bound/'));
    final pendingResponse = request.close();
    controller.add(slice);
    final response = await pendingResponse;

    final reading = expectLater(
      response.fold<int>(0, (n, chunk) => n + chunk.length),
      throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
    );
    controller.addError(
      const TunnelStreamException('x', 'chunk 2 arrived, expected 1'),
    );
    await controller.close();
    await reading;
    expect(reported, contains(isA<TunnelStreamException>()));
  });

  test('a client disconnect cancels the body stream', () async {
    final port = await freePort();
    final cancelled = Completer<void>();
    final controller = StreamController<List<int>>(
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {'content-type': 'text/plain'},
        body: controller.stream,
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final socket = await Socket.connect('localhost', bound);
    socket.write('GET / HTTP/1.1\r\nHost: localhost:$bound\r\n\r\n');
    await socket.flush();
    socket.listen((_) {}, onError: (_) {});
    controller.add(slice);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    socket.destroy();

    // dart:io only learns the socket is dead on its next write, so the cancel
    // lags a slice.
    for (var i = 0; i < 40 && !cancelled.isCompleted; i++) {
      controller.add(slice);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await cancelled.future.timeout(const Duration(seconds: 2));
  });

  test('set-cookie and location are rewritten off the head of a streaming '
      'body', () async {
    final blocker = await ServerSocket.bind('localhost', 0);
    addTearDown(() async => blocker.close());
    final targetPort = blocker.port;
    final controller = StreamController<List<int>>();
    addTearDown(() async => controller.close());
    final proxy = PreviewProxyServer(
      targetPort: targetPort,
      targetScheme: 'https',
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 302,
        headers: {'location': 'http://localhost:$targetPort/landed'},
        setCookies: const ['sid=1; Path=/; Secure'],
        // Never completes: every head rewrite must be done off the start
        // frame alone, with no body byte to wait for.
        body: controller.stream,
      ),
    );
    final bound = await proxy.start(allowFallback: true);
    addTearDown(() async => proxy.stop());

    final socket = await Socket.connect('localhost', bound);
    addTearDown(() async => socket.destroy());
    socket.write('GET / HTTP/1.1\r\nHost: localhost:$bound\r\n\r\n');
    await socket.flush();

    final head = StringBuffer();
    final gotHead = Completer<void>();
    socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((s) {
          head.write(s);
          if (head.toString().contains('\r\n\r\n') && !gotHead.isCompleted) {
            gotHead.complete();
          }
        }, onError: (_) {});
    controller.add(slice);
    await gotHead.future.timeout(const Duration(seconds: 5));

    expect(
      head.toString(),
      contains('location: http://localhost:$bound/landed'),
    );
    expect(head.toString().toLowerCase(), isNot(contains('; secure')));
    expect(head.toString(), contains('sid=1'));
  });

  // A response the dev server sent without a content-type keeps dart:io's own
  // default rather than gaining one from the tunnel: nothing on the byte path
  // may name a type the origin did not.
  test('a body with no content-type gains no tunnel-invented type', () async {
    final port = await freePort();
    final proxy = PreviewProxyServer(
      targetPort: port,
      onRequest: (_) async => TunnelHttpResponse(
        requestId: 'x',
        status: 200,
        headers: const {},
        body: Stream.value(utf8.encode('<p>hi</p>')),
      ),
    );
    final bound = await proxy.start();
    addTearDown(() async => proxy.stop());

    final raw = await _get(bound);

    expect(
      raw.toLowerCase(),
      isNot(contains('content-type: application/octet-stream')),
    );
    expect(raw, contains('<p>hi</p>'));
  });
}

Future<String> _get(int port) async {
  final socket = await Socket.connect('localhost', port);
  socket.write(
    'GET / HTTP/1.1\r\n'
    'Host: localhost:$port\r\n'
    'Connection: close\r\n'
    '\r\n',
  );
  await socket.flush();
  final raw = await socket
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  await socket.close();
  return raw;
}
