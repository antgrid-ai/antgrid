// Every terminal condition the connection ladder can hit must land as an
// explicit `Blocked(reason)`, with a producer wired for its documented
// unblock — not a side channel the app happens to also listen to. This drives
// a FAKE relay socket through the REAL `RelayMechanisms` adapter and a REAL
// `ConnectionSupervisor`. The licenseExpired/superseded/sessionTakenOver
// cases go through the actual production entry point
// (`RelayConnection.ensureStarted`, app/lib/providers/relay_connection.dart),
// so deleting one of its listeners fails those tests, not just this file's
// own hand-fed input. The handshakeFailing case cannot: it needs a custom
// backoff/jitter `ensureStarted` hardcodes, so it stays hand-wired and only
// proves the supervisor's own reaction, not the production wiring.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/screens/workspace_shell.dart'
    show workspaceBlockingError;
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay socket: `connect()` drives the same state transitions a real
/// `welcome`/`peer-online` would, without a WebSocket. Mirrors
/// app/test/providers/relay_connection_supervisor_test.dart's `_ScriptedRelay`.
class _ScriptedRelay extends RelayService {
  _ScriptedRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();

  final List<String> dialedTokens = <String>[];
  bool announcePeer = true;

  /// When set, every `connect()` loses at the relay: the typed error frame is
  /// delivered and the dial rejects, exactly as the real `RelayService.connect`
  /// does for a `retryable:false` verdict.
  ErrorMessage? connectError;

  AppState _cur = const AppState();

  @override
  AppState get currentState => _cur;
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  Stream<IncomingRouteMessage> get messageStream => _messages.stream;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => _errors.stream;

  void push(AppState s) {
    _cur = s;
    if (!_states.isClosed) _states.add(s);
  }

  void presence(bool online) {
    if (!_presence.isClosed) _presence.add(online);
  }

  /// Mirrors what the REAL `RelayService._handleError` does for a
  /// `retryable:false` frame (state → disconnected, presence → false) — the
  /// fake must reproduce that or a redial after unblocking would never find a
  /// broken socket rung to climb.
  void pushError(ErrorMessage e) {
    if (!_errors.isClosed) _errors.add(e);
    if (!e.retryable) {
      push(
        AppState(
          connectionState: RelayConnectionState.disconnected,
          errorCode: e.code,
        ),
      );
      presence(false);
    }
  }

  @override
  Future<void> connect(
    String relayUrl,
    DeviceIdentity identity, {
    required String licenseToken,
    required int epoch,
    String? machineDeviceId,
  }) async {
    dialedTokens.add(licenseToken);
    final err = connectError;
    if (err != null) {
      pushError(err);
      throw RelayConnectException(
        code: err.code,
        retryable: err.retryable,
        message: err.message,
      );
    }
    push(const AppState(connectionState: RelayConnectionState.authenticated));
    if (announcePeer) presence(true);
  }

  @override
  void disconnect() {
    push(const AppState());
    presence(false);
  }

  @override
  void dispose() {
    unawaited(closeStreams());
  }

  Future<void> closeStreams() async {
    if (!_states.isClosed) await _states.close();
    if (!_messages.isClosed) await _messages.close();
    if (!_presence.isClosed) await _presence.close();
    if (!_errors.isClosed) await _errors.close();
  }
}

/// The E2E handshake needs a live agent no fake relay can produce, so
/// stubbing the established rung is what lets these tests reach [Connected].
/// `simulateTakeover()` also flips [sessionEstablished] back to false —
/// mirroring how a real `session-takeover` tears the E2E session down — so a
/// subsequent `retry()` has an established rung to actually re-climb.
class _EstablishStubbed extends RelayMechanisms {
  _EstablishStubbed({
    required super.relay,
    required super.crypto,
    required super.machineDeviceId,
    required super.identity,
    required super.phoneDeviceId,
    required super.phoneEd25519Seed,
    required super.epoch,
    required super.resolveCoords,
    required super.mintToken,
  });

  bool _established = false;
  int establishCalls = 0;

  @override
  Future<void> establishSession() async {
    establishCalls++;
    _established = true;
  }

  @override
  bool get sessionEstablished => _established;

  void simulateTakeover() {
    _established = false;
    onSessionTakenOver?.call();
  }
}

/// Every attempt fails — models a peer that never completes a handshake for
/// reasons a retry cannot fix (mirrors `_kMaxInitialHandshakeAttempts`).
class _EstablishAlwaysFails extends RelayMechanisms {
  _EstablishAlwaysFails({
    required super.relay,
    required super.crypto,
    required super.machineDeviceId,
    required super.identity,
    required super.phoneDeviceId,
    required super.phoneEd25519Seed,
    required super.epoch,
    required super.resolveCoords,
    required super.mintToken,
  });

  int establishCalls = 0;

  @override
  Future<void> establishSession() async {
    establishCalls++;
    throw StateError('handshake refused');
  }

  @override
  bool get sessionEstablished => false;
}

DeviceIdentity _identity() => DeviceIdentity(
  deviceId: 'phone-1',
  name: 'Test Phone',
  ed25519PrivateKey: Uint8List(64),
  ed25519PublicKey: Uint8List(32),
  x25519PrivateKey: Uint8List(32),
  x25519PublicKey: Uint8List(32),
);

Future<void> _waitUntil(
  bool Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late _ScriptedRelay relay;
  late int mintCalls;

  setUp(() {
    relay = _ScriptedRelay();
    mintCalls = 0;
  });

  tearDown(() async {
    await relay.closeStreams();
  });

  Future<String> defaultMint() async => 'token-${++mintCalls}';

  _EstablishStubbed climbableMech() => _EstablishStubbed(
    relay: relay,
    crypto: CryptoService(),
    machineDeviceId: 'M',
    identity: _identity(),
    phoneDeviceId: 'phone-1',
    phoneEd25519Seed: List<int>.filled(32, 7),
    epoch: 1,
    resolveCoords: () async => const ConnCoords(
      relayUrl: 'ws://relay.test',
      agentEd25519PubB64: 'AGENT_PUB',
    ),
    mintToken: defaultMint,
  );

  /// Routes [mech] through the REAL production entry point —
  /// `RelayConnection.ensureStarted` (app/lib/providers/relay_connection.dart)
  /// — instead of hand-rebuilding its listeners. This is what makes deleting a
  /// production listener (the errorStream subscription, `onSessionTakenOver`)
  /// fail these tests instead of passing them.
  ConnectionSupervisor wireProduction(RelayMechanisms mech) {
    final conn = RelayConnection(
      machineDeviceId: 'M',
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);
    conn.ensureStarted(mechanisms: mech);
    return conn.supervisor!;
  }

  /// Hand-rebuilds the same listeners `RelayConnection.ensureStarted` wires in
  /// production, for the ONE case that cannot go through it: handshakeFailing
  /// needs a custom `backoffBaseMs`/`jitter` that `ensureStarted` hardcodes.
  /// This proves the supervisor's own reaction to a hand-fed input, not the
  /// production wiring.
  ConnectionSupervisor wire(
    RelayMechanisms mech, {
    int backoffBaseMs = 1000,
    int backoffCapMs = 30000,
    int Function(int maxExclusive)? jitter,
  }) {
    final supervisor = ConnectionSupervisor(
      mech,
      backoffBaseMs: backoffBaseMs,
      backoffCapMs: backoffCapMs,
      jitter: jitter,
    );
    mech.onTerminalAuthError = (code) =>
        supervisor.noteRelayError(code, retryable: false);
    mech.onSessionTakenOver = supervisor.noteSessionTakenOver;
    relay.stateStream.listen((s) {
      supervisor.noteSocketState(
        authenticated:
            s.connectionState.index >= RelayConnectionState.authenticated.index,
      );
      if (s.connectionState == RelayConnectionState.disconnected) {
        supervisor.noteSessionDown();
      }
    });
    relay.errorStream.listen(
      (e) => supervisor.noteRelayError(e.code, retryable: e.retryable),
    );
    // Mechanism level first, exactly as production does — the supervisor reads
    // `agentOnline` synchronously inside notePresence.
    relay.peerPresenceStream.listen((online) {
      mech.notePresence(online);
      supervisor.notePresence(online);
    });
    supervisor.setWanted(true);
    return supervisor;
  }

  test('LICENSE_EXPIRED blocks the ladder, and noteFreshToken() unblocks it '
      'into a dial with a freshly minted token', () async {
    final mech = climbableMech();
    final supervisor = wireProduction(mech);
    await _waitUntil(() => supervisor.status is Connected);
    expect(relay.dialedTokens, ['token-1']);

    relay.pushError(
      const ErrorMessage(
        code: 'LICENSE_EXPIRED',
        message: 'expired',
        retryable: false,
      ),
    );
    await _waitUntil(() => supervisor.status is Blocked);
    expect(supervisor.status, const Blocked(BlockReason.licenseExpired));

    supervisor.noteFreshToken();
    await _waitUntil(() => supervisor.status is Connected);
    expect(relay.dialedTokens, [
      'token-1',
      'token-2',
    ], reason: 'noteFreshToken must redial with a NEWLY minted token');
  });

  test(
    'a single SUPERSEDED reaches the supervisor without dead-ending the '
    'ladder — the app\'s own stale relay entry recovers on the next dial',
    () async {
      final mech = climbableMech();
      final supervisor = wireProduction(mech);
      await _waitUntil(() => supervisor.status is Connected);

      // The phone changed network. The relay still holds the old entry and
      // rejects the same-epoch redial (the app mints one epoch per launch), then
      // drops the stale entry on its own liveness sweep — after which the very
      // same epoch is admitted.
      relay.pushError(
        const ErrorMessage(
          code: 'SUPERSEDED',
          message: 'a newer or equal connection already holds this deviceId',
          retryable: false,
        ),
      );

      await _waitUntil(
        () => relay.dialedTokens.length == 2 && supervisor.status is Connected,
        reason: 'a stale relay-side entry must not be a sticky dead end',
      );
    },
  );

  test('a SUPERSEDED that keeps repeating blocks the ladder; presence flaps do '
      'NOT clear it; only retry() redials', () async {
    final mech = climbableMech();
    // A genuinely newer instance holds the id: every redial loses arbitration.
    relay.connectError = const ErrorMessage(
      code: 'SUPERSEDED',
      message: 'a newer or equal connection already holds this deviceId',
      retryable: false,
    );
    final supervisor = wire(
      mech,
      backoffBaseMs: 1,
      backoffCapMs: 2,
      jitter: (_) => 0,
    );

    await _waitUntil(() => supervisor.status is Blocked);
    expect(supervisor.status, const Blocked(BlockReason.superseded));
    expect(relay.dialedTokens, hasLength(kMaxSupersededRetries));

    relay.presence(false);
    relay.presence(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      supervisor.status,
      const Blocked(BlockReason.superseded),
      reason: 'presence must never clear a SUPERSEDED block',
    );

    relay.connectError = null;
    supervisor.retry();
    await _waitUntil(() => supervisor.status is Connected);
    expect(relay.dialedTokens, hasLength(kMaxSupersededRetries + 1));
  });

  test('a sealed session-takeover blocks sessionTakenOver; presence flaps do '
      'NOT clear it; only retry() re-establishes', () async {
    final mech = climbableMech();
    final supervisor = wireProduction(mech);
    await _waitUntil(() => supervisor.status is Connected);
    expect(mech.establishCalls, 1);

    mech.simulateTakeover();
    expect(supervisor.status, const Blocked(BlockReason.sessionTakenOver));

    // The hop that was missing in the field: blocking the ladder is only half
    // the job — the workspace has to state the reason. Both providers are
    // healthy at this point (the session established before the takeover), so
    // nothing throws and the supervisor's own verdict is the ONLY thing that
    // can reach the user. See workspace_blocking_error_test.dart.
    expect(
      workspaceBlockingError(
        transportError: null,
        sessionError: null,
        liveStatus: supervisor.status,
      ),
      isA<ConnectionBlockedException>().having(
        (e) => e.reason,
        'reason',
        BlockReason.sessionTakenOver,
      ),
      reason:
          'a takeover that stops at the supervisor leaves the user staring at '
          'a dead session with no explanation',
    );

    relay.presence(false);
    relay.presence(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      supervisor.status,
      const Blocked(BlockReason.sessionTakenOver),
      reason:
          'reclaiming on presence would make two devices evict each '
          'other forever',
    );

    supervisor.retry();
    await _waitUntil(() => supervisor.status is Connected);
    expect(
      mech.establishCalls,
      2,
      reason: 'retry() must actually re-run the established rung',
    );
  });

  test('6 consecutive handshake failures block handshakeFailing without '
      're-dialling the socket', () async {
    final mech = _EstablishAlwaysFails(
      relay: relay,
      crypto: CryptoService(),
      machineDeviceId: 'M',
      identity: _identity(),
      phoneDeviceId: 'phone-1',
      phoneEd25519Seed: List<int>.filled(32, 7),
      epoch: 1,
      resolveCoords: () async => const ConnCoords(
        relayUrl: 'ws://relay.test',
        agentEd25519PubB64: 'AGENT_PUB',
      ),
      mintToken: defaultMint,
    );
    final supervisor = wire(
      mech,
      backoffBaseMs: 1,
      backoffCapMs: 2,
      jitter: (_) => 0,
    );

    await _waitUntil(
      () => supervisor.status is Blocked,
      timeout: const Duration(seconds: 5),
    );
    expect(supervisor.status, const Blocked(BlockReason.handshakeFailing));
    expect(mech.establishCalls, 6);
    expect(
      relay.dialedTokens,
      hasLength(1),
      reason: 'a failing established rung must not re-dial the socket',
    );
  });
}
