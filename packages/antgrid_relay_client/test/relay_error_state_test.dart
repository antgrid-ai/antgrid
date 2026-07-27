import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

/// Regression guard for the "error frame lost its code" bug.
///
/// An `error` frame used to set only `AppState.error` (the human "code:
/// message" string) and not `errorCode`. Because `AppState.copyWith` does NOT
/// preserve `errorCode`, the field stayed null — yet consumers (the connection
/// supervisor, the error banner) classify on `errorCode`, never by parsing
/// `error`. The check could never fire, so a terminal verdict read as an
/// ordinary retryable drop.
void main() {
  group('RelayService error-frame handling', () {
    late RelayService relay;

    setUp(() => relay = RelayService(crypto: CryptoService()));

    // v3 `error` frames carry a required `retryable` bool
    // (ErrorMessage.fromJson returns null without it), so the frame must
    // include it. The regression guarded here — AppState.copyWith not
    // preserving `errorCode` — is independent of the code itself.
    String errorFrame(String code) => jsonEncode({
      'type': 'error',
      'code': code,
      'message': '$code happened',
      'retryable': false,
    });

    test('a terminal verdict populates errorCode (not just error)', () {
      relay.debugHandleFrame(errorFrame('NOT_AUTHORIZED'));

      expect(
        relay.currentState.errorCode,
        'NOT_AUTHORIZED',
        reason: 'consumers classify on errorCode, not error',
      );
      expect(relay.currentState.error, contains('NOT_AUTHORIZED'));
    });

    test(
      'LICENSE_UNAVAILABLE is not treated as a license-fatal error',
      () async {
        // LICENSE_UNAVAILABLE is deliberately absent from RelayLicenseErrorCode
        // (the relay couldn't reach the license service, so retrying is the
        // right move) — it must fall through to the generic errorStream/
        // errorCode path like any other terminal verdict, not get a
        // license-specific classification.
        expect(RelayLicenseErrorCode.fromWire('LICENSE_UNAVAILABLE'), isNull);

        final events = <ErrorMessage>[];
        relay.errorStream.listen(events.add);

        relay.debugHandleFrame(errorFrame('LICENSE_UNAVAILABLE'));
        await Future<void>.delayed(Duration.zero);

        expect(events.map((e) => e.code), ['LICENSE_UNAVAILABLE']);
        expect(relay.currentState.errorCode, 'LICENSE_UNAVAILABLE');
      },
    );

    test('a subsequent transition clears the stale errorCode', () {
      relay.debugHandleFrame(errorFrame('NOT_AUTHORIZED'));
      expect(relay.currentState.errorCode, 'NOT_AUTHORIZED');

      // `welcome` is the success path; copyWith's non-preserving errorCode means
      // it resets to null, so a stale verdict can't linger past a fresh
      // authentication.
      relay.debugHandleFrame(
        jsonEncode({
          'type': 'welcome',
          'deviceId': 'd1',
          'epoch': 1,
          'serverTime': '2026-07-16T00:00:00.000Z',
        }),
      );

      expect(relay.currentState.errorCode, isNull);
      expect(
        relay.currentState.connectionState,
        RelayConnectionState.authenticated,
      );
    });
  });
}
