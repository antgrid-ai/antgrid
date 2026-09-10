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
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Authenticates instantly and routes nothing: only which sessions get disposed
/// is under test here.
class _StubRelay extends RelayService {
  _StubRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  AppState _cur = const AppState();

  /// The agent going away and coming back is what arms a rekey.
  void presence(bool online) {
    if (!_presence.isClosed) _presence.add(online);
  }

  void inject(IncomingRouteMessage msg) {
    if (!_messages.isClosed) _messages.add(msg);
  }

  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
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
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {}

  @override
  void dispose() => unawaited(closeStreams());

  Future<void> closeStreams() async {
    if (!_states.isClosed) await _states.close();
    if (!_presence.isClosed) await _presence.close();
    if (!_messages.isClosed) await _messages.close();
  }
}

/// Hands back a scripted sequence of results, so a test can reach the teardowns
/// that only a rekey outcome can produce. A null entry is an attempt that never
/// confirmed.
class _FakeHandshaker implements SessionHandshaker {
  _FakeHandshaker(this._results);

  final List<SessionKeys?> _results;
  int calls = 0;

  @override
  Future<SessionKeys?> perform() async {
    final i = calls++;
    return _results[i < _results.length ? i : _results.length - 1];
  }

  @override
  void abort() {}
}

SessionKeys _keys(int fill) => SessionKeys(
  a2p: Uint8List(32)..fillRange(0, 32, fill),
  p2a: Uint8List(32)..fillRange(0, 32, fill + 1),
  confirm: Uint8List(32)..fillRange(0, 32, fill + 2),
);

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(64),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

const _pinA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _pinB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';

void main() {
  late _StubRelay relay;

  setUp(() => relay = _StubRelay());
  tearDown(() async {
    await relay.closeStreams();
    CngAesGcm.evictImportedKeys();
  });

  RelayMechanisms build({List<SessionKeys?>? handshakes}) => RelayMechanisms(
    buildHandshaker: handshakes == null
        ? null
        : (_) => _FakeHandshaker(handshakes),
    relay: relay,
    crypto: CryptoService(),
    machineDeviceId: 'M',
    identity: _identity(),
    phoneDeviceId: 'phone-1',
    phoneEd25519Seed: List<int>.filled(32, 7),
    epoch: 1,
    resolveCoords: () async => const ConnCoords(
      relayUrl: 'ws://relay.test',
      agentEd25519PubB64: _pinA,
    ),
    mintToken: () async => 'tok',
  );

  /// Puts key material in the cipher's cache the way a live session would: the
  /// stub relay never completes a handshake, so there is no other way to get a
  /// key in there.
  Future<void> sealOneFrame(int fill) async {
    await CngAesGcm().encrypt(
      const <int>[1, 2, 3],
      secretKey: SecretKeyData(Uint8List(32)..fillRange(0, 32, fill)),
    );
  }

  group('native cipher key retirement', () {
    setUp(() {
      expect(CngAesGcm.probe(), isTrue);
      CngAesGcm.evictImportedKeys();
    });

    test('release() retires the cipher keys with the session', () async {
      final mech = build();
      await mech.dial(
        const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
        'tok',
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

    test('a dropped socket retires the keys, without disposing the session',
        () async {
      // The common case and the one the dispose sites miss entirely: the
      // supervisor keeps the session for a reconnect, so nothing releases it.
      // Left uncovered, a laptop that loses wifi and sits idle holds the
      // session keys for the rest of the process.
      final mech = build();
      addTearDown(mech.release);
      await mech.dial(
        const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
        'tok',
      );
      await sealOneFrame(0x43);
      expect(CngAesGcm.importedKeyCount, 1);

      relay.disconnect();
      await pumpEventQueue();

      expect(CngAesGcm.importedKeyCount, 0);
      expect(
        mech.session,
        isNotNull,
        reason: 'the session must survive for the supervisor to reconnect it',
      );
    });

    test('replacing a stale-pinned session retires its keys too', () async {
      final mech = build();
      addTearDown(mech.release);
      await mech.dial(
        const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
        'tok',
      );
      await sealOneFrame(0x42);
      expect(CngAesGcm.importedKeyCount, 1);

      // The host re-provisioned: the old session is disposed mid-flight rather
      // than released, a path that zeroizes its keys just the same.
      await mech.dial(
        const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinB,
        ),
        'tok',
      );

      expect(CngAesGcm.importedKeyCount, 0);
    });

    /// Drives a real session to `established` through the handshaker seam, which
    /// is the only way to reach a teardown that does not dispose the session.
    Future<RelayMechanisms> established(List<SessionKeys?> handshakes) async {
      final mech = build(handshakes: handshakes);
      addTearDown(mech.release);
      const coords = ConnCoords(
        relayUrl: 'ws://relay.test',
        agentEd25519PubB64: _pinA,
      );
      await mech.dial(coords, 'tok');
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
        IncomingRouteMessage(
          from: 'M',
          channel: 'control',
          kind: FrameKind.sealed,
          payload: await E2eTransportDart(
            sendKey: keys.a2p,
            recvKey: keys.p2a,
          ).seal(jsonEncode({'type': 'session-takeover'})),
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

    test('a rekey that never confirmed retires the keys it tore down',
        () async {
      final mech = await established([_keys(0x20), null]);
      await sealOneFrame(0x45);
      expect(CngAesGcm.importedKeyCount, 1);

      // The agent bounces: coming back arms a rekey, and this attempt fails.
      relay.presence(false);
      relay.presence(true);
      for (var i = 0; i < 50 && mech.session!.isEstablished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(mech.session!.isEstablished, isFalse);
      await pumpEventQueue();

      expect(CngAesGcm.importedKeyCount, 0);
    });
  }, skip: Platform.isWindows ? false : 'CNG is the only cipher that caches');
}
