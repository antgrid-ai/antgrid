import 'dart:convert';

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

    test('parses stream-opened and stream-closed', () {
      final opened =
          parseRelayMessage({'type': 'stream-opened', 'streamId': 's1'});
      expect(opened, isA<StreamOpenedMessage>());
      expect((opened as StreamOpenedMessage).streamId, 's1');

      final closed =
          parseRelayMessage({'type': 'stream-closed', 'streamId': 's1'});
      expect(closed, isA<StreamClosedMessage>());
      expect((closed as StreamClosedMessage).streamId, 's1');
    });

    test('parses grant-revoked with reason', () {
      final msg = parseRelayMessage({
        'type': 'grant-revoked',
        'peerDeviceId': 'phone-1',
        'reason': 'PEER_REPLACED',
      });
      expect(msg, isA<GrantRevokedMessage>());
      final g = msg as GrantRevokedMessage;
      expect(g.peerDeviceId, 'phone-1');
      expect(g.reason, 'PEER_REPLACED');
    });

    test('parses error with retryable/ref/serverTime', () {
      final msg = parseRelayMessage({
        'type': 'error',
        'code': 'PEER_OFFLINE',
        'message': 'peer not connected',
        'retryable': true,
        'ref': 's1',
        'serverTime': '2026-07-16T00:00:00.000Z',
      });
      expect(msg, isA<ErrorMessage>());
      final e = msg as ErrorMessage;
      expect(e.code, 'PEER_OFFLINE');
      expect(e.retryable, isTrue);
      expect(e.ref, 's1');
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

    test('error omits optional ref/serverTime when absent', () {
      final msg = parseRelayMessage({
        'type': 'error',
        'code': 'SUPERSEDED',
        'message': 'newer connection won',
        'retryable': false,
      }) as ErrorMessage;
      expect(msg.retryable, isFalse);
      expect(msg.ref, isNull);
      expect(msg.serverTime, isNull);
    });

    test('parses pair-approval with pairId', () {
      final raw = jsonDecode('''
        {"type":"pair-approval","pairId":"pid","phonePubkey":"pk","phoneDeviceId":"d1","nonce":"n","expiresAt":"2026-04-29T10:00:00.000Z","signature":"sig"}
      ''') as Map<String, dynamic>;
      final m = parseRelayMessage(raw);
      expect(m, isA<PairApprovalMessage>());
      final approval = m as PairApprovalMessage;
      expect(approval.pairId, 'pid');
      expect(approval.phonePubkey, 'pk');
      expect(approval.phoneDeviceId, 'd1');
      expect(approval.nonce, 'n');
      expect(approval.signature, 'sig');
      expect(approval.expiresAt.toUtc().toIso8601String(),
          '2026-04-29T10:00:00.000Z');
    });

    test('pair-approval without pairId returns null', () {
      final raw = jsonDecode('''
        {"type":"pair-approval","phonePubkey":"pk","phoneDeviceId":"d1","nonce":"n","expiresAt":"2026-04-29T10:00:00.000Z","signature":"sig"}
      ''') as Map<String, dynamic>;
      expect(parseRelayMessage(raw), isNull);
    });

    test('parses pair-rejected with pairId and reason', () {
      final raw = jsonDecode('''
        {"type":"pair-rejected","pairId":"pid","phonePubkey":"pk","reason":"UNKNOWN_PHONE"}
      ''') as Map<String, dynamic>;
      final m = parseRelayMessage(raw);
      expect(m, isA<PairRejectedMessage>());
      final rejected = m as PairRejectedMessage;
      expect(rejected.pairId, 'pid');
      expect(rejected.phonePubkey, 'pk');
      expect(rejected.reason, 'UNKNOWN_PHONE');
    });

    test('pair-rejected without pairId returns null', () {
      expect(
        parseRelayMessage(
            {'type': 'pair-rejected', 'phonePubkey': 'pk', 'reason': 'X'}),
        isNull,
      );
    });

    test('parses pair-connected, peer-online, peer-offline', () {
      expect(
        parseRelayMessage({
          'type': 'pair-connected',
          'peerId': 'a',
          'peerName': 'n',
          'peerType': 'agent',
        }),
        isA<PairConnectedMessage>(),
      );
      expect(parseRelayMessage({'type': 'peer-online', 'peerId': 'a'}),
          isA<PeerOnlineMessage>());
      expect(parseRelayMessage({'type': 'peer-offline', 'peerId': 'a'}),
          isA<PeerOfflineMessage>());
    });

    test('removed v2 types no longer dispatch', () {
      for (final t in ['challenge', 'authenticated', 'pair-disconnected']) {
        expect(parseRelayMessage({'type': t}), isNull,
            reason: '$t should not resolve in v3');
      }
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

    test('StreamOpen/StreamClose toJson', () {
      expect(const StreamOpenMessage(streamId: 's1').toJson(),
          {'type': 'stream-open', 'streamId': 's1'});
      expect(const StreamCloseMessage(streamId: 's1').toJson(),
          {'type': 'stream-close', 'streamId': 's1'});
    });

    test('GrantRevokeMessage.toJson', () {
      expect(const GrantRevokeMessage(peerDeviceId: 'phone-1').toJson(),
          {'type': 'grant-revoke', 'peerDeviceId': 'phone-1'});
    });

    test('PairRequestMessage.toJson includes deadline and omits pairId', () {
      final m = PairRequestMessage(
        agentDeviceId: 'a1',
        phonePubkey: 'pk',
        phoneDeviceId: 'p1',
        nonce: 'n',
        requestedAt: '2030-01-01T00:00:00.000Z',
        deadline: 1893456000000,
        phoneSignature: 'sig',
        pairCode: 'pc',
        label: 'iPhone',
      );
      expect(m.toJson(), {
        'type': 'pair-request',
        'agentDeviceId': 'a1',
        'phonePubkey': 'pk',
        'phoneDeviceId': 'p1',
        'nonce': 'n',
        'requestedAt': '2030-01-01T00:00:00.000Z',
        'deadline': 1893456000000,
        'phoneSignature': 'sig',
        'pairCode': 'pc',
        'label': 'iPhone',
      });
      expect(m.toJson().containsKey('pairId'), isFalse);
    });

    test('PairRequestMessage.toJson omits null pairCode/label/account fields',
        () {
      final m = PairRequestMessage(
        agentDeviceId: 'a1',
        phonePubkey: 'pk',
        phoneDeviceId: 'p1',
        nonce: 'n',
        requestedAt: '2030-01-01T00:00:00.000Z',
        deadline: 1,
        phoneSignature: 'sig',
      );
      final j = m.toJson();
      expect(j.containsKey('pairCode'), isFalse);
      expect(j.containsKey('label'), isFalse);
      expect(j.containsKey('accountDevicePubkey'), isFalse);
      expect(j.containsKey('accountMembershipSig'), isFalse);
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

  group('RelayErrorCode', () {
    test('round-trips all v3 wire codes', () {
      const wires = [
        'AGENT_OFFLINE',
        'PAIR_REJECTED',
        'UNKNOWN_PHONE',
        'PAIRING_WINDOW_CLOSED',
        'NONCE_MISMATCH',
        'APPROVAL_EXPIRED',
        'SUPERSEDED',
        'PEER_OFFLINE',
        'PROTOCOL_VIOLATION',
        'EXPIRED',
        'NOT_AUTHORIZED',
        'PEER_REPLACED',
        'SESSION_LIMIT_EXCEEDED',
      ];
      for (final w in wires) {
        final code = RelayErrorCode.fromWire(w);
        expect(code, isNotNull, reason: 'fromWire($w) should resolve');
        expect(code!.wireValue, w);
      }
    });

    test('removed PARENT_AGENT_DISCONNECTED no longer resolves', () {
      expect(RelayErrorCode.fromWire('PARENT_AGENT_DISCONNECTED'), isNull);
    });

    test('returns null for unknown code', () {
      expect(RelayErrorCode.fromWire('SOMETHING_ELSE'), isNull);
      expect(RelayErrorCode.fromWire(null), isNull);
    });
  });
}
