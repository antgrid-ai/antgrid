import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
      'selectPort in local mode sets currentUrl to localhost:port',
      () async {
        final t = _LocalFakeTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        await svc.selectPort(3000);

        expect(svc.currentState.selectedPort, 3000);
        expect(svc.currentState.localProxyPort, 3000);
        expect(svc.currentState.currentUrl, 'http://localhost:3000');

        await svc.deselectPort();
        expect(svc.currentState.selectedPort, isNull);
        expect(svc.currentState.currentUrl, isNull);

        await session.close();
      },
    );

    test(
      'selectPort (relay) binds the exact port and returns opened',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        final port = await freePort();

        final result = await svc.selectPort(port);

        expect(result, SelectPortResult.opened);
        expect(svc.currentState.selectedPort, port);
        expect(svc.currentState.localProxyPort, port);
        expect(svc.currentState.currentUrl, 'http://localhost:$port');

        await svc.deselectPort();
        await session.close();
      },
    );

    test('selectPort (relay) returns portInUse and leaves state unchanged '
        'when the port is taken', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final blocker = await ServerSocket.bind('localhost', 0);
      addTearDown(() async => blocker.close());

      final result = await svc.selectPort(blocker.port);

      expect(result, SelectPortResult.portInUse);
      expect(svc.currentState.selectedPort, isNull);
      expect(svc.currentState.localProxyPort, isNull);
      expect(svc.currentState.currentUrl, isNull);

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

        expect(svc.currentState.selectedPort, port);
        expect(svc.currentState.localProxyPort, isNotNull);
        expect(svc.currentState.localProxyPort, isNot(port));
        expect(
          svc.currentState.currentUrl,
          'http://localhost:${svc.currentState.localProxyPort}',
        );

        await svc.deselectPort();
        await session.close();
      },
    );

    test(
      'selectPort portInUse keeps the previously-opened preview live',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = session.previewService;

        // Open port A successfully (exact bind).
        final portA = await freePort();
        final r1 = await svc.selectPort(portA);
        expect(r1, SelectPortResult.opened);
        expect(svc.currentState.localProxyPort, portA);

        // Attempt an in-use port B → portInUse.
        final blocker = await ServerSocket.bind('localhost', 0);
        addTearDown(() async => blocker.close());
        final r2 = await svc.selectPort(blocker.port);

        expect(r2, SelectPortResult.portInUse);
        // The previous preview must remain selected AND its proxy still live.
        expect(svc.currentState.selectedPort, portA);
        expect(svc.currentState.localProxyPort, portA);
        expect(svc.currentState.currentUrl, 'http://localhost:$portA');
        // Proof the A proxy is still bound: an external bind of portA fails.
        await expectLater(
          ServerSocket.bind('localhost', portA),
          throwsA(isA<SocketException>()),
        );

        await svc.deselectPort();
        await session.close();
      },
    );

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
}

/// Local-mode fake transport variant for testing the `isLocal` branch in
/// [PreviewService.selectPort].
class _LocalFakeTransport extends FakeAgentTransport {
  @override
  bool get isLocal => true;
}
