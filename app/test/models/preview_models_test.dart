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
    });

    test('fromJson returns null for missing port', () {
      final info = PortInfo.fromJson({'pid': 1234});
      expect(info, isNull);
    });
  });

  group('PreviewState', () {
    test('default constructor has correct defaults', () {
      const state = PreviewState();
      expect(state.ports, isEmpty);
      expect(state.selectedPort, isNull);
      expect(state.localProxyPort, isNull);
      expect(state.currentUrl, isNull);
      expect(state.isLoading, false);
      expect(state.error, isNull);
    });

    test('copyWith creates new instance with updated fields', () {
      const state = PreviewState();
      final updated = state.copyWith(
        ports: [PortInfo(port: 3000)],
        selectedPort: 3000,
        isLoading: true,
      );
      expect(updated.ports.length, 1);
      expect(updated.selectedPort, 3000);
      expect(updated.isLoading, true);
    });

    test('copyWith with clearSelectedPort resets nullable field', () {
      final state = const PreviewState().copyWith(selectedPort: 3000);
      final cleared = state.copyWith(clearSelectedPort: true);
      expect(cleared.selectedPort, isNull);
    });

    test('copyWith with clearError resets error', () {
      final state = const PreviewState().copyWith(error: 'test error');
      final cleared = state.copyWith(clearError: true);
      expect(cleared.error, isNull);
    });

    test('copyWith with clearLocalProxyPort resets localProxyPort', () {
      final state = const PreviewState().copyWith(localProxyPort: 8080);
      final cleared = state.copyWith(clearLocalProxyPort: true);
      expect(cleared.localProxyPort, isNull);
    });

    test('copyWith with clearCurrentUrl resets currentUrl', () {
      final state = const PreviewState().copyWith(
        currentUrl: 'http://localhost:3000',
      );
      final cleared = state.copyWith(clearCurrentUrl: true);
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
  });

  group('TunnelHttpResponse', () {
    test('fromJson parses all fields', () {
      final response = TunnelHttpResponse.fromJson({
        'requestId': 'req-1',
        'status': 200,
        'headers': {'content-type': 'text/html'},
        'body': '<html></html>',
        'bodyEncoding': 'utf8',
      });
      expect(response, isNotNull);
      expect(response!.requestId, 'req-1');
      expect(response.status, 200);
      expect(response.headers['content-type'], 'text/html');
      expect(response.body, '<html></html>');
      expect(response.bodyEncoding, 'utf8');
    });

    test('fromJson returns null for missing required fields', () {
      final response = TunnelHttpResponse.fromJson({
        'requestId': 'req-1',
        // missing status
        'headers': {},
        'body': '',
        'bodyEncoding': 'utf8',
      });
      expect(response, isNull);
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

    test('tunnel:http-response returns TunnelHttpResponse', () {
      final msg = parseAbMessage({
        'type': 'tunnel:http-response',
        'requestId': 'req-1',
        'status': 200,
        'headers': {'content-type': 'text/html'},
        'body': '<html></html>',
        'bodyEncoding': 'utf8',
      });
      expect(msg, isA<TunnelHttpResponse>());
      final resp = msg as TunnelHttpResponse;
      expect(resp.requestId, 'req-1');
      expect(resp.status, 200);
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
  });
}
