import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:test/test.dart';

import 'support/fake_live_relay.dart';

class _Peer implements PeerLink {
  final states = StreamController<PeerLinkState>.broadcast(sync: true);
  final paths = StreamController<PeerPath>.broadcast(sync: true);

  @override
  Stream<IncomingSessionRecord> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => states.stream;
  @override
  Stream<PeerPath> get pathStream => paths.stream;
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  bool get isDispatchAllowed => true;
  @override
  PeerLinkDiagnostic? get netTap => null;
  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async =>
      PeerSendOutcome.accepted;
  @override
  Future<void> close() async {
    states.add(PeerLinkState.closed);
    await states.close();
    await paths.close();
  }
}

void main() {
  test('session consumes a non-relay link and ignores path changes', () async {
    final peer = _Peer();
    final handshaker = FakeHandshaker();
    final session = MachineSession(
      relay: peer,
      machineDeviceId: 'machine',
      handshaker: handshaker,
    );
    session.start();
    await session.ensureEstablished();
    peer.paths.add(PeerPath.direct);
    peer.paths.add(PeerPath.relay);
    expect(session.isEstablished, isTrue);
    expect(handshaker.performCalls, 1);
    peer.states.add(PeerLinkState.closed);
    expect(session.isEstablished, isFalse);
    await session.dispose();
    await peer.close();
  });
}
