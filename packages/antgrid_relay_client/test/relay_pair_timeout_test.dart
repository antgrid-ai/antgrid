import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

/// Regression guard for the PAIR_TIMEOUT reachability bug.
///
/// An `error` frame used to set only `AppState.error` (the human "code:
/// message" string) and not `errorCode`. Because `AppState.copyWith` does NOT
/// preserve `errorCode`, the field stayed null — yet the app's
/// `agentReachabilityProvider` gates "agent offline" on
/// `state.errorCode == 'PAIR_TIMEOUT'`. The check could never fire, so a
/// timed-out pairing showed a perpetual "connecting" spinner instead of
/// "offline".
void main() {
  group('RelayService error-frame handling', () {
    late RelayService relay;

    setUp(() => relay = RelayService(crypto: CryptoService()));

    // v3-phase-A: v3 `error` frames carry a required `retryable` bool
    // (ErrorMessage.fromJson returns null without it), so the frame must now
    // include it. The regression this test guards — AppState.copyWith not
    // preserving `errorCode` — is unchanged; the specific PAIR_TIMEOUT code is
    // just an opaque token here. Phase A should re-express it against a live v3
    // code (e.g. EXPIRED / PEER_OFFLINE) once the service consumes them.
    String errorFrame(String code) => jsonEncode(
        {'type': 'error', 'code': code, 'message': '$code happened', 'retryable': false});

    test('PAIR_TIMEOUT populates errorCode (not just error)', () {
      relay.debugHandleFrame(errorFrame('PAIR_TIMEOUT'));

      expect(relay.currentState.errorCode, 'PAIR_TIMEOUT',
          reason: 'consumers gate reachability on errorCode, not error');
      expect(relay.currentState.error, contains('PAIR_TIMEOUT'));
    });

    test('LICENSE_UNAVAILABLE is not treated as a license-fatal error', () async {
      // The fatal branch emits on licenseErrorStream and suppresses reconnect.
      // LICENSE_UNAVAILABLE must fall through to the generic path instead —
      // the relay couldn't reach web to check, so retrying is the right move.
      final fatal = <RelayLicenseErrorCode>[];
      relay.licenseErrorStream.listen(fatal.add);

      relay.debugHandleFrame(errorFrame('LICENSE_UNAVAILABLE'));
      await Future<void>.delayed(Duration.zero);

      expect(fatal, isEmpty);
      expect(relay.currentState.errorCode, 'LICENSE_UNAVAILABLE');
    });

    test('a subsequent transition clears the stale errorCode', () {
      relay.debugHandleFrame(errorFrame('PAIR_TIMEOUT'));
      expect(relay.currentState.errorCode, 'PAIR_TIMEOUT');

      // pair-connected is the success path; copyWith's non-preserving errorCode
      // means it resets to null, so the offline marker can't linger past a
      // successful pair.
      relay.debugHandleFrame(jsonEncode({
        'type': 'pair-connected',
        'peerId': 'agent-1',
        'peerName': 'agent',
        'peerType': 'agent',
      }));

      expect(relay.currentState.errorCode, isNull);
      expect(relay.currentState.connectionState, RelayConnectionState.paired);
    });
  });
}
