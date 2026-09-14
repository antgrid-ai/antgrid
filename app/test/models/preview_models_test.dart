import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  group('PortInfo', () {
    test('fromJson parses all fields correctly', () {
      final info = PortInfo.fromJson({
        'port': 3000,
        'pid': 1234,
        'processName': 'node',
        'label': 'Frontend',
      });
      expect(info, isNotNull);
      expect(info!.port, 3000);
      expect(info.pid, 1234);
      expect(info.processName, 'node');
      expect(info.label, 'Frontend');
    });

    test('fromJson handles missing optional fields', () {
      final info = PortInfo.fromJson({'port': 8080});
      expect(info, isNotNull);
      expect(info!.port, 8080);
      expect(info.pid, isNull);
      expect(info.processName, isNull);
      expect(info.label, isNull);
      expect(info.scheme, isNull);
    });

    test('fromJson parses detected scheme', () {
      final info = PortInfo.fromJson({'port': 8443, 'scheme': 'https'});
      expect(info, isNotNull);
      expect(info!.scheme, 'https');
    });

    test('fromJson returns null for missing port', () {
      final info = PortInfo.fromJson({'pid': 1234});
      expect(info, isNull);
    });

    test('fromJson parses declared onDetect', () {
      final info = PortInfo.fromJson({'port': 3000, 'onDetect': 'silent'});
      expect(info, isNotNull);
      expect(info!.onDetect, 'silent');
    });

    test('fromJson leaves onDetect null for an undeclared port', () {
      final info = PortInfo.fromJson({'port': 3000});
      expect(info, isNotNull);
      expect(info!.onDetect, isNull);
    });
  });

  group('PreviewState', () {
    test('default constructor has correct defaults', () {
      const state = PreviewState();
      expect(state.ports, isEmpty);
      expect(state.tabs, isEmpty);
      expect(state.activeTabId, isNull);
      expect(state.activeTab, isNull);
      expect(state.isLoading, false);
      expect(state.error, isNull);
    });

    test('copyWith creates new instance with updated fields', () {
      const state = PreviewState();
      const tab = PreviewTab(
        port: 3000,
        scheme: 'http',
        localProxyPort: 3000,
        currentUrl: 'http://localhost:3000',
      );
      final updated = state.copyWith(
        ports: [PortInfo(port: 3000)],
        tabs: [tab],
        activeTabId: 3000,
        isLoading: true,
      );
      expect(updated.ports.length, 1);
      expect(updated.tabs, [tab]);
      expect(updated.activeTabId, 3000);
      expect(updated.activeTab, tab);
      expect(updated.isLoading, true);
    });

    test('copyWith with clearActiveTabId resets nullable field', () {
      final state = const PreviewState().copyWith(activeTabId: 3000);
      final cleared = state.copyWith(clearActiveTabId: true);
      expect(cleared.activeTabId, isNull);
    });

    test('copyWith with clearError resets error', () {
      final state = const PreviewState().copyWith(error: 'test error');
      final cleared = state.copyWith(clearError: true);
      expect(cleared.error, isNull);
    });

    test('activeTab returns null when activeTabId names no open tab', () {
      const state = PreviewState(
        tabs: [PreviewTab(port: 3000, scheme: 'http')],
        activeTabId: 4000,
      );
      expect(state.activeTab, isNull);
    });
  });

  group('PreviewTab', () {
    test('copyWith with clearLocalProxyPort resets localProxyPort', () {
      const tab = PreviewTab(
        port: 3000,
        scheme: 'http',
        localProxyPort: 8080,
      );
      final cleared = tab.copyWith(clearLocalProxyPort: true);
      expect(cleared.localProxyPort, isNull);
      expect(cleared.port, 3000);
    });

    test('copyWith with clearCurrentUrl resets currentUrl', () {
      const tab = PreviewTab(
        port: 3000,
        scheme: 'http',
        currentUrl: 'http://localhost:3000',
      );
      final cleared = tab.copyWith(clearCurrentUrl: true);
      expect(cleared.currentUrl, isNull);
    });
  });

  group('TunnelHttpRequest', () {
    test('holds all fields and toJson works', () {
      final request = TunnelHttpRequest(
        requestId: 'req-1',
        port: 3000,
        method: 'GET',
        path: '/index.html',
        headers: {'accept': 'text/html'},
      );
      expect(request.requestId, 'req-1');
      expect(request.body, isNull);
      final json = request.toJson();
      expect(json['type'], 'tunnel:http-request');
      expect(json['requestId'], 'req-1');
      expect(json['port'], 3000);
      expect(json['method'], 'GET');
      expect(json['path'], '/index.html');
      expect(json['headers'], {'accept': 'text/html'});
      expect(json.containsKey('body'), false);
    });

    test('toJson includes body when present', () {
      final request = TunnelHttpRequest(
        requestId: 'req-2',
        port: 3000,
        method: 'POST',
        path: '/api/data',
        headers: {'content-type': 'application/json'},
        body: '{"key":"value"}',
      );
      final json = request.toJson();
      expect(json['body'], '{"key":"value"}');
    });

    // The bridge matches this string literally (TUNNEL_GZIP_ENCODING in
    // tunnel-protocol.ts) and answers uncompressed when it doesn't recognise
    // what we advertised, so a rename on either side degrades silently.
    test('the advertised gzip encoding is the name the bridge matches', () {
      expect(kTunnelGzipEncoding, 'gzip-base64');
    });

    test('an explicitly empty acceptEncodings omits the key', () {
      final json = TunnelHttpRequest(
        requestId: 'req-3',
        port: 3000,
        method: 'GET',
        path: '/',
        headers: const {},
        acceptEncodings: const [],
      ).toJson();
      expect(json.containsKey('acceptEncodings'), false);
    });

    // A lost-head recovery re-sends under a fresh id; anything else changing
    // would ask the dev server a different question than the browser asked.
    test('copyWith(requestId:) changes only the id', () {
      final source = TunnelHttpRequest(
        requestId: 'req-old',
        port: 3000,
        scheme: 'https',
        method: 'GET',
        path: '/app.js',
        headers: const {'accept': '*/*'},
        body: null,
        acceptEncodings: const [kTunnelGzipEncoding],
      );
      final copy = source.copyWith(requestId: 'req-new');

      expect(copy.requestId, 'req-new');
      expect(copy.port, source.port);
      expect(copy.scheme, source.scheme);
      expect(copy.method, source.method);
      expect(copy.path, source.path);
      expect(copy.headers, source.headers);
      expect(copy.body, source.body);
      expect(copy.acceptEncodings, source.acceptEncodings);
    });
  });

  group('tunnel response frames', () {
    test('start parses head, slice 0 and last', () {
      final msg = TunnelHttpStartMessage.fromJson({
        'requestId': 'req-1',
        'status': 200,
        'headers': {'content-type': 'text/html'},
        'setCookies': ['a=1', 'b=2'],
        'data': 'aGk=',
        'bodyEncoding': 'base64',
        'last': true,
      });
      expect(msg, isNotNull);
      expect(msg!.requestId, 'req-1');
      expect(msg.status, 200);
      expect(msg.headers['content-type'], 'text/html');
      expect(msg.setCookies, ['a=1', 'b=2']);
      expect(msg.data, 'aGk=');
      expect(msg.bodyEncoding, 'base64');
      expect(msg.last, isTrue);
    });

    test('start without last defaults it false and tolerates no cookies', () {
      final msg = TunnelHttpStartMessage.fromJson({
        'requestId': 'req-1',
        'status': 204,
        'headers': <String, dynamic>{},
        'data': '',
        'bodyEncoding': 'base64',
      });
      expect(msg!.last, isFalse);
      expect(msg.setCookies, isEmpty);
    });

    test('start without status returns null', () {
      expect(
        TunnelHttpStartMessage.fromJson({
          'requestId': 'req-1',
          'headers': <String, dynamic>{},
          'data': '',
          'bodyEncoding': 'base64',
        }),
        isNull,
      );
    });

    test('chunk parses seq, data and per-slice encoding', () {
      final msg = TunnelHttpChunkMessage.fromJson({
        'requestId': 'req-1',
        'seq': 3,
        'data': 'aGk=',
        'bodyEncoding': kTunnelGzipEncoding,
      });
      expect(msg!.seq, 3);
      expect(msg.bodyEncoding, kTunnelGzipEncoding);
    });

    // An unknown encoding must PARSE: rejected here it is indistinguishable
    // from a lost frame, where the handler fails the body naming the value.
    test('chunk with an unknown bodyEncoding still parses', () {
      final msg = TunnelHttpChunkMessage.fromJson({
        'requestId': 'req-1',
        'seq': 1,
        'data': 'aGk=',
        'bodyEncoding': 'utf8',
      });
      expect(msg, isNotNull);
      expect(msg!.bodyEncoding, 'utf8');
    });

    test('chunk with a non-int seq returns null', () {
      expect(
        TunnelHttpChunkMessage.fromJson({
          'requestId': 'req-1',
          'seq': '1',
          'data': 'aGk=',
          'bodyEncoding': 'base64',
        }),
        isNull,
      );
    });

    test('end parses the chunk count and an optional error', () {
      final clean = TunnelHttpEndMessage.fromJson({
        'requestId': 'req-1',
        'chunks': 4,
      });
      expect(clean!.chunks, 4);
      expect(clean.error, isNull);

      final failed = TunnelHttpEndMessage.fromJson({
        'requestId': 'req-1',
        'chunks': 2,
        'error': 'upstream body stalled',
      });
      expect(failed!.error, 'upstream body stalled');
    });

    test('end without chunks returns null', () {
      expect(
        TunnelHttpEndMessage.fromJson({'requestId': 'req-1'}),
        isNull,
      );
    });

    test('ws-close carries a code and reason, and tolerates neither', () {
      final withCode = TunnelWsCloseMessage.fromJson({
        'tunnelId': 't-1',
        'code': 1009,
        'reason': 'too big',
      });
      expect(withCode!.code, 1009);
      expect(withCode.reason, 'too big');

      final bare = TunnelWsCloseMessage.fromJson({'tunnelId': 't-1'});
      expect(bare!.code, isNull);
      expect(bare.reason, isNull);
    });
  });

  group('parseAbMessage - preview types', () {
    test('ports:update returns PortsUpdateMessage', () {
      final msg = parseAbMessage({
        'type': 'ports:update',
        'id': 'msg-1',
        'timestamp': 1234567890,
        'projectId': 'proj-1',
        'ports': [
          {
            'port': 3000,
            'pid': 1234,
            'processName': 'node',
            'label': 'Frontend',
          },
          {'port': 8080},
        ],
      });
      expect(msg, isA<PortsUpdateMessage>());
      final portsMsg = msg as PortsUpdateMessage;
      expect(portsMsg.id, 'msg-1');
      expect(portsMsg.timestamp, 1234567890);
      expect(portsMsg.projectId, 'proj-1');
      expect(portsMsg.ports.length, 2);
      expect(portsMsg.ports[0].port, 3000);
      expect(portsMsg.ports[1].port, 8080);
    });

    test('the three streamed tunnel frames parse to their own types', () {
      final start = parseAbMessage({
        'type': 'tunnel:http-start',
        'requestId': 'req-1',
        'status': 200,
        'headers': {'content-type': 'text/html'},
        'data': '',
        'bodyEncoding': 'base64',
      });
      expect(start, isA<TunnelHttpStartMessage>());
      expect((start as TunnelHttpStartMessage).status, 200);

      final chunk = parseAbMessage({
        'type': 'tunnel:http-chunk',
        'requestId': 'req-1',
        'seq': 1,
        'data': 'aGk=',
        'bodyEncoding': 'base64',
      });
      expect(chunk, isA<TunnelHttpChunkMessage>());

      final end = parseAbMessage({
        'type': 'tunnel:http-end',
        'requestId': 'req-1',
        'chunks': 1,
      });
      expect(end, isA<TunnelHttpEndMessage>());
    });

    // The retired whole-body type must not resolve to anything: a stale bridge
    // speaking it should surface as a dropped frame, not a half-decoded one.
    test('tunnel:http-response no longer parses', () {
      expect(
        parseAbMessage({
          'type': 'tunnel:http-response',
          'requestId': 'req-1',
          'status': 200,
          'headers': <String, dynamic>{},
          'body': '',
          'bodyEncoding': 'utf8',
        }),
        isNull,
      );
    });

    test('malformed ports:update returns null', () {
      final msg = parseAbMessage({
        'type': 'ports:update',
        'id': 'msg-1',
        'timestamp': 1234567890,
        // missing projectId
        'ports': 'not a list',
      });
      expect(msg, isNull);
    });

    test('port:detected returns PortDetectedMessage', () {
      final msg = parseAbMessage({
        'type': 'port:detected',
        'id': 'msg-2',
        'timestamp': 1234567890,
        'projectId': 'proj-1',
        'port': 3000,
        'url': 'http://localhost:3000',
        'scheme': 'http',
        'source': 'output',
        'sourceSessionId': 'sess-1',
        'attributes': {'name': 'web', 'onDetect': 'openPreview'},
      });
      expect(msg, isA<PortDetectedMessage>());
      final detected = msg as PortDetectedMessage;
      expect(detected.id, 'msg-2');
      expect(detected.port, 3000);
      expect(detected.url, 'http://localhost:3000');
      expect(detected.scheme, 'http');
      expect(detected.source, 'output');
      expect(detected.sourceSessionId, 'sess-1');
      expect(detected.attributes.name, 'web');
      expect(detected.attributes.onDetect, 'openPreview');
    });

    test('port:detected defaults onDetect to notify when attributes '
        'omits it', () {
      final msg = parseAbMessage({
        'type': 'port:detected',
        'id': 'msg-3',
        'timestamp': 1234567890,
        'projectId': 'proj-1',
        'port': 3000,
        'url': 'http://localhost:3000',
        'scheme': 'http',
        'source': 'process',
        'attributes': <String, dynamic>{},
      });
      expect(msg, isA<PortDetectedMessage>());
      expect((msg as PortDetectedMessage).attributes.onDetect, 'notify');
    });

    test('malformed port:detected returns null', () {
      final msg = parseAbMessage({
        'type': 'port:detected',
        'id': 'msg-4',
        'timestamp': 1234567890,
        'projectId': 'proj-1',
        // missing port
        'url': 'http://localhost:3000',
        'scheme': 'http',
        'source': 'output',
        'attributes': {'onDetect': 'notify'},
      });
      expect(msg, isNull);
    });
  });
}
