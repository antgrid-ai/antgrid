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
  AppState _cur = const AppState();

  @override
  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();
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
  }
}

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

  RelayMechanisms build() => RelayMechanisms(
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
  }, skip: Platform.isWindows ? false : 'CNG is the only cipher that caches');
}
