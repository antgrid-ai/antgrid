import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/preview_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/free_port.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _newSession(
  FakeAgentTransport t, {
  String projectId = 'p',
}) async {
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: projectId,
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await t.dispose(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  group('PreviewService.fromSession', () {
    test(
      'explicit navigation preserves paths on an existing local tab',
      () async {
        final session = await _newSession(_LocalFakeTransport());
        addTearDown(session.close);
        final svc = session.previewService;
        await svc.openTab(3000, scheme: 'https', path: '/dashboard');
        expect(
          svc
              .existingTabNavigationUrl(
                3000,
                scheme: 'https',
                path: '/login?q=1#form',
              )
              .toString(),
          'https://localhost:3000/login?q=1#form',
        );
        expect(
          svc
              .existingTabNavigationUrl(3000, scheme: 'https', path: '/')
              .toString(),
          'https://localhost:3000/',
        );
        expect(
          svc.existingTabNavigationUrl(3000, scheme: 'http', path: '/'),
          isNull,
        );
        expect(
          svc.existingTabNavigationUrl(4000, scheme: 'https', path: '/'),
          isNull,
        );
        await svc.openTab(3000, scheme: 'https');
        expect(
          svc.currentState.activeTab!.currentUrl,
          'https://localhost:3000/dashboard',
        );
      },
    );

    test(
      'explicit navigation uses the existing fallback proxy origin',
      () async {
        final occupied = await ServerSocket.bind('localhost', 0);
        addTearDown(occupied.close);
        final session = await _newSession(FakeAgentTransport());
        addTearDown(session.close);
        final svc = session.previewService;
        await svc.selectPortWithFallback(occupied.port, scheme: 'https');
        final proxyPort = svc.currentState.activeTab!.localProxyPort;
        expect(proxyPort, isNot(occupied.port));
        expect(
          svc
              .existingTabNavigationUrl(
                occupied.port,
                scheme: 'https',
                path: '/login?q=1#form',
              )
              .toString(),
          'http://localhost:$proxyPort/login?q=1#form',
        );
      },
    );

    test('preview:snapshot (heavy) populates state.ports', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      // Subscribe to heavyStream so the focus-state gate fires.
      final sub = session.heavyStream.listen((_) {});

      t.emit('preview:snapshot', {
        'urls': [
          {'port': 3000, 'url': 'http://localhost:3000', 'label': 'web'},
          {'port': 5173, 'url': 'http://localhost:5173'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.ports, hasLength(2));
      expect(svc.currentState.ports[0].port, 3000);
      expect(svc.currentState.ports[0].label, 'web');
      expect(svc.currentState.ports[1].port, 5173);

      await sub.cancel();
      await session.close();
    });

    test('a live preview:url merges like a one-entry snapshot', () async {
      // preview:url used to parse to null and be dropped on the floor, so the
      // live push was dead weight and only the welcome-replayed snapshot fed
      // preview entries in. Both now land through the same merge, so a re-push
      // (the bridge re-sends when a port's scheme is detected after the first
      // entry went out) updates in place instead of duplicating the port.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emit('preview:url', {
        'projectId': 'p',
        'port': 3000,
        'url': 'http://relay.test/preview/3000/',
        'label': 'web',
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.ports.single.label, 'web');
      expect(svc.currentState.ports.single.scheme, isNull);

      t.emit('preview:url', {
        'projectId': 'p',
        'port': 3000,
        'url': 'http://relay.test/preview/3000/',
        'label': 'web',
        'scheme': 'https',
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.ports, hasLength(1));
      expect(svc.currentState.ports.single.scheme, 'https');

      await sub.cancel();
      await session.close();
    });

    test('ports:update (status) populates state.ports', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      t.emitJson({
        'id': 'x',
        'timestamp': 0,
        'type': 'ports:update',
        'projectId': 'p',
        'ports': [
          {'port': 8080, 'label': 'api'},
          {'port': 3000, 'processName': 'node'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.ports, hasLength(2));
      expect(svc.currentState.ports[0].port, 8080);
      expect(svc.currentState.ports[0].label, 'api');
      expect(svc.currentState.ports[1].processName, 'node');

      await session.close();
    });

    // --- Tunneled HTTP: each request opens its own stream-backed exchange ---

    test(
      'proxyRequest opens an exchange whose head carries checkoutId and no '
      'body',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        addTearDown(session.close);
        final svc = session.previewService;

        final future = svc.proxyRequest(
          TunnelHttpRequest(
            requestId: 'req-1',
            port: 3000,
            method: 'GET',
            path: '/index.html',
            headers: {'accept': 'text/html'},
          ),
        );

        expect(t.tunnelHttpOpens, hasLength(1));
        final exchange = t.tunnelHttpOpens.single;
        expect(exchange.requestId, 'req-1');
        expect(exchange.checkoutId, 'main');
        expect(exchange.requestHead.containsKey('body'), isFalse);
        expect(exchange.bodyLength, 0);
        expect(exchange.requestBody, isNull);

        exchange.completeHead(
          const TunnelHttpHead(
            status: 200,
            headers: {'content-type': 'text/html'},
          ),
        );
        exchange.addBody(Uint8List.fromList(utf8.encode('<html>Hello</html>')));
        exchange.endBody();

        final response = await future;
        expect(response.requestId, 'req-1');
        expect(response.status, 200);
        expect(await utf8.decodeStream(response.body), '<html>Hello</html>');
      },
    );

    test("a POST's bytes reach openTunnelHttp.body intact", () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(session.close);
      final svc = session.previewService;

      final bodyBytes = Uint8List.fromList(utf8.encode('{"a":1}'));
      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-post',
          port: 3000,
          method: 'POST',
          path: '/api/save',
          headers: {},
          bodyLength: bodyBytes.length,
          body: Stream.value(bodyBytes),
        ),
      );

      final exchange = t.tunnelHttpOpens.single;
      expect(exchange.bodyLength, bodyBytes.length);
      expect(await exchange.requestBody!.expand((c) => c).toList(), bodyBytes);

      exchange.completeHead(const TunnelHttpHead(status: 200, headers: {}));
      exchange.endBody();
      await future;
    });

    test('a head timeout cancels the exchange', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(session.close);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-t',
          port: 3000,
          method: 'GET',
          path: '/slow',
          headers: {},
        ),
        timeout: const Duration(milliseconds: 50),
      );

      await expectLater(future, throwsA(isA<TimeoutException>()));
      expect(t.tunnelHttpOpens.single.cancelled, isTrue);
    });

    test('a body idle timeout cancels it', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(session.close);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-idle',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
        chunkIdleTimeout: const Duration(milliseconds: 60),
      );
      final exchange = t.tunnelHttpOpens.single;
      exchange.completeHead(const TunnelHttpHead(status: 200, headers: {}));
      await future;

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exchange.cancelled, isTrue);
    });

    test('the browser cancelling the body cancels it', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(session.close);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-cancel',
          port: 3000,
          method: 'GET',
          path: '/big.js',
          headers: {},
        ),
      );
      final exchange = t.tunnelHttpOpens.single;
      exchange.completeHead(const TunnelHttpHead(status: 200, headers: {}));
      final response = await future;

      final sub = response.body.listen((_) {});
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(exchange.cancelled, isTrue);
    });

    test('TRUNCATED surfaces as TunnelStreamException', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(session.close);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-trunc',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      final exchange = t.tunnelHttpOpens.single;
      exchange.completeHead(const TunnelHttpHead(status: 200, headers: {}));
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(
          isA<TunnelStreamException>().having(
            (e) => e.reason,
            'reason',
            'TRUNCATED',
          ),
        ),
      );

      exchange.failWith(const TunnelExchangeFailure('TRUNCATED'));
      await reading;
    });

    test('raw body chunks pass through undecoded', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(session.close);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-raw',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      final exchange = t.tunnelHttpOpens.single;
      exchange.completeHead(const TunnelHttpHead(status: 200, headers: {}));
      final response = await future;
      final collected = utf8.decodeStream(response.body);

      exchange.addBody(Uint8List.fromList(utf8.encode('hello raw')));
      exchange.endBody();

      expect(await collected, 'hello raw');
    });

    test('dispose cancels every live exchange', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final headless = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-d',
          port: 3000,
          method: 'GET',
          path: '/',
          headers: {},
        ),
      );
      // The head is never completed — dispose must not leave it dangling as
      // an unhandled rejection once nothing awaits it any more.
      headless.ignore();
      final headlessExchange = t.tunnelHttpOpens.single;

      final live = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-live',
          port: 3000,
          method: 'GET',
          path: '/live.js',
          headers: {},
        ),
      );
      final liveExchange = t.tunnelHttpOpens.last;
      liveExchange.completeHead(const TunnelHttpHead(status: 200, headers: {}));
      final response = await live;
      unawaited(response.body.drain<void>().catchError((_) {}));

      await session.close();

      expect(headlessExchange.cancelled, isTrue);
      expect(liveExchange.cancelled, isTrue);
    });

    // --- WebSocket tunnel: one native stream per browser socket ---

    test('an inbound close from the bridge carries a forwardable code to '
        'the browser socket', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_hmr');
      await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
      final channel = t.tunnelWsOpens.single;

      channel.closeFromPeer(code: 4001, reason: 'upstream said so');

      await ws.drain<void>().timeout(const Duration(seconds: 2));
      expect(ws.closeCode, 4001);
      expect(ws.closeReason, 'upstream said so');
    });

    test('a close code the browser sink refuses closes it bare', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_hmr');
      await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
      final channel = t.tunnelWsOpens.single;

      // The sink throws an ArgumentError for anything outside 1000 and
      // 3000-4999, which would take the transport subscription down with it;
      // the bridge's own too-large code is exactly such a value.
      channel.closeFromPeer(
        code: 1009,
        reason: 'upstream message too large to tunnel',
      );

      await ws.drain<void>().timeout(const Duration(seconds: 2));
      expect(ws.closeCode, isNot(1009));
    });

    test('a tunnel that fails at open closes the browser socket', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_blazor');
      await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
      t.tunnelWsOpens.single.failWith(
        const TunnelExchangeFailure('NOT_SUPPORTED'),
      );

      // The browser must see a real close it can reconnect from, rather than
      // holding a socket against a tunnel that never opened.
      await ws.drain<void>().timeout(const Duration(seconds: 2));
    });

    test('an outbound WS frame over the queue ceiling aborts the tunnel '
        'before any send', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_hmr');
      await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
      final channel = t.tunnelWsOpens.single;

      ws.add('x' * (1024 * 1024 + 1));
      await ws.drain<void>().timeout(const Duration(seconds: 2));

      expect(channel.sent, isEmpty);
      await _waitUntil(() => channel.aborted);
    });

    test('the queue ceiling counts UTF-8 bytes, not UTF-16 units', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_hmr');
      await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
      final channel = t.tunnelWsOpens.single;

      // 400k three-byte characters is 1.2 MB on the wire and 400k UTF-16
      // units: a length-based ceiling would wave it through.
      ws.add('☃' * 400000);
      await ws.drain<void>().timeout(const Duration(seconds: 5));

      expect(channel.sent, isEmpty);
      await _waitUntil(() => channel.aborted);
    });

    test(
      'WebSocket frames retain browser order and the close follows them',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        addTearDown(() async => session.close());
        final svc = session.previewService;
        final port = await freePort();
        expect(await svc.openTab(port), SelectPortResult.opened);
        addTearDown(() async => svc.closeTab(port));

        final ws = await WebSocket.connect('ws://localhost:$port/_blazor');
        addTearDown(() async => ws.close());
        await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
        final channel = t.tunnelWsOpens.single;

        ws.add('signalr-handshake');
        ws.add(<int>[0, 1, 2, 255]);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(channel.sent.map((f) => f.binary), <bool>[false, true]);
        expect(utf8.decode(channel.sent[0].bytes), 'signalr-handshake');
        expect(channel.sent[1].bytes, <int>[0, 1, 2, 255]);
        // The close hasn't been asked for yet.
        expect(channel.closedWith, isNull);

        await ws.close();
        await _waitUntil(() => channel.closedWith != null);
      },
    );

    test('dispose closes every open WS channel with 1001', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);

      final ws = await WebSocket.connect('ws://localhost:$port/_blazor');
      addTearDown(() async => ws.close());
      await _waitUntil(() => t.tunnelWsOpens.isNotEmpty);
      final channel = t.tunnelWsOpens.single;

      await session.close();

      expect(channel.closedWith?.code, 1001);
    });

    test(
      'openTab in local mode sets the tab currentUrl to localhost:port',
      () async {
        final t = _LocalFakeTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        await svc.openTab(3000);

        expect(svc.currentState.activeTabId, 3000);
        expect(svc.currentState.activeTab?.localProxyPort, 3000);
        expect(svc.currentState.activeTab?.currentUrl, 'http://localhost:3000');

        await svc.closeTab(3000);
        expect(svc.currentState.activeTabId, isNull);
        expect(svc.currentState.tabs, isEmpty);

        await session.close();
      },
    );

    test(
      'openTab with a path lands the tab there, not just the origin',
      () async {
        final t = _LocalFakeTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        await svc.openTab(3000, path: '/dashboard');

        expect(
          svc.currentState.activeTab?.currentUrl,
          'http://localhost:3000/dashboard',
        );

        await session.close();
      },
    );

    test('openTab (relay) binds the exact port and returns opened', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();

      final result = await svc.openTab(port);

      expect(result, SelectPortResult.opened);
      expect(svc.currentState.activeTabId, port);
      expect(svc.currentState.activeTab?.localProxyPort, port);
      expect(svc.currentState.activeTab?.currentUrl, 'http://localhost:$port');

      await svc.closeTab(port);
      await session.close();
    });

    test(
      'openTab (relay) with a path lands the tab there behind the proxy',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        final port = await freePort();
        await svc.openTab(port, path: '/dashboard');

        expect(
          svc.currentState.activeTab?.currentUrl,
          'http://localhost:$port/dashboard',
        );

        await svc.closeTab(port);
        await session.close();
      },
    );

    test('openTab (relay) returns portInUse and leaves state unchanged '
        'when the port is taken', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final blocker = await ServerSocket.bind('localhost', 0);
      addTearDown(() async => blocker.close());

      final result = await svc.openTab(blocker.port);

      expect(result, SelectPortResult.portInUse);
      expect(svc.currentState.activeTabId, isNull);
      expect(svc.currentState.tabs, isEmpty);

      await session.close();
    });

    test('openTab re-detecting an already-open port is a no-op', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port);
      final tabBefore = svc.currentState.activeTab;

      // Same port, same scheme — must not rebind the proxy or replace the
      // tab (the whole point of the no-op: no reload on re-detection).
      final result = await svc.openTab(port);

      expect(result, SelectPortResult.opened);
      expect(svc.currentState.tabs, hasLength(1));
      expect(
        svc.currentState.activeTab?.localProxyPort,
        tabBefore?.localProxyPort,
      );

      await svc.closeTab(port);
      await session.close();
    });

    test(
      'selectPortWithFallback binds a different local port when taken',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        final blocker = await ServerSocket.bind('localhost', 0);
        addTearDown(() async => blocker.close());
        final port = blocker.port;

        await svc.selectPortWithFallback(port);

        expect(svc.currentState.activeTabId, port);
        expect(svc.currentState.activeTab?.localProxyPort, isNotNull);
        expect(svc.currentState.activeTab?.localProxyPort, isNot(port));
        expect(
          svc.currentState.activeTab?.currentUrl,
          'http://localhost:${svc.currentState.activeTab?.localProxyPort}',
        );

        await svc.closeTab(port);
        await session.close();
      },
    );

    test('openTab portInUse keeps the previously-opened tab live', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      // Open port A successfully (exact bind).
      final portA = await freePort();
      final r1 = await svc.openTab(portA);
      expect(r1, SelectPortResult.opened);
      expect(svc.currentState.activeTab?.localProxyPort, portA);

      // Attempt an in-use port B → portInUse. Backgrounded so it can't steal
      // focus from A even on success.
      final blocker = await ServerSocket.bind('localhost', 0);
      addTearDown(() async => blocker.close());
      final r2 = await svc.openTab(blocker.port, focus: false);

      expect(r2, SelectPortResult.portInUse);
      // Port A's tab must remain open AND its proxy still live.
      expect(svc.currentState.activeTabId, portA);
      expect(svc.currentState.tabs, hasLength(1));
      expect(svc.currentState.activeTab?.localProxyPort, portA);
      // Proof the A proxy is still bound: an external bind of portA fails.
      await expectLater(
        ServerSocket.bind('localhost', portA),
        throwsA(isA<SocketException>()),
      );

      await svc.closeTab(portA);
      await session.close();
    });

    test('two detected ports open two tabs; the first focuses, the second '
        'backgrounds', () async {
      // Local transport: openTab's local-mode branch sets state synchronously
      // (no real socket bind to wait on), so the fire-and-forget
      // `unawaited(openTab(...))` inside `_handlePortDetected` has already
      // applied by the time the message-emit call returns.
      final t = _LocalFakeTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emitJson({
        'id': 'd1',
        'timestamp': 0,
        'type': 'port:detected',
        'projectId': 'p',
        'port': 3000,
        'url': 'http://localhost:3000',
        'scheme': 'http',
        'source': 'output',
        'attributes': {'onDetect': 'notify'},
      });
      await Future<void>.delayed(Duration.zero);
      // First detection with no tabs open yet — focuses.
      expect(svc.currentState.activeTabId, 3000);
      expect(svc.currentState.tabs, hasLength(1));

      t.emitJson({
        'id': 'd2',
        'timestamp': 0,
        'type': 'port:detected',
        'projectId': 'p',
        'port': 4000,
        'url': 'http://localhost:4000',
        'scheme': 'http',
        'source': 'output',
        'attributes': {'onDetect': 'notify'},
      });
      await Future<void>.delayed(Duration.zero);
      // Second detection — opens in the background, focus stays on the first.
      expect(svc.currentState.tabs, hasLength(2));
      expect(svc.currentState.activeTabId, 3000);

      await svc.closeTab(3000);
      await svc.closeTab(4000);
      await sub.cancel();
      await session.close();
    });

    test('a silent or ignored detected port does not open a tab', () async {
      final t = _LocalFakeTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      for (final onDetect in ['silent', 'ignore']) {
        t.emitJson({
          'id': 'detected-$onDetect',
          'timestamp': 0,
          'type': 'port:detected',
          'projectId': 'p',
          'port': onDetect == 'silent' ? 3000 : 4000,
          'url': 'http://localhost:${onDetect == 'silent' ? 3000 : 4000}',
          'scheme': 'http',
          'source': 'output',
          'attributes': {'onDetect': onDetect},
        });
      }
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs, isEmpty);

      await sub.cancel();
      await session.close();
    });

    test('demo ports remain listed without opening a localhost tab', () async {
      final t = _LocalFakeTransport();
      final session = await _newSession(t, projectId: kDemoProjectId);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emit('ports:update', {
        'projectId': kDemoProjectId,
        'ports': [
          {'port': 3000, 'scheme': 'http', 'onDetect': 'notify'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.ports.single.port, 3000);
      expect(svc.currentState.tabs, isEmpty);

      await sub.cancel();
      await session.close();
    });

    test('ports:update auto-opens a port whose dev server was already '
        'running before this checkout subscribed', () async {
      // Regression: before this, a port only auto-opened off the live
      // one-shot port:detected event. A dev server started (and detected)
      // BEFORE the preview panel ever subscribed had already missed that
      // event — the port only ever reached state.ports via the ports:update/
      // preview:snapshot hydration, which never opened a tab, forcing the
      // user through manual entry despite the port being known.
      final t = _LocalFakeTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emit('ports:update', {
        'projectId': 'p',
        'ports': [
          {'port': 3000, 'scheme': 'http', 'onDetect': 'notify'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs, hasLength(1));
      expect(svc.currentState.activeTabId, 3000);

      await svc.closeTab(3000);
      await sub.cancel();
      await session.close();
    });

    test('ports:update does not auto-open a port with no declared onDetect '
        "field the same as 'notify'", () async {
      final t = _LocalFakeTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emit('ports:update', {
        'projectId': 'p',
        'ports': [
          {'port': 3000, 'scheme': 'http'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs, hasLength(1));
      expect(svc.currentState.activeTabId, 3000);

      await svc.closeTab(3000);
      await sub.cancel();
      await session.close();
    });

    test('ports:update never auto-opens a silent or ignored port', () async {
      final t = _LocalFakeTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emit('ports:update', {
        'projectId': 'p',
        'ports': [
          {'port': 3000, 'scheme': 'http', 'onDetect': 'silent'},
          {'port': 4000, 'scheme': 'http', 'onDetect': 'ignore'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.tabs, isEmpty);
      expect(svc.currentState.ports, hasLength(2));

      await sub.cancel();
      await session.close();
    });

    test('ports:update never reopens a port the user already closed', () async {
      final t = _LocalFakeTransport();
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});

      t.emit('ports:update', {
        'projectId': 'p',
        'ports': [
          {'port': 3000, 'scheme': 'http', 'onDetect': 'notify'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs, hasLength(1));

      await svc.closeTab(3000);
      expect(svc.currentState.tabs, isEmpty);

      // A resync of the same, still-running port (reconnect, another port
      // changing) must not pop the closed tab back open.
      t.emit('ports:update', {
        'projectId': 'p',
        'ports': [
          {'port': 3000, 'scheme': 'http', 'onDetect': 'notify'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.tabs, isEmpty);

      await sub.cancel();
      await session.close();
    });

    test('closing the active tab reassigns focus to a remaining tab', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final portA = await freePort();
      await svc.openTab(portA);
      final portB = await freePort();
      await svc.openTab(portB, focus: false);
      expect(svc.currentState.activeTabId, portA);

      await svc.closeTab(portA);

      expect(svc.currentState.tabs, hasLength(1));
      expect(svc.currentState.activeTabId, portB);

      await svc.closeTab(portB);
      expect(svc.currentState.activeTabId, isNull);
      await session.close();
    });
  });
}

/// Local-mode fake transport variant for testing the `isLocal` branch in
/// [PreviewService.openTab].
class _LocalFakeTransport extends FakeAgentTransport {
  @override
  bool get isLocal => true;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
