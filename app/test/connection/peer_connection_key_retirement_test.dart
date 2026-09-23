// A native transport cipher caches per-key state so that the stateless
// `E2eTransportDart` does not pay key setup per frame. `SessionKeys.zeroize`
// cannot reach that copy, and the cache evicts by USE — so once a session is
// torn down and no further keys are imported, nothing retires it and the key
// material lives as long as the process. Signing out and closing the laptop is
// exactly that case.
//
// Disposing the session is the only place the app knows those keys are dead,
// which is what these tests pin. Nothing else observes the eviction, so a
// dropped call here is silent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid/config/cng_aes_gcm.dart';
import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/peer_connection.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
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
  final _messages = StreamController<IncomingPeerFrame>.broadcast();
  AppState _cur = const AppState();

  void dropPayload() => _payloadStates.add(PeerLinkState.closed);

  void inject(IncomingPeerFrame msg) {
    if (!_messages.isClosed) _messages.add(msg);
  }

  @override
  Stream<IncomingPeerFrame> get messageStream => _messages.stream;
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
  Future<PeerSendOutcome> sendFrame(String channel, Uint8List payload) async {
    if (!isDispatchAllowed) return PeerSendOutcome.closed;
    return PeerSendOutcome.accepted;
  }

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

/// Hands back a scripted sequence of results, so a test can reach the teardowns
/// that only an establishment outcome can produce. A null entry is an attempt that never
/// confirmed.
class _FakeHandshaker implements SessionHandshaker {
  _FakeHandshaker(this._results);

  final List<SessionKeys?> _results;
  int calls = 0;

  @override
  Future<bool> perform() async {
    final i = calls++;
    return _results[i < _results.length ? i : _results.length - 1] != null;
  }

  @override
  void abort() {}
}

SessionKeys _keys(int fill) => SessionKeys(
  a2p: Uint8List(32)..fillRange(0, 32, fill),
  p2a: Uint8List(32)..fillRange(0, 32, fill + 1),
  confirm: Uint8List(32)..fillRange(0, 32, fill + 2),
);

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
  _ClosingLinkConnector(PeerLink carrier)
    : _link = _ClosingPayloadLink(carrier),
      super(carrier);
  final PeerLink _link;
  @override
  PeerLink get link => _link;
}

void main() {
  late _StubRelay relay;

  setUp(() => relay = _StubRelay());
  tearDown(() async {
    await relay.closeStreams();
    CngAesGcm.evictImportedKeys();
  });

  PeerConnectionMechanisms build({
    List<SessionKeys?>? handshakes,
    bool freshLinkPerDial = false,
  }) => PeerConnectionMechanisms(
        buildHandshaker: handshakes == null
            ? null
            : () => _FakeHandshaker(handshakes),
        peerRuntime: freshLinkPerDial
            ? _FreshLinkConnector(relay)
            : _ClosingLinkConnector(relay),
        machineDeviceId: 'M',
        resolveCoords: () async => const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
      );

  /// Puts key material in the cipher's cache the way a live session would: the
  /// stub relay never completes a handshake, so there is no other way to get a
  /// key in there.
  Future<void> sealOneFrame(int fill) async {
    await CngAesGcm().encrypt(const <int>[
      1,
      2,
      3,
    ], secretKey: SecretKeyData(Uint8List(32)..fillRange(0, 32, fill)));
  }

  // `MachineSession.relay` is fixed at construction, so a session outliving
  // the link it was built on reads a closed link forever. Platform-independent,
  // unlike the cipher group below.
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
      stale.takeoverEvents.listen(null, onDone: () => staleDisposed = true);

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

  group('native cipher key retirement', () {
    setUp(() {
      expect(CngAesGcm.probe(), isTrue);
      CngAesGcm.evictImportedKeys();
    });

    test('release() retires the cipher keys with the session', () async {
      final mech = build();
      await mech.connectPayload(
        const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
      );
      await sealOneFrame(0x41);
      expect(CngAesGcm.importedKeyCount, 1);

      await mech.release();

      expect(
        CngAesGcm.importedKeyCount,
        0,
        reason: 'a released connection leaves no key material behind',
      );
    });

    test(
      'a dropped socket retires the keys, without disposing the session',
      () async {
        // The common case and the one the dispose sites miss entirely: the
        // supervisor keeps the session for a reconnect, so nothing releases it.
        // Left uncovered, a laptop that loses wifi and sits idle holds the
        // session keys for the rest of the process.
        final mech = build();
        addTearDown(mech.release);
        await mech.connectPayload(
          const ConnCoords(
            relayUrl: 'ws://relay.test',
            agentEd25519PubB64: _pinA,
          ),
        );
        await sealOneFrame(0x43);
        expect(CngAesGcm.importedKeyCount, 1);

        relay.dropPayload();
        await pumpEventQueue();

        expect(CngAesGcm.importedKeyCount, 0);
        expect(
          mech.session,
          isNotNull,
          reason: 'the session must survive for the supervisor to reconnect it',
        );
      },
    );

    test('replacing a session bound to a redialed-away link retires its keys '
        'too', () async {
      final mech = build(freshLinkPerDial: true);
      addTearDown(mech.release);
      const coords = ConnCoords(
        relayUrl: 'ws://relay.test',
        agentEd25519PubB64: _pinA,
      );
      await mech.connectPayload(coords);
      await sealOneFrame(0x42);
      expect(CngAesGcm.importedKeyCount, 1);

      // The old session is disposed mid-flight rather than released, a path
      // that has to zeroize its keys just the same.
      await mech.connectPayload(coords);

      expect(CngAesGcm.importedKeyCount, 0);
    });

    /// Drives a real session to `established` through the handshaker seam, which
    /// is the only way to reach a teardown that does not dispose the session.
    Future<PeerConnectionMechanisms> established(
      List<SessionKeys?> handshakes,
    ) async {
      final mech = build(handshakes: handshakes);
      addTearDown(mech.release);
      const coords = ConnCoords(
        relayUrl: 'ws://relay.test',
        agentEd25519PubB64: _pinA,
      );
      await mech.connectPayload(coords);
      await mech.resolveCoords();
      await mech.establishSession();
      expect(mech.session!.isEstablished, isTrue);
      return mech;
    }

    test('an agent takeover retires the keys it just invalidated', () async {
      // The agent handed the session to another device and dropped these keys.
      // It is reported, never auto-repaired, so no later handshake comes along
      // to push the dead keys out of the cache by use.
      final keys = _keys(0x10);
      final mech = await established([keys]);
      await sealOneFrame(0x44);
      expect(CngAesGcm.importedKeyCount, 1);

      relay.inject(
        IncomingPeerFrame(
          channel: 'control',
          payload: Uint8List.fromList(
            utf8.encode(jsonEncode({'type': 'session-takeover'})),
          ),
        ),
      );
      await pumpEventQueue();

      expect(
        mech.session!.isEstablished,
        isFalse,
        reason: 'the real teardown must have run, not merely the event',
      );
      expect(CngAesGcm.importedKeyCount, 0);
    });

    test(
      'a link closed on repeated timeouts retires the keys it tore down',
      () async {
        final mech = await established([_keys(0x20), null]);
        await sealOneFrame(0x45);
        expect(CngAesGcm.importedKeyCount, 1);

        // Repeated RPC timeouts close the link.
        for (var i = 0; i < 3; i++) {
          mech.session!.notifyRpcResult(timedOut: true);
        }
        for (var i = 0; i < 50 && mech.session!.isEstablished; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(mech.session!.isEstablished, isFalse);
        await pumpEventQueue();

        expect(CngAesGcm.importedKeyCount, 0);
      },
    );
  }, skip: Platform.isWindows ? false : 'CNG is the only cipher that caches');
}
