import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

    test('proxyRequest sends tunnel:http-request on preview channel '
        'and completes on matching response', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final request = TunnelHttpRequest(
        requestId: 'req-1',
        port: 3000,
        method: 'GET',
        path: '/index.html',
        headers: {'accept': 'text/html'},
      );
      final future = svc.proxyRequest(request);

      // Verify outbound contained tunnel:http-request.
      final sentReq = t.sent.firstWhere(
        (m) => m['type'] == 'tunnel:http-request',
        orElse: () => <String, dynamic>{},
      );
      expect(sentReq['requestId'], 'req-1');

      t.emitJson({
        'type': 'tunnel:http-response',
        'requestId': 'req-1',
        'status': 200,
        'headers': {'content-type': 'text/html'},
        'body': '<html>Hello</html>',
        'bodyEncoding': 'utf8',
      }, channel: 'preview');

      final response = await future;
      expect(response.requestId, 'req-1');
      expect(response.status, 200);
      expect(response.body, '<html>Hello</html>');

      await session.close();
    });

    test('proxyRequest times out when no response arrives', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final request = TunnelHttpRequest(
        requestId: 'req-t',
        port: 3000,
        method: 'GET',
        path: '/slow',
        headers: {},
      );
      final future = svc.proxyRequest(
        request,
        timeout: const Duration(milliseconds: 50),
      );

      expect(future, throwsA(isA<TimeoutException>()));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await session.close();
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

    test('WebSocket frames wait for open and retain browser order', () async {
      final t = _GateFirstWsSendTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      // Not discarded: `openTab` passes allowFallback:false, so a lost port
      // race binds no proxy and every assertion below would then be aimed at
      // whatever else holds the port.
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_blazor');
      addTearDown(() async => ws.close());
      // A gate left held would leave the outbound queue's tail pending forever.
      addTearDown(t.releaseOpen);

      ws.add('signalr-handshake');
      ws.add(<int>[0, 1, 2, 255]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The open send is deliberately held incomplete. No data send may even
      // start while it is still being sealed/routed.
      expect(t.tunnelFrames.map((m) => m['type']), <String>['tunnel:ws-open']);

      // Close the browser socket while the gate still holds: the close frame
      // must queue BEHIND the data it follows, not race ahead of it. Asserting
      // only that a close eventually arrives would pass on plain
      // fire-and-forget sends, which is the property under test.
      await ws.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t.tunnelFrames.map((m) => m['type']), <String>['tunnel:ws-open']);

      t.releaseOpen();
      await _waitUntil(
        () => t.tunnelFrames.any((m) => m['type'] == 'tunnel:ws-close'),
      );
      expect(t.tunnelFrames.map((m) => m['type']), <String>[
        'tunnel:ws-open',
        'tunnel:ws-data',
        'tunnel:ws-data',
        'tunnel:ws-close',
      ]);
      expect(t.tunnelFrames[1]['data'], 'signalr-handshake');
      expect(t.tunnelFrames[1]['binary'], isNull);
      expect(t.tunnelFrames[2]['binary'], isTrue);
      expect(t.tunnelFrames[2]['data'], 'AAEC/w==');
    });

    test('a tunnel whose open cannot be delivered closes the browser socket', () async {
      final t = _GateFirstWsSendTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      // A send with no session keys installed completes SUCCESSFULLY and
      // delivers nothing — the state a relay reconnect passes through, and
      // exactly when a previewed page's own socket reconnects.
      t.setEstablished(false);

      final ws = await WebSocket.connect('ws://localhost:$port/_blazor');
      // The browser must see a real close it can reconnect from, rather than
      // holding a socket against a tunnel the bridge never heard of. Drained
      // rather than awaiting `done`: the close frame is only processed once
      // something reads the stream.
      await ws.drain<void>().timeout(const Duration(seconds: 2));
      expect(t.sent.any((m) => m['type'] == 'tunnel:ws-open'), isFalse);
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

    test(
      'openTab re-detecting an already-open port is a no-op',
      () async {
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
      },
    );

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

    test(
      'openTab portInUse keeps the previously-opened tab live',
      () async {
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
      },
    );

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

    test(
      'ports:update does not auto-open a port with no declared onDetect '
      "field the same as 'notify'",
      () async {
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
      },
    );

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

    test('ports:update never reopens a port the user already closed',
        () async {
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

    test('closing the active tab reassigns focus to a remaining tab',
        () async {
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

    test('dispose cancels subscriptions and fails pending requests', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final request = TunnelHttpRequest(
        requestId: 'req-d',
        port: 3000,
        method: 'GET',
        path: '/',
        headers: {},
      );
      final future = svc.proxyRequest(request);
      // Attach the matcher BEFORE disposing so the unawaited error has a
      // listener and doesn't surface as an unhandled async error.
      final expectation = expectLater(future, throwsA(isA<TimeoutException>()));
      await session.close();
      await expectation;
    });
  });

  group('PreviewService dropped-frame recovery', () {
    /// Longer than [PreviewService]'s 600ms retry grace, which is real elapsed
    /// time (a wall-clock Timer, not a fake async zone).
    const pastGrace = Duration(milliseconds: 750);

    List<Map<String, dynamic>> tunnelSends(FakeAgentTransport t, String id) => t
        .sent
        .where(
          (m) => m['type'] == 'tunnel:http-request' && m['requestId'] == id,
        )
        .toList();

    void respond(FakeAgentTransport t, String id) {
      t.emitJson({
        'type': 'tunnel:http-response',
        'requestId': id,
        'status': 200,
        'headers': const <String, dynamic>{},
        'body': 'ok',
        'bodyEncoding': 'utf8',
      }, channel: 'preview');
    }

    test('re-sends a stalled GET under its original requestId', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-drop',
          port: 3000,
          method: 'GET',
          path: '/app.js',
          headers: {},
        ),
      );
      expect(tunnelSends(t, 'req-drop'), hasLength(1));

      t.emitDroppedFrame();
      await Future<void>.delayed(pastGrace);

      // Same id, so the bridge replays from its outbox instead of re-fetching.
      expect(tunnelSends(t, 'req-drop'), hasLength(2));

      respond(t, 'req-drop');
      expect((await future).status, 200);
      await session.close();
    });

    test('does not re-send a non-idempotent method', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-post',
          port: 3000,
          method: 'POST',
          path: '/api/save',
          headers: {},
          body: '{}',
        ),
      );

      t.emitDroppedFrame();
      await Future<void>.delayed(pastGrace);

      expect(tunnelSends(t, 'req-post'), hasLength(1));

      respond(t, 'req-post');
      await future;
      await session.close();
    });

    test('stops re-sending after the retry cap', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-cap',
          port: 3000,
          method: 'GET',
          path: '/chunk.js',
          headers: {},
        ),
      );

      for (var i = 0; i < 3; i++) {
        t.emitDroppedFrame();
        await Future<void>.delayed(pastGrace);
      }

      // Original + 2 retries. A link that keeps dropping frames must not be
      // handed an unbounded amplification of the same request.
      expect(tunnelSends(t, 'req-cap'), hasLength(3));

      respond(t, 'req-cap');
      await future;
      await session.close();
    });

    test('does not re-send a request that already answered', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-done',
          port: 3000,
          method: 'GET',
          path: '/index.html',
          headers: {},
        ),
      );
      respond(t, 'req-done');
      await future;

      t.emitDroppedFrame();
      await Future<void>.delayed(pastGrace);

      expect(tunnelSends(t, 'req-done'), hasLength(1));
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

class _GateFirstWsSendTransport extends FakeAgentTransport {
  final Completer<void> _openGate = Completer<void>();
  final List<Map<String, dynamic>> started = <Map<String, dynamic>>[];

  /// [started] records every frame the session sends — a project bind alone
  /// emits several before any tunnel exists — so order assertions have to be
  /// made against the tunnel's own frames.
  List<Map<String, dynamic>> get tunnelFrames => [
    for (final m in started)
      if ((m['type'] as String).startsWith('tunnel:')) m,
  ];

  void releaseOpen() {
    if (!_openGate.isCompleted) _openGate.complete();
  }

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    started.add(message);
    if (message['type'] == 'tunnel:ws-open') await _openGate.future;
    await super.send(message, channel: channel);
  }
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
