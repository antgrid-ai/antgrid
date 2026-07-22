import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

void main() {
  group('InboundMessage', () {
    test('holds channel and json', () {
      const m = InboundMessage('control', {'type': 'x'});
      expect(m.channel, 'control');
      expect(m.json['type'], 'x');
    });

    test('supports the preview channel', () {
      const m = InboundMessage('preview', {'method': 'GET'});
      expect(m.channel, 'preview');
      expect(m.json['method'], 'GET');
    });
  });

  group('TransportState', () {
    test('exposes the four lifecycle values', () {
      expect(TransportState.values, hasLength(4));
      expect(
        TransportState.values,
        containsAll(<TransportState>[
          TransportState.connecting,
          TransportState.connected,
          TransportState.disconnected,
          TransportState.error,
        ]),
      );
    });
  });
}
