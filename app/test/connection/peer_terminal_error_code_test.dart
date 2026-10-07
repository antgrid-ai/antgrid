import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixed_peer_connector.dart';

const _coords = ConnCoords(
  relayUrl: 'wss://relay.test',
  agentEd25519PubB64: 'pin',
);

Future<List<PeerConnectionEvent>> _dial(Object error) async {
  final mechanisms = PeerConnectionMechanisms(
    machineDeviceId: 'M',
    resolveCoords: () async => _coords,
    peerRuntime: FailingPeerConnector(error),
  );
  final events = <PeerConnectionEvent>[];
  final sub = mechanisms.events.listen(events.add);
  await expectLater(mechanisms.connectPayload(_coords), throwsA(anything));
  await mechanisms.release();
  await sub.cancel();
  return events;
}

List<String> _codes(List<PeerConnectionEvent> events) =>
    events.whereType<PeerTerminalError>().map((e) => e.code).toList();

void main() {
  test('a terminal connection failure carries its own code', () async {
    final events = await _dial(
      const PeerConnectionFailure('PEER_IDENTITY_DENIED', terminal: true),
    );
    expect(_codes(events), ['PEER_IDENTITY_DENIED']);
  });

  test('a lease that lapses mid-dial is not a peer rejection', () async {
    final events = await _dial(authorizationChangedDuringConnect);
    expect(events.whereType<PeerTerminalError>(), isEmpty);
  });

  test('a retryable connection failure emits no terminal error', () async {
    final events = await _dial(
      const PeerConnectionFailure('LEASE_EXPIRED', terminal: false),
    );
    expect(events.whereType<PeerTerminalError>(), isEmpty);
  });

  test('an authorization denial carries the fixed denied code', () async {
    final events = await _dial(const PeerAuthorizationDenied());
    expect(_codes(events), [kPeerAuthorizationDeniedCode]);
    expect(kPeerAuthorizationDeniedCode, 'PEER_AUTHORIZATION_DENIED');
  });

  test(
    'a malformed authorization answer carries the fixed malformed code',
    () async {
      final events = await _dial(const FormatException('bad'));
      final codes = _codes(events);
      expect(codes, [kPeerAuthorizationMalformedCode]);
      expect(codes.single, isNot(contains('bad')));
    },
  );
}
