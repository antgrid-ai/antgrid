// Fast (no-socket) coverage for the v3 `hello`/`welcome`/`error` wire contract
// on RelayService. Uses `debugHandleFrame` (the test-only seam documented on
// RelayService) to drive the message-handling state machine directly, mirroring
// the existing relay_pair_timeout_test.dart style. Live-socket reconnect/skew
// behavior (which needs a real WS round trip) lives in
// relay_service_reconnect_test.dart.
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  group('HelloMessage.toJson', () {
    test('carries every required v3 wire field', () {
      final hello = HelloMessage(
        deviceType: 'app',
        deviceId: 'phone-1',
        name: 'Test Phone',
        publicKey: 'pub==',
        epoch: 42,
        licenseToken: 'tok',
        ts: '2026-01-01T00:00:00.000Z',
        nonce: 'nonce==',
        sig: 'sig==',
      ).toJson();

      expect(hello['type'], 'hello');
      expect(hello['protocolVersion'], 3);
      for (final key in [
        'deviceType',
        'deviceId',
        'name',
        'publicKey',
        'epoch',
        'licenseToken',
        'ts',
        'nonce',
        'sig',
      ]) {
        expect(hello.containsKey(key), isTrue, reason: 'missing $key');
        expect(hello[key], isNotNull);
      }
    });
  });

  group('RelayService — malformed / rejected frames', () {
    late RelayService relay;
    setUp(() => relay = RelayService(crypto: CryptoService()));

    test('an error frame missing the required `retryable` field is dropped '
        '(ErrorMessage.fromJson returns null — the error contract is law)', () {
      final before = relay.currentState;
      relay.debugHandleFrame(
        jsonEncode({
          'type': 'error',
          'code': 'PROTOCOL_VIOLATION',
          'message': 'First frame must be a valid v3 hello',
          // no `retryable` — malformed per the v3 contract.
        }),
      );
      // Silently ignored: state is untouched, no errorStream emission.
      expect(relay.currentState.connectionState, before.connectionState);
      expect(relay.currentState.errorCode, isNull);
    });

    test('an error frame missing `code`/`message` is dropped', () {
      relay.debugHandleFrame(jsonEncode({'type': 'error', 'retryable': true}));
      expect(relay.currentState.errorCode, isNull);
    });

    test('a welcome frame missing `epoch` is dropped (WelcomeMessage.fromJson '
        'requires it)', () {
      relay.debugHandleFrame(
        jsonEncode({
          'type': 'welcome',
          'deviceId': 'phone-1',
          'serverTime': '2026-01-01T00:00:00.000Z',
          // no `epoch`
        }),
      );
      expect(
        relay.currentState.connectionState,
        isNot(RelayConnectionState.authenticated),
      );
    });

    test('non-JSON text is ignored without throwing', () {
      expect(() => relay.debugHandleFrame('not json'), returnsNormally);
      expect(
        relay.currentState.connectionState,
        RelayConnectionState.disconnected,
      );
    });
  });

  group('RelayService — welcome → authenticated', () {
    test('a valid welcome transitions to authenticated and resets backoff '
        'markers (errorCode clears via copyWith not preserving it)', () {
      final relay = RelayService(crypto: CryptoService());
      relay.debugHandleFrame(
        jsonEncode({
          'type': 'error',
          'code': 'AGENT_OFFLINE',
          'message': 'not yet',
          'retryable': true,
        }),
      );
      expect(relay.currentState.errorCode, 'AGENT_OFFLINE');

      relay.debugHandleFrame(
        jsonEncode({
          'type': 'welcome',
          'deviceId': 'phone-1',
          'epoch': 7,
          'serverTime': DateTime.now().toUtc().toIso8601String(),
        }),
      );

      expect(
        relay.currentState.connectionState,
        RelayConnectionState.authenticated,
      );
      expect(relay.currentState.errorCode, isNull);
    });
  });
}
