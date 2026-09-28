// `MachineSession.relay` is fixed at construction, so a session outliving the
// link it was built on reads a closed link forever. These pin that a redial
// keeps the session only while the link is the same one.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixed_peer_connector.dart';

/// Authenticates instantly and routes nothing: only which sessions get disposed
/// is under test here.
class _StubRelay extends RelayService implements PeerLink {
  @override
  bool get isDispatchAllowed => true;
  @override
  Stream<PeerLinkState> get payloadStateStream => _payloadStates.stream;
  @override
  Stream<PeerPath> get pathStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  _StubRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _payloadStates = StreamController<PeerLinkState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _messages = StreamController<IncomingSessionRecord>.broadcast();
  AppState _cur = const AppState();

  void dropPayload() => _payloadStates.add(PeerLinkState.closed);

  @override
  Stream<IncomingSessionRecord> get messageStream => _messages.stream;
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => const Stream.empty();
  @override
  AppState get currentState => _cur;

  @override
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
    String? machineDeviceId,
  }) async {
    _cur = const AppState(connectionState: RelayConnectionState.authenticated);
    if (!_states.isClosed) _states.add(_cur);
  }

  @override
  void disconnect() {
    _cur = const AppState();
    if (!_states.isClosed) _states.add(_cur);
  }

  @override
  Future<PeerSendOutcome> sendRecord(Uint8List payload) async {
    if (!isDispatchAllowed) return PeerSendOutcome.closed;
    return PeerSendOutcome.accepted;
  }

  @override
  Future<PeerStream> openStream(
    StreamOpen open, {
    required int maxRecordBytes,
    required int maxQueuedBytes,
    int? rawAfterRecords,
  }) => throw UnimplementedError('not exercised by this suite');

  /// The session's only recovery is closing its link; a real link reports
  /// that as a closed payload, which is the teardown under test.
  @override
  Future<void> close() async => dropPayload();

  @override
  void dispose() => unawaited(closeStreams());

  Future<void> closeStreams() async {
    if (!_states.isClosed) await _states.close();
    if (!_presence.isClosed) await _presence.close();
    if (!_messages.isClosed) await _messages.close();
    if (!_payloadStates.isClosed) await _payloadStates.close();
  }
}

const _pinA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Hands back a NEW link on every dial, as the production runtime does (each
/// connect wraps a fresh native connection). [FixedPeerConnector] returns one
/// link forever, so it cannot tell a session bound to the live link from one
/// still bound to the link a redial closed.
class _FreshLinkConnector extends FixedPeerConnector {
  _FreshLinkConnector(this.carrier) : super(carrier);
  final PeerLink carrier;
  @override
  Future<PeerLink> connect({
    required PeerConnectionAttempt attempt,
    PeerLinkDiagnostic? diagnostic,
    required String machineDeviceId,
    required String machinePublicKey,
  }) async => TestPayloadLink(carrier);
}

/// [TestPayloadLink.close] is a no-op, but the session's timeout recovery IS
/// a link close, so this carrier has to see it for the teardown to run.
class _ClosingPayloadLink extends TestPayloadLink {
  _ClosingPayloadLink(super.carrier);
  @override
  Future<void> close() => carrier.close();
}

class _ClosingLinkConnector extends FixedPeerConnector {
  _ClosingLinkConnector(super.carrier)
    : _link = _ClosingPayloadLink(carrier);
  final PeerLink _link;
  @override
  PeerLink get link => _link;
}

void main() {
  late _StubRelay relay;

  setUp(() => relay = _StubRelay());
  tearDown(() => relay.closeStreams());

  PeerConnectionMechanisms build({bool freshLinkPerDial = false}) =>
      PeerConnectionMechanisms(
        peerRuntime: freshLinkPerDial
            ? _FreshLinkConnector(relay)
            : _ClosingLinkConnector(relay),
        machineDeviceId: 'M',
        resolveCoords: () async => const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
      );

  group('session binding to the payload link', () {
    const coords = ConnCoords(
      relayUrl: 'ws://relay.test',
      agentEd25519PubB64: _pinA,
    );

    test('a redial that returns the same link reuses the live session', () async {
      final mech = build();
      addTearDown(mech.release);
      await mech.connectPayload(coords);
      final first = mech.session;

      await mech.connectPayload(coords);

      expect(
        identical(mech.session, first),
        isTrue,
        reason: 'a plain redial must not orphan the project streams',
      );
    });

    test('a redial onto a new link rebuilds the session on it, disposes the '
        'old one and signals the replacement', () async {
      final mech = build(freshLinkPerDial: true);
      addTearDown(mech.release);
      final replaced = <PeerConnectionEvent>[];
      mech.events.listen((e) {
        if (e is PeerSessionReplaced) replaced.add(e);
      });
      await mech.connectPayload(coords);
      final stale = mech.session!;
      var staleDisposed = false;
      stale.sessionDownEvents.listen(null, onDone: () => staleDisposed = true);

      await mech.connectPayload(coords);

      expect(identical(mech.session, stale), isFalse);
      expect(identical(mech.session!.relay, mech.payloadLink), isTrue);
      await pumpEventQueue();
      expect(staleDisposed, isTrue);
      expect(
        replaced,
        hasLength(1),
        reason: 'every project transport hangs off the disposed session',
      );
    });
  });
}
