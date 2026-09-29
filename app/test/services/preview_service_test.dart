import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/preview_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
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
      'explicit navigation uses the fallback forwarder origin when the port '
      'is taken locally',
      () async {
        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(occupied.close);
        final session = await _newSession(FakeAgentTransport());
        addTearDown(session.close);
        final svc = session.previewService;
        await svc.openTab(occupied.port);
        final localPort = svc.currentState.activeTab!.localPort;
        expect(localPort, isNot(occupied.port));
        expect(
          svc
              .existingTabNavigationUrl(
                occupied.port,
                scheme: 'http',
                path: '/login?q=1#form',
              )
              .toString(),
          'http://localhost:$localPort/login?q=1#form',
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

    test(
      'openTab in local mode sets the tab currentUrl to localhost:port',
      () async {
        final t = _LocalFakeTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        await svc.openTab(3000);

        expect(svc.currentState.activeTabId, 3000);
        expect(svc.currentState.activeTab?.localPort, 3000);
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

    test('openTab (relay) probes, then forwards the exact port', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port);

      expect(t.tunnelTcpOpens.first.probe, isTrue);
      expect(t.tunnelTcpOpens.first.port, port);
      expect(t.tunnelTcpOpens.first.checkoutId, 'main');
      expect(svc.currentState.activeTabId, port);
      expect(svc.currentState.activeTab?.localPort, port);
      expect(svc.currentState.activeTab?.scheme, 'http');
      expect(svc.currentState.activeTab?.currentUrl, 'http://localhost:$port');

      await svc.closeTab(port);
      await session.close();
    });

    test('a TLS probe opens an https tab and a path lands behind it', () async {
      final t = FakeAgentTransport()..probeTls = true;
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port, path: '/dashboard');

      expect(svc.currentState.activeTab?.scheme, 'https');
      expect(
        svc.currentState.activeTab?.currentUrl,
        'https://localhost:$port/dashboard',
      );

      await svc.closeTab(port);
      await session.close();
    });

    test('a browser connection on the forwarded port opens a tunnel stream',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port);
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.destroy);
      await _waitUntil(() => t.tunnelTcpOpens.length == 2);

      final conn = t.tunnelTcpOpens.last;
      expect(conn.probe, isFalse);
      expect(conn.port, port);
      expect(conn.checkoutId, 'main');

      await svc.closeTab(port);
      await _waitUntil(() => conn.aborted);
      await session.close();
    });

    test('an unreachable probe opens no tab and reports the error', () async {
      final t = FakeAgentTransport()
        ..probeFailure = const TunnelExchangeFailure(
          'UNREACHABLE',
          message: 'connection refused',
        );
      final session = await _newSession(t);
      final svc = session.previewService;

      await svc.openTab(3000);

      expect(svc.currentState.tabs, isEmpty);
      expect(svc.currentState.activeTabId, isNull);
      expect(svc.currentState.error, contains('3000'));

      await session.close();
    });

    test('openTab re-detecting an already-open port is a no-op', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port);
      final tabBefore = svc.currentState.activeTab;

      await svc.openTab(port);

      expect(t.tunnelTcpOpens, hasLength(1));
      expect(svc.currentState.tabs, hasLength(1));
      expect(svc.currentState.activeTab?.localPort, tabBefore?.localPort);

      await svc.closeTab(port);
      await session.close();
    });

    test('openTab binds a different local port when the port is taken',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => blocker.close());
      final port = blocker.port;

      await svc.openTab(port);

      expect(svc.currentState.activeTabId, port);
      expect(svc.currentState.activeTab?.localPort, isNot(port));
      expect(
        svc.currentState.activeTab?.currentUrl,
        'http://localhost:${svc.currentState.activeTab?.localPort}',
      );

      await svc.closeTab(port);
      await session.close();
    });

    test('closing a tab releases its forwarded port', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port);
      await expectLater(
        ServerSocket.bind(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );

      await svc.closeTab(port);

      final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close();
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

    test('a probed https tab is reused when the caller hints http', () async {
      final t = FakeAgentTransport()..probeTls = true;
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      await svc.openTab(port);
      await svc.openTab(port, scheme: 'http');

      expect(t.tunnelTcpOpens.where((c) => c.probe), hasLength(1));
      expect(svc.currentState.activeTab?.scheme, 'https');
      expect(
        svc.existingTabNavigationUrl(port, scheme: 'http', path: '/x'),
        Uri.parse('https://localhost:$port/x'),
      );

      await svc.closeTab(port);
      await session.close();
    });

    test('concurrent opens of one port share a single probe and forwarder',
        () async {
      final t = FakeAgentTransport()..probeTls = null;
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      final first = svc.openTab(port, focus: false);
      final second = svc.openTab(port);
      await Future<void>.delayed(Duration.zero);
      expect(t.tunnelTcpOpens, hasLength(1));

      t.tunnelTcpOpens.single.completeReady(tls: false);
      await Future.wait([first, second]);

      expect(svc.currentState.tabs, hasLength(1));
      expect(svc.currentState.activeTabId, port);
      await svc.closeTab(port);
      final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close();
      await session.close();
    });

    test('closing a tab while its probe is pending keeps it closed', () async {
      final t = FakeAgentTransport()..probeTls = null;
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      final opening = svc.openTab(port);
      await Future<void>.delayed(Duration.zero);
      await svc.closeTab(port);
      t.tunnelTcpOpens.single.completeReady(tls: false);
      await opening;

      expect(svc.currentState.tabs, isEmpty);
      final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close();
      await session.close();
    });

    test('a reopen after a close supersedes the stale open', () async {
      final t = FakeAgentTransport()..probeTls = null;
      final session = await _newSession(t);
      final svc = session.previewService;

      final port = await freePort();
      final stale = svc.openTab(port);
      await Future<void>.delayed(Duration.zero);
      await svc.closeTab(port);
      final fresh = svc.openTab(port);
      await Future<void>.delayed(Duration.zero);
      expect(t.tunnelTcpOpens, hasLength(2));

      t.tunnelTcpOpens[0].completeReady(tls: false);
      await stale;
      expect(svc.currentState.tabs, isEmpty);
      t.tunnelTcpOpens[1].completeReady(tls: false);
      await fresh;

      expect(svc.currentState.tabs, hasLength(1));
      await svc.closeTab(port);
      final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close();
      await session.close();
    });

    test('a failed auto-open sets no panel error and is retried later',
        () async {
      final t = FakeAgentTransport()
        ..probeFailure = const TunnelExchangeFailure('UNREACHABLE');
      final session = await _newSession(t);
      final svc = session.previewService;
      final sub = session.heavyStream.listen((_) {});
      final port = await freePort();

      void announce() => t.emit('ports:update', {
        'projectId': 'p',
        'ports': [
          {'port': port, 'scheme': 'http', 'onDetect': 'notify'},
        ],
      });

      announce();
      await _waitUntil(() => t.tunnelTcpOpens.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(svc.currentState.tabs, isEmpty);
      expect(svc.currentState.error, isNull);

      t.probeFailure = null;
      announce();
      await _waitUntil(() => svc.currentState.tabs.length == 1);

      await svc.closeTab(port);
      await sub.cancel();
      await session.close();
    });

    test('a probe that never answers times out with an error', () async {
      final t = FakeAgentTransport()..probeTls = null;
      final session = await _newSession(t);
      final svc = PreviewService.fromSession(
        session,
        probeTimeout: const Duration(milliseconds: 50),
      );

      await svc.openTab(3000);

      expect(svc.currentState.tabs, isEmpty);
      expect(svc.currentState.error, contains('3000'));
      expect(t.tunnelTcpOpens.single.aborted, isTrue);

      await svc.dispose();
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
