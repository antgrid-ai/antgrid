import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Payload implements PeerLink {
  bool closed = false;
  final states = StreamController<PeerLinkState>.broadcast(sync: true);
  final paths = StreamController<PeerPath>.broadcast(sync: true);
  @override
  bool get isDispatchAllowed => !closed;
  @override
  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();
  @override
  Stream<PeerLinkState> get payloadStateStream => states.stream;
  @override
  Stream<PeerPath> get pathStream => paths.stream;
  @override
  Stream<void> get peerRestartStream => const Stream.empty();
  @override
  Stream<PeerLinkFailure> get failureStream => const Stream.empty();
  @override
  PeerLinkDiagnostic? get netTap => null;
  @override
  Future<PeerSendOutcome> sendFrame(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async => closed ? PeerSendOutcome.closed : PeerSendOutcome.accepted;
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    states.add(PeerLinkState.closed);
    await Future<void>.value();
    await states.close();
    await paths.close();
  }
}

class _Runtime extends PeerRuntime {
  _Runtime(this.payload)
    : super(
        record: DeviceRecord(
          userId: 'account',
          deviceUuid: 'phone',
          clientId: 'credential',
          clientSecret: 'secret',
          ed25519Pub: base64Encode(Uint8List(32)),
          ed25519Priv: base64Encode(Uint8List(32)),
          x25519Pub: '',
          x25519Priv: '',
          endpointSecret: base64Encode(Uint8List(32)),
        ),
        licenseApiUrl: 'https://api.test',
        mintToken: () async => 'token',
      );
  final _Payload payload;
  Completer<void>? gate;
  bool selecting = false;
  @override
  void retain() {}
  @override
  void release() {}
  @override
  Future<SelectedPeerLink> select({
    required PeerLinkSelector selector,
    required RelayService relay,
    required String machineDeviceId,
    required String machinePublicKey,
    PeerTransportMode? mode,
    Future<void>? centralReady,
  }) async {
    selecting = true;
    await gate?.future;
    return SelectedPeerLink(payload, independent: true);
  }
}

class _Relay extends RelayService {
  _Relay() : super(crypto: CryptoService());
  final states = StreamController<AppState>.broadcast();
  final presence = StreamController<bool>.broadcast();
  AppState state = const AppState();
  int dials = 0;
  Completer<void>? gate;
  @override
  AppState get currentState => state;
  @override
  Stream<AppState> get stateStream => states.stream;
  @override
  Stream<bool> get peerPresenceStream => presence.stream;
  @override
  Future<void> connect(
    String url,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
    String? machineDeviceId,
  }) async {
    dials++;
    await gate?.future;
    state = const AppState(connectionState: RelayConnectionState.authenticated);
    if (!states.isClosed) states.add(state);
  }

  @override
  void disconnect() {
    state = const AppState();
    if (!states.isClosed) states.add(state);
  }

  @override
  void dispose() {
    super.dispose();
    states.close();
    presence.close();
  }
}

class _Handshake implements SessionHandshaker {
  int calls = 0;
  @override
  Future<SessionKeys?> perform() async {
    calls++;
    return SessionKeys(
      a2p: Uint8List(32),
      p2a: Uint8List(32),
      confirm: Uint8List(32),
    );
  }

  @override
  void abort() {}
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

RelayMechanisms _mechanisms(
  _Relay relay,
  _Runtime runtime,
  _Handshake handshake,
) => RelayMechanisms(
  relay: relay,
  crypto: CryptoService(),
  machineDeviceId: 'machine',
  identity: DeviceIdentity(
    deviceId: 'phone',
    name: 'test',
    ed25519PrivateKey: Uint8List(32),
    ed25519PublicKey: Uint8List(32),
    x25519PrivateKey: Uint8List(32),
    x25519PublicKey: Uint8List(32),
  ),
  phoneDeviceId: 'phone',
  phoneEd25519Seed: Uint8List(32),
  epoch: 1,
  resolveCoords: () async =>
      const ConnCoords(relayUrl: 'wss://relay.test', agentEd25519PubB64: 'pin'),
  mintToken: () async => 'token',
  peerRuntime: runtime,
  buildHandshaker: (_) => handshake,
);

void main() {
  test(
    'central reconnect and path changes preserve the native E2E session',
    () async {
      final relay = _Relay();
      final payload = _Payload();
      final runtime = _Runtime(payload);
      final handshake = _Handshake();
      final connection = RelayConnection(
        machineDeviceId: 'machine',
        crypto: CryptoService(),
        relayOverride: relay,
      );
      connection.ensureStarted(
        mechanisms: _mechanisms(relay, runtime, handshake),
      );
      await _settle();
      final session = connection.session;
      expect(connection.supervisor!.status, const Connected());
      expect(handshake.calls, 1);
      relay.gate = Completer<void>();
      relay.disconnect();
      relay.presence.add(false);
      payload.paths.add(PeerPath.relay);
      payload.paths.add(PeerPath.direct);
      await _settle();
      expect(relay.dials, 2);
      expect(connection.session, same(session));
      expect(session!.isEstablished, isTrue);
      expect(handshake.calls, 1);
      expect(connection.supervisor!.status, const Connected());
      relay.gate!.complete();
      await _settle();
      expect(handshake.calls, 1);
      await connection.dispose();
      await runtime.dispose();
    },
  );

  test('release fences a late native selection and closes it', () async {
    final relay = _Relay();
    final payload = _Payload();
    final runtime = _Runtime(payload)..gate = Completer<void>();
    final mechanisms = _mechanisms(relay, runtime, _Handshake());
    final dialing = mechanisms.dial(
      const ConnCoords(relayUrl: 'wss://relay.test', agentEd25519PubB64: 'pin'),
      'token',
    );
    await _settle();
    expect(runtime.selecting, isTrue);
    await mechanisms.release();
    runtime.gate!.complete();
    await dialing;
    expect(payload.closed, isTrue);
    expect(mechanisms.session, isNull);
    relay.dispose();
    await runtime.dispose();
  });
}
