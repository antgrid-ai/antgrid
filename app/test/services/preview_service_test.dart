import 'dart:async';
import 'dart:convert';
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

/// Emit `tunnel:http-start` for [id] on the preview channel. [data] is raw
/// bytes; they are encoded the way the bridge would.
void _start(
  FakeAgentTransport t,
  String id, {
  String data = '',
  bool last = false,
  int status = 200,
  Map<String, dynamic> headers = const {},
  List<String> setCookies = const [],
  bool gzipped = false,
}) {
  t.emitJson({
    'type': 'tunnel:http-start',
    'requestId': id,
    'status': status,
    'headers': headers,
    if (setCookies.isNotEmpty) 'setCookies': setCookies,
    'data': _encodeSlice(data, gzipped),
    'bodyEncoding': gzipped ? kTunnelGzipEncoding : 'base64',
    if (last) 'last': true,
  }, channel: 'preview');
}

void _chunk(
  FakeAgentTransport t,
  String id,
  int seq,
  String data, {
  bool gzipped = false,
  String? encoding,
}) {
  t.emitJson({
    'type': 'tunnel:http-chunk',
    'requestId': id,
    'seq': seq,
    'data': encoding == null
        ? _encodeSlice(data, gzipped)
        : base64Encode(utf8.encode(data)),
    'bodyEncoding': encoding ?? (gzipped ? kTunnelGzipEncoding : 'base64'),
  }, channel: 'preview');
}

void _end(FakeAgentTransport t, String id, int chunks, {String? error}) {
  t.emitJson({
    'type': 'tunnel:http-end',
    'requestId': id,
    'chunks': chunks,
    'error': ?error,
  }, channel: 'preview');
}

String _encodeSlice(String data, bool gzipped) {
  if (data.isEmpty) return '';
  final bytes = utf8.encode(data);
  return base64Encode(gzipped ? gzip.encode(bytes) : bytes);
}

List<Map<String, dynamic>> _cancelsFor(FakeAgentTransport t, String id) => t.sent
    .where((m) => m['type'] == 'tunnel:http-cancel' && m['requestId'] == id)
    .toList();

List<Map<String, dynamic>> _allCancels(FakeAgentTransport t) =>
    t.sent.where((m) => m['type'] == 'tunnel:http-cancel').toList();

List<Map<String, dynamic>> _requests(FakeAgentTransport t) =>
    t.sent.where((m) => m['type'] == 'tunnel:http-request').toList();

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
    test('explicit navigation preserves paths on an existing local tab', () async {
      final session = await _newSession(_LocalFakeTransport());
      addTearDown(session.close);
      final svc = session.previewService;
      await svc.openTab(3000, scheme: 'https', path: '/dashboard');
      expect(
        svc.existingTabNavigationUrl(3000, scheme: 'https', path: '/login?q=1#form').toString(),
        'https://localhost:3000/login?q=1#form',
      );
      expect(svc.existingTabNavigationUrl(3000, scheme: 'https', path: '/').toString(),
          'https://localhost:3000/');
      expect(svc.existingTabNavigationUrl(3000, scheme: 'http', path: '/'), isNull);
      expect(svc.existingTabNavigationUrl(4000, scheme: 'https', path: '/'), isNull);
      await svc.openTab(3000, scheme: 'https');
      expect(svc.currentState.activeTab!.currentUrl, 'https://localhost:3000/dashboard');
    });

    test('explicit navigation uses the existing fallback proxy origin', () async {
      final occupied = await ServerSocket.bind('localhost', 0);
      addTearDown(occupied.close);
      final session = await _newSession(FakeAgentTransport());
      addTearDown(session.close);
      final svc = session.previewService;
      await svc.selectPortWithFallback(occupied.port, scheme: 'https');
      final proxyPort = svc.currentState.activeTab!.localProxyPort;
      expect(proxyPort, isNot(occupied.port));
      expect(svc.existingTabNavigationUrl(occupied.port, scheme: 'https', path: '/login?q=1#form').toString(),
          'http://localhost:$proxyPort/login?q=1#form');
    });

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
        'and completes on a single-frame start', () async {
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

      _start(
        t,
        'req-1',
        data: '<html>Hello</html>',
        last: true,
        headers: const {'content-type': 'text/html'},
      );

      final response = await future;
      expect(response.requestId, 'req-1');
      expect(response.status, 200);
      expect(await utf8.decodeStream(response.body), '<html>Hello</html>');

      await session.close();
    });

    test('a streamed response completes at start and delivers chunks in '
        'order', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-s',
          port: 3000,
          method: 'GET',
          path: '/bundle.js',
          headers: {},
        ),
      );
      _start(t, 'req-s', data: 'Hel');
      final response = await future;
      final collected = utf8.decodeStream(response.body);

      _chunk(t, 'req-s', 1, 'lo');
      // Per-slice encoding: the bridge decides it slice by slice.
      _chunk(t, 'req-s', 2, ' world', gzipped: true);
      _end(t, 'req-s', 2);

      expect(await collected, 'Hello world');
      expect(_cancelsFor(t, 'req-s'), isEmpty);

      await session.close();
    });

    test('proxyRequest times out when no start arrives', () async {
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

      await expectLater(future, throwsA(isA<TimeoutException>()));
      // The bridge may still be fetching for an id nothing will read.
      expect(_cancelsFor(t, 'req-t'), hasLength(1));

      await session.close();
    });

    test('a chunk gap aborts the body and sends tunnel:http-cancel', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-gap',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-gap', data: 'a');
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(isA<TunnelStreamException>()),
      );

      _chunk(t, 'req-gap', 2, 'skipped one');
      await reading;
      expect(_cancelsFor(t, 'req-gap'), hasLength(1));

      // Nothing arriving late may buy a second cancel.
      _chunk(t, 'req-gap', 3, 'later');
      _end(t, 'req-gap', 3);
      expect(_cancelsFor(t, 'req-gap'), hasLength(1));

      await session.close();
    });

    test("an end whose count disagrees aborts the body", () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-count',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-count', data: 'a');
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(isA<TunnelStreamException>()),
      );

      _chunk(t, 'req-count', 1, 'b');
      // The bridge sent two; only one arrived — the hole a FIFO cannot show.
      _end(t, 'req-count', 2);
      await reading;
      expect(_cancelsFor(t, 'req-count'), hasLength(1));

      await session.close();
    });

    test('an error end aborts the body without a cancel', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-err',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-err', data: 'a');
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(
          isA<TunnelStreamException>().having(
            (e) => e.reason,
            'reason',
            contains('upstream body stalled'),
          ),
        ),
      );

      _end(t, 'req-err', 1, error: 'upstream body stalled');
      await reading;
      // The bridge already ended its own run; a cancel would tell it what it
      // just told us.
      expect(_cancelsFor(t, 'req-err'), isEmpty);

      await session.close();
    });

    test('no chunk within the idle timeout aborts the body and cancels',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final started = DateTime.now();
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
      _start(t, 'req-idle', data: 'a');
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(isA<TunnelStreamException>()),
      );

      // The clock is per chunk, not per request: a chunk at 40ms buys another
      // full window.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      _chunk(t, 'req-idle', 1, 'b');
      await reading;

      expect(
        DateTime.now().difference(started).inMilliseconds,
        greaterThan(90),
      );
      expect(_cancelsFor(t, 'req-idle'), hasLength(1));

      await session.close();
    });

    test('an undecodable chunk aborts the body', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-enc',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-enc', data: 'a');
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(
          isA<TunnelStreamException>().having(
            (e) => e.reason,
            'reason',
            contains('utf8'),
          ),
        ),
      );

      _chunk(t, 'req-enc', 1, 'b', encoding: 'utf8');
      await reading;
      expect(_cancelsFor(t, 'req-enc'), hasLength(1));

      await session.close();
    });

    test('a chunk before its start cancels the id and re-sends a GET under a '
        'fresh id at once', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-lost',
          port: 3000,
          method: 'GET',
          path: '/app.js',
          headers: {'accept': '*/*'},
        ),
      );
      expect(_requests(t), hasLength(1));

      // No grace: FIFO puts a start ahead of its own chunks, so this proves
      // the start was dropped and there is nothing to wait for.
      _chunk(t, 'req-lost', 1, 'orphan');
      await Future<void>.delayed(Duration.zero);

      expect(_cancelsFor(t, 'req-lost'), hasLength(1));
      expect(_requests(t), hasLength(2));
      final resent = _requests(t)[1];
      expect(resent['requestId'], isNot('req-lost'));
      expect(resent['path'], '/app.js');
      expect(resent['method'], 'GET');
      expect(resent['headers'], {'accept': '*/*'});

      _start(t, resent['requestId'] as String, data: 'fresh', last: true);
      final response = await future;
      expect(await utf8.decodeStream(response.body), 'fresh');

      // The old id is remembered as cancelled, so its late start buys nothing.
      _start(t, 'req-lost', data: 'stale', last: true);
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'req-lost'), hasLength(1));
      expect(_requests(t), hasLength(2));

      await session.close();
    });

    test('frames of the cancelled run neither re-trigger recovery nor reach '
        'the body', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-old',
          port: 3000,
          method: 'GET',
          path: '/app.js',
          headers: {},
        ),
      );
      _chunk(t, 'req-old', 1, 'stale-1');
      await Future<void>.delayed(Duration.zero);
      final freshId = _requests(t)[1]['requestId'] as String;

      // The cancelled run keeps streaming for as long as its window holds —
      // past any grace a wall clock could give it.
      _chunk(t, 'req-old', 2, 'stale-2');
      await Future<void>.delayed(const Duration(milliseconds: 750));
      _chunk(t, 'req-old', 3, 'stale-3');
      _end(t, 'req-old', 3);
      await Future<void>.delayed(Duration.zero);

      expect(_cancelsFor(t, 'req-old'), hasLength(1));
      expect(_requests(t), hasLength(2));

      _start(t, freshId, data: 'new-');
      final response = await future;
      final collected = utf8.decodeStream(response.body);
      _chunk(t, freshId, 1, 'body');
      // The old run's end arriving after the fresh start changes nothing.
      _end(t, 'req-old', 3);
      _end(t, freshId, 1);

      expect(await collected, 'new-body');

      await session.close();
    });

    test('a lost start on the re-sent run recovers once more, then fails',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-r0',
          port: 3000,
          method: 'GET',
          path: '/app.js',
          headers: {},
        ),
      );
      final failing = expectLater(
        future,
        throwsA(isA<TunnelStreamException>()),
      );

      _chunk(t, 'req-r0', 1, 'x');
      await Future<void>.delayed(Duration.zero);
      final id2 = _requests(t)[1]['requestId'] as String;
      _chunk(t, id2, 1, 'x');
      await Future<void>.delayed(Duration.zero);
      final id3 = _requests(t)[2]['requestId'] as String;
      _chunk(t, id3, 1, 'x');

      await failing;
      expect(_requests(t), hasLength(3));
      expect(_allCancels(t), hasLength(3));

      await session.close();
    });

    test('a head timeout after a re-key cancels the fresh id and leaves '
        'nothing pending', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-rekeyed',
          port: 3000,
          method: 'GET',
          path: '/app.js',
          headers: {},
        ),
        timeout: const Duration(milliseconds: 80),
      );
      final failing = expectLater(future, throwsA(isA<TimeoutException>()));

      _chunk(t, 'req-rekeyed', 1, 'orphan');
      await Future<void>.delayed(Duration.zero);
      final freshId = _requests(t)[1]['requestId'] as String;

      await failing;
      // The one head timer keeps running across the re-key, and what it reaps
      // is the entry under its CURRENT id.
      expect(_cancelsFor(t, freshId), hasLength(1));
      // A stray frame for the fresh id is now unknown and answered by nothing.
      _chunk(t, freshId, 1, 'late');
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, freshId), hasLength(1));
      expect(_requests(t), hasLength(2));

      await session.close();
    });

    test('a chunk before its start fails a POST immediately', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-post-lost',
          port: 3000,
          method: 'POST',
          path: '/api/save',
          headers: {},
          body: '{}',
        ),
      );
      final failing = expectLater(
        future,
        throwsA(isA<TunnelStreamException>()),
      );

      _chunk(t, 'req-post-lost', 1, 'orphan');
      await Future<void>.delayed(Duration.zero);

      await failing;
      expect(_requests(t), hasLength(1));
      expect(_cancelsFor(t, 'req-post-lost'), hasLength(1));

      await session.close();
    });

    test('a frame for an id nobody waits on is answered with one cancel',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      // Touch the service so it subscribes before any frame is emitted.
      session.previewService;

      _chunk(t, 'ghost', 1, 'x');
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'ghost'), hasLength(1));
      _chunk(t, 'ghost', 2, 'x');
      _end(t, 'ghost', 2);
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'ghost'), hasLength(1));

      _start(t, 'ghost-2', data: 'x', last: true);
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'ghost-2'), hasLength(1));
      _start(t, 'ghost-2', data: 'x', last: true);
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'ghost-2'), hasLength(1));

      // The memory is capped, so a burst of distinct ids eventually evicts the
      // oldest and it is cancelled again. One repeat cancel is a no-op at the
      // bridge.
      for (var i = 0; i < 65; i++) {
        _chunk(t, 'burst-$i', 1, 'x');
      }
      await Future<void>.delayed(Duration.zero);
      _chunk(t, 'ghost', 3, 'x');
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'ghost'), hasLength(2));

      await session.close();
    });

    test('cancelling the body subscription cancels the request exactly once',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
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
      _start(t, 'req-cancel', data: 'a');
      final response = await future;
      final sub = response.body.listen((_) {});
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(_cancelsFor(t, 'req-cancel'), hasLength(1));
      _end(t, 'req-cancel', 0);
      await Future<void>.delayed(Duration.zero);
      expect(_cancelsFor(t, 'req-cancel'), hasLength(1));

      await session.close();
    });

    test('a completed body sends no cancel when its subscription ends',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-done-body',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-done-body', data: 'a');
      final response = await future;
      final collected = utf8.decodeStream(response.body);
      _chunk(t, 'req-done-body', 1, 'b');
      _end(t, 'req-done-body', 1);

      expect(await collected, 'ab');
      await Future<void>.delayed(Duration.zero);
      // The entry is removed before the close, so the `onCancel` that follows
      // the delivered done finds nothing to cancel.
      expect(_cancelsFor(t, 'req-done-body'), isEmpty);

      await session.close();
    });

    test('a duplicate start is ignored', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-dup',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-dup', data: 'a');
      final response = await future;
      final collected = utf8.decodeStream(response.body);

      // A replay racing the live run: the body it belongs to is already open.
      _start(t, 'req-dup', data: 'REPLAY');
      _chunk(t, 'req-dup', 1, 'b');
      _end(t, 'req-dup', 1);

      expect(await collected, 'ab');
      expect(_cancelsFor(t, 'req-dup'), isEmpty);

      await session.close();
    });

    test('does not re-send a request whose body is already streaming',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final future = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-streaming',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-streaming', data: 'a');
      final response = await future;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(isA<TunnelStreamException>()),
      );

      // Bytes are already in the browser; nothing can be spliced on.
      t.emitDroppedFrame();
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(_requests(t), hasLength(1));

      await session.close();
      await reading;
    });

    test('re-establishment aborts started bodies and re-sends headless GETs',
        () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = session.previewService;

      final streaming = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-live',
          port: 3000,
          method: 'GET',
          path: '/a.js',
          headers: {},
        ),
      );
      _start(t, 'req-live', data: 'a');
      final response = await streaming;
      final reading = expectLater(
        utf8.decodeStream(response.body),
        throwsA(isA<TunnelStreamException>()),
      );

      final headlessGet = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-headless',
          port: 3000,
          method: 'GET',
          path: '/b.js',
          headers: {},
        ),
      );
      final headlessPost = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-post',
          port: 3000,
          method: 'POST',
          path: '/api',
          headers: {},
          body: '{}',
        ),
      );

      t.setEstablished(false);
      t.setEstablished(true);
      await Future<void>.delayed(Duration.zero);

      await reading;
      expect(_cancelsFor(t, 'req-live'), hasLength(1));
      // Same id: the bridge replays from its outbox or joins the live run.
      expect(
        _requests(t).where((m) => m['requestId'] == 'req-headless'),
        hasLength(2),
      );
      expect(
        _requests(t).where((m) => m['requestId'] == 'req-post'),
        hasLength(1),
      );

      _start(t, 'req-headless', data: 'ok', last: true);
      await headlessGet;
      _start(t, 'req-post', data: 'ok', last: true);
      await headlessPost;

      await session.close();
    });

    test('an inbound tunnel:ws-close carries a forwardable code to the '
        'browser socket', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      addTearDown(() async => session.close());
      final svc = session.previewService;
      final port = await freePort();
      expect(await svc.openTab(port), SelectPortResult.opened);
      addTearDown(() async => svc.closeTab(port));

      final ws = await WebSocket.connect('ws://localhost:$port/_hmr');
      await _waitUntil(
        () => t.sent.any((m) => m['type'] == 'tunnel:ws-open'),
      );
      final tunnelId = t.sent
          .firstWhere((m) => m['type'] == 'tunnel:ws-open')['tunnelId'];

      t.emitJson({
        'type': 'tunnel:ws-close',
        'tunnelId': tunnelId,
        'code': 4001,
        'reason': 'upstream said so',
      }, channel: 'preview');

      await ws.drain<void>().timeout(const Duration(seconds: 2));
      expect(ws.closeCode, 4001);
      expect(ws.closeReason, 'upstream said so');
      // The bridge closed first, so nothing is owed back.
      expect(t.sent.any((m) => m['type'] == 'tunnel:ws-close'), isFalse);
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
      await _waitUntil(
        () => t.sent.any((m) => m['type'] == 'tunnel:ws-open'),
      );
      final tunnelId = t.sent
          .firstWhere((m) => m['type'] == 'tunnel:ws-open')['tunnelId'];

      // The sink throws an ArgumentError for anything outside 1000 and
      // 3000-4999, which would take the transport subscription down with it;
      // the bridge's own too-large code is exactly such a value.
      t.emitJson({
        'type': 'tunnel:ws-close',
        'tunnelId': tunnelId,
        'code': 1009,
        'reason': 'upstream message too large to tunnel',
      }, channel: 'preview');

      await ws.drain<void>().timeout(const Duration(seconds: 2));
      expect(ws.closeCode, isNot(1009));
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
      await _waitUntil(
        () => t.sent.any((m) => m['type'] == 'tunnel:ws-open'),
      );

      ws.add('x' * (1024 * 1024 + 1));
      await ws.drain<void>().timeout(const Duration(seconds: 2));

      expect(t.sent.any((m) => m['type'] == 'tunnel:ws-data'), isFalse);
      await _waitUntil(
        () => t.sent.any((m) => m['type'] == 'tunnel:ws-close'),
      );
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
      await _waitUntil(
        () => t.sent.any((m) => m['type'] == 'tunnel:ws-open'),
      );

      // 400k three-byte characters is 1.2 MB on the wire and 400k UTF-16
      // units: a length-based ceiling would wave it through.
      ws.add('☃' * 400000);
      await ws.drain<void>().timeout(const Duration(seconds: 5));

      expect(t.sent.any((m) => m['type'] == 'tunnel:ws-data'), isFalse);
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

    test('dispose fails pending heads, errors streaming bodies and cancels '
        'each of them', () async {
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
      // Attach the matcher BEFORE disposing so the unawaited error has a
      // listener and doesn't surface as an unhandled async error.
      final headExpectation = expectLater(
        headless,
        throwsA(isA<TimeoutException>()),
      );

      final live = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-live',
          port: 3000,
          method: 'GET',
          path: '/live.js',
          headers: {},
        ),
      );
      _start(t, 'req-live', data: 'a');
      final liveBody = utf8.decodeStream((await live).body);
      final liveExpectation = expectLater(
        liveBody,
        throwsA(isA<TunnelStreamException>()),
      );

      // A body whose subscription never reads: stopping the proxy would never
      // reach its onCancel, so the dispose loop is the only thing that can end
      // it and tell the bridge.
      final stalled = svc.proxyRequest(
        TunnelHttpRequest(
          requestId: 'req-stalled',
          port: 3000,
          method: 'GET',
          path: '/stalled.js',
          headers: {},
        ),
      );
      _start(t, 'req-stalled', data: 'a');
      final stalledBody = (await stalled).body;
      final stalledExpectation = expectLater(
        stalledBody.drain<void>(),
        throwsA(isA<TunnelStreamException>()),
      );

      await session.close();
      await headExpectation;
      await liveExpectation;
      await stalledExpectation;

      expect(_cancelsFor(t, 'req-live'), hasLength(1));
      expect(_cancelsFor(t, 'req-stalled'), hasLength(1));
      expect(_cancelsFor(t, 'req-d'), isEmpty);
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

    void respond(FakeAgentTransport t, String id) =>
        _start(t, id, data: 'ok', last: true);

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
