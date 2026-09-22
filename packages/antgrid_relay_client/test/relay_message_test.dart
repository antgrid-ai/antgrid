import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

void main() {
  group('parseRelayMessage — relay → client', () {
    test('parses welcome message', () {
      final msg = parseRelayMessage({
        'type': 'welcome',
        'deviceId': 'd1',
        'epoch': 7,
        'serverTime': '2026-07-16T00:00:00.000Z',
      });
      expect(msg, isA<WelcomeMessage>());
      final w = msg as WelcomeMessage;
      expect(w.deviceId, 'd1');
      expect(w.epoch, 7);
      expect(w.serverTime, '2026-07-16T00:00:00.000Z');
    });

    test('parses pong message', () {
      expect(parseRelayMessage({'type': 'pong'}), isA<PongMessage>());
      expect(
        parseRelayMessage({'type': 'pong', 'extra': true}),
        isA<PongMessage>(),
      );
    });

    test('welcome with non-int epoch returns null', () {
      expect(
        parseRelayMessage({
          'type': 'welcome',
          'deviceId': 'd1',
          'epoch': 'nope',
          'serverTime': '2026-07-16T00:00:00.000Z',
        }),
        isNull,
      );
    });

    test('parses error with retryable/serverTime', () {
      final msg = parseRelayMessage({
        'type': 'error',
        'code': 'PEER_OFFLINE',
        'message': 'peer not connected',
        'retryable': true,
        'serverTime': '2026-07-16T00:00:00.000Z',
      });
      expect(msg, isA<ErrorMessage>());
      final e = msg as ErrorMessage;
      expect(e.code, 'PEER_OFFLINE');
      expect(e.retryable, isTrue);
      expect(e.serverTime, '2026-07-16T00:00:00.000Z');
    });

    test('error without retryable returns null', () {
      expect(
        parseRelayMessage({
          'type': 'error',
          'code': 'PROTOCOL_VIOLATION',
          'message': 'bad frame',
        }),
        isNull,
      );
    });

    test('error with non-bool retryable returns null', () {
      expect(
        parseRelayMessage({
          'type': 'error',
          'code': 'PROTOCOL_VIOLATION',
          'message': 'bad frame',
          'retryable': 'false',
        }),
        isNull,
      );
    });

    test('error omits optional serverTime when absent', () {
      final msg =
          parseRelayMessage({
                'type': 'error',
                'code': 'SUPERSEDED',
                'message': 'newer connection won',
                'retryable': false,
              })
              as ErrorMessage;
      expect(msg.retryable, isFalse);
      expect(msg.serverTime, isNull);
    });

    test('parses peer-online, peer-offline', () {
      expect(
        parseRelayMessage({'type': 'peer-online', 'peerId': 'a'}),
        isA<PeerOnlineMessage>(),
      );
      expect(
        parseRelayMessage({'type': 'peer-offline', 'peerId': 'a'}),
        isA<PeerOfflineMessage>(),
      );
    });

    test('returns null for unknown type', () {
      expect(parseRelayMessage({'type': 'unknown'}), isNull);
    });
  });

  group('outgoing message serialization — client → relay', () {
    test('HelloMessage.toJson emits the v3 wire shape', () {
      final json = HelloMessage(
        deviceType: 'agent',
        deviceId: 'd1',
        name: 'test',
        publicKey: 'pk',
        epoch: 42,
        licenseToken: 'jwt.fixture.token',
        ts: '2026-07-16T00:00:00.000Z',
        nonce: 'BwcHBwcHBwcHBwcHBwcHBw==',
        sig: 'sig',
      ).toJson();
      expect(json, {
        'type': 'hello',
        'protocolVersion': 3,
        'deviceType': 'agent',
        'deviceId': 'd1',
        'name': 'test',
        'publicKey': 'pk',
        'epoch': 42,
        'licenseToken': 'jwt.fixture.token',
        'ts': '2026-07-16T00:00:00.000Z',
        'nonce': 'BwcHBwcHBwcHBwcHBwcHBw==',
        'sig': 'sig',
      });
    });

    test('PingMessage.toJson', () {
      expect(const PingMessage().toJson(), {'type': 'ping'});
    });
  });

  group('StreamEnvelope', () {
    test('kControlStreamId is "0"', () {
      expect(kControlStreamId, '0');
    });

    test('toJson omits absent stream id', () {
      expect(const StreamEnvelope(m: {'type': 'x'}).toJson(), {
        'm': {'type': 'x'},
      });
      expect(const StreamEnvelope(s: '3', m: {'type': 'x'}).toJson(), {
        's': '3',
        'm': {'type': 'x'},
      });
    });

    test('fromJson requires m and rejects non-string s', () {
      expect(StreamEnvelope.fromJson({'s': '3', 'm': 1})?.s, '3');
      expect(StreamEnvelope.fromJson({'m': 1})?.s, isNull);
      expect(StreamEnvelope.fromJson({'s': 3, 'm': 1}), isNull);
      expect(StreamEnvelope.fromJson({'s': '3'}), isNull);
    });
  });

}
