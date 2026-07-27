// `AppSessionHandshaker` pins the agent's Ed25519 key at construction, so a
// [MachineSession] can only ever verify one agent identity. When the coords
// step comes back with a DIFFERENT pin — the host re-provisioned its identity —
// reusing the live session would keep verifying against a key that no longer
// exists, and the user's Retry would be inert: only "forget the machine"
// (which releases the connection) could recover.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Authenticates instantly; records nothing else. The E2E handshake never
/// completes against it, which is irrelevant here — only which session object
/// a dial binds to is under test.
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
  tearDown(() async => relay.closeStreams());

  RelayMechanisms build({ConnCoords Function()? coords}) => RelayMechanisms(
    relay: relay,
    crypto: CryptoService(),
    machineDeviceId: 'M',
    identity: _identity(),
    phoneDeviceId: 'phone-1',
    phoneEd25519Seed: List<int>.filled(32, 7),
    epoch: 1,
    resolveCoords: () async =>
        coords?.call() ??
        const ConnCoords(
          relayUrl: 'ws://relay.test',
          agentEd25519PubB64: _pinA,
        ),
    mintToken: () async => 'tok',
  );

  test('a dial at the same pin reuses the live session', () async {
    final mech = build();
    addTearDown(mech.release);

    await mech.dial(
      const ConnCoords(relayUrl: 'ws://relay.test', agentEd25519PubB64: _pinA),
      'tok',
    );
    final first = mech.session;
    expect(first, isNotNull);

    await mech.dial(
      const ConnCoords(relayUrl: 'ws://relay.test', agentEd25519PubB64: _pinA),
      'tok',
    );
    expect(
      identical(mech.session, first),
      isTrue,
      reason: 'a plain redial must not orphan the project streams',
    );
  });

  test('a dial at a CHANGED pin rebuilds the session and disposes the old one '
      '(zeroizing its keys)', () async {
    final mech = build();
    addTearDown(mech.release);

    await mech.dial(
      const ConnCoords(relayUrl: 'ws://relay.test', agentEd25519PubB64: _pinA),
      'tok',
    );
    final first = mech.session!;
    var oldDisposed = false;
    // `MachineSession.dispose()` closes this controller (and zeroizes the
    // session keys on the way), so its onDone is the observable proof that the
    // stale-pinned session was actually torn down rather than merely dropped.
    first.takeoverEvents.listen(null, onDone: () => oldDisposed = true);

    await mech.dial(
      const ConnCoords(relayUrl: 'ws://relay.test', agentEd25519PubB64: _pinB),
      'tok',
    );

    expect(
      identical(mech.session, first),
      isFalse,
      reason:
          'the handshaker pins the agent key at construction, so a new pin '
          'needs a new session',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      oldDisposed,
      isTrue,
      reason: 'the stale-pinned session must be disposed',
    );
  });

  // The ladder reaches a re-provisioned host through `establishSession`, not
  // through `dial`: the socket goes to the RELAY, so a host swapping its
  // Ed25519 identity never breaks the socket rung, and `_lowestBrokenRung`
  // returns `established`. A pin check that only runs on a dial is unreachable
  // on this path, which is the whole scenario it was written for.
  test('the ladder path — socket still authenticated, pin changed — rebuilds '
      'the session in establishSession', () async {
    var pin = _pinA;
    final mech = build(
      coords: () =>
          ConnCoords(relayUrl: 'ws://relay.test', agentEd25519PubB64: pin),
    );
    addTearDown(mech.release);

    // Rung 1: coords.
    final first = await mech.resolveCoords();
    expect(first!.agentEd25519PubB64, _pinA);
    // Rung 2: socket.
    await mech.dial(first, 'tok');
    final stale = mech.session!;
    var staleDisposed = false;
    stale.takeoverEvents.listen(null, onDone: () => staleDisposed = true);
    expect(mech.socketAuthenticated, isTrue);

    // The host re-provisions. The user presses Retry, which drops the cached
    // coordinates, so the coords step runs again — but nothing dropped the
    // socket, so the socket rung stays satisfied and `dial` is never re-entered.
    pin = _pinB;
    await mech.resolveCoords();
    expect(
      mech.socketAuthenticated,
      isTrue,
      reason:
          'the socket rung must still be satisfied, or this is not the '
          'path under test',
    );

    // Rung 4: established — the lowest broken rung on this path.
    final pending = mech.establishSession();
    // The rebuild happens before the handshake is awaited; the step itself
    // cannot finish against a stub relay.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      identical(mech.session, stale),
      isFalse,
      reason: 'establishSession must honour the new pin, or Retry is inert',
    );
    expect(
      staleDisposed,
      isTrue,
      reason: 'the stale-pinned session must be disposed (zeroizing its keys)',
    );

    // A socket drop is the step's own fast-fail path; use it to unwedge the
    // attempt rather than serving out the establish timeout.
    relay.disconnect();
    await expectLater(pending, throwsA(anything));
  });
}
