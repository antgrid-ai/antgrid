// Admission is account trust; the app never sends a pair-request. An
// un-upgraded relay binary may still push `pair-connected`, `grant-revoked`,
// `pair-approval` and `pair-rejected` at a v3 app. Parsing must stay
// TOLERANT: a legacy (or simply unknown) frame type is ignored — never
// thrown, never a state transition, never fatal to the socket.
import 'dart:convert';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

void main() {
  test('legacy pair frames from an un-swept relay are ignored, never fatal', () {
    final relay = RelayService(crypto: CryptoService());
    addTearDown(relay.dispose);

    relay.debugHandleFrame(
      jsonEncode({
        'type': 'welcome',
        'deviceId': 'd1',
        'epoch': 1,
        'serverTime': '2026-07-16T00:00:00.000Z',
      }),
    );
    expect(
      relay.currentState.connectionState,
      RelayConnectionState.authenticated,
      reason: 'precondition: the socket is live before the legacy frames land',
    );

    // Well-formed under the OLD schema — an un-swept relay sends complete
    // frames, so "ignored" has to hold for valid ones, not just malformed ones.
    relay.debugHandleFrame(
      jsonEncode({
        'type': 'pair-connected',
        'peerId': 'x',
        'peerName': 'machine',
        'peerType': 'agent',
      }),
    );
    expect(
      relay.currentState.connectionState,
      RelayConnectionState.authenticated,
      reason: 'pair-connected must not promote the connection state',
    );

    relay.debugHandleFrame(
      jsonEncode({
        'type': 'grant-revoked',
        'peerDeviceId': 'x',
        'reason': 'REVOKED',
      }),
    );
    relay.debugHandleFrame(
      jsonEncode({
        'type': 'pair-approval',
        'pairId': 'pid',
        'phonePubkey': 'pk',
        'phoneDeviceId': 'p1',
        'nonce': 'n',
        'expiresAt': '2030-01-01T00:00:00.000Z',
        'signature': 'sig',
      }),
    );
    relay.debugHandleFrame(
      jsonEncode({
        'type': 'pair-rejected',
        'pairId': 'pid',
        'phonePubkey': 'pk',
        'reason': 'UNKNOWN_PHONE',
      }),
    );
    // A type this client has never known must take the same path.
    relay.debugHandleFrame(jsonEncode({'type': 'something-from-the-future'}));

    expect(
      relay.currentState.connectionState,
      isNot(RelayConnectionState.disconnected),
    );
    expect(
      relay.currentState.connectionState,
      RelayConnectionState.authenticated,
      reason: 'a legacy frame must not move the connection state',
    );
    expect(
      relay.currentState.errorCode,
      isNull,
      reason: 'a legacy frame is not an error the app should surface',
    );
    expect(relay.currentState.peerDeviceId, isNull);
  });
}
