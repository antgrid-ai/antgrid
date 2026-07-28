// The production wiring of Task 7's ConnectionSupervisor: `RelayConnection`
// hands the supervisor a `RelayMechanisms` adapter and the supervisor becomes
// the ONE thing that decides when to dial. These tests pin the two properties
// the old memoized `open()` + RelayService-owned reconnect loop could not
// give: recovery is level-triggered (a dropped socket re-dials with no caller
// involved) and every dial presents a FRESHLY minted token.
import 'dart:async';
import 'dart:typed_data';

import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/connection/relay_mechanisms.dart';
import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/license_token_minter.dart';
import 'package:antgrid/services/storage_service.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A RelayService whose socket is scripted: `connect()` records the token it
/// was handed and drives the state machine the way a real welcome would.
class _ScriptedRelay extends RelayService {
  _ScriptedRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _messages = StreamController<IncomingRouteMessage>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();

  final List<String> dialedTokens = <String>[];
  int disconnectCalls = 0;

  /// When set, `connect()` fails instead of authenticating.
  Object? connectError;

  /// Whether a successful `connect()` also announces the agent as present.
  /// The real relay does this right after `welcome` for a same-account peer;
  /// leaving it false models an agent that simply is not running.
  bool announcePeer = true;

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

  // Guarded: a connection disposed at teardown releases its socket
  // asynchronously, which can land after closeStreams().
  void push(AppState s) {
    _cur = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _presenceAdd(bool online) {
    if (!_presence.isClosed) _presence.add(online);
  }

  /// A `peer-online`/`peer-offline` arriving on its own, decoupled from a dial.
  void announce(bool online) => _presenceAdd(online);

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
      push(const AppState());
      throw err;
    }
    push(const AppState(connectionState: RelayConnectionState.authenticated));
    if (announcePeer) _presenceAdd(true);
  }

  @override
  void disconnect() {
    disconnectCalls++;
    push(const AppState());
    _presenceAdd(false);
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

/// The E2E handshake needs a live agent, which no fake relay can produce, so
/// the established rung would never be satisfied here. Stubbing exactly that
/// rung is what lets a test drive the ladder all the way to [Connected].
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

  /// The shape a failed rekey leaves behind: the E2E session is gone while the
  /// relay socket underneath it is still authenticated.
  void killSession() => _established = false;

  @override
  Future<void> establishSession() async {
    establishCalls++;
    _established = true;
  }

  @override
  bool get sessionEstablished => _established;
}

/// `retryAgentConnection` reaches the supervisor through `peek()`; pinning one
/// connection here is what lets the provider test drive a real, really-blocked
/// supervisor without a relay.
class _FixedManager extends RelayConnectionManager {
  _FixedManager(this.conn) : super(crypto: CryptoService());

  final RelayConnection conn;

  @override
  RelayConnection? peek(String machineDeviceId) => conn;

  @override
  RelayConnection connectionFor(String machineDeviceId) => conn;
}

class _MemoryStorageService extends StorageService {
  _MemoryStorageService(this.agents);

  List<PairedAgent> agents;

  @override
  Future<List<PairedAgent>> loadPairedAgents() async => List.of(agents);

  @override
  Future<void> savePairedAgents(List<PairedAgent> agents) async {
    this.agents = List.of(agents);
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
  TestWidgetsFlutterBinding.ensureInitialized();

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

  RelayMechanisms mechanisms({Future<String> Function()? mintToken}) =>
      RelayMechanisms(
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
        mintToken: mintToken ?? defaultMint,
      );

  /// Same wiring, but the ladder can actually reach [Connected].
  _EstablishStubbed climbable() => _EstablishStubbed(
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

  RelayConnection connection() {
    final conn = RelayConnection(
      machineDeviceId: 'M',
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);
    return conn;
  }

  test('a dropped socket is re-dialled by the supervisor with a NEWLY minted '
      'token — no caller re-invokes anything', () async {
    final conn = connection();
    conn.ensureStarted(mechanisms: mechanisms());

    await _waitUntil(() => relay.dialedTokens.length == 1);
    expect(relay.dialedTokens, <String>['token-1']);

    // The socket dies with nothing else happening in the app. The only
    // input is the relay's own state stream.
    relay.push(const AppState());

    await _waitUntil(
      () => relay.dialedTokens.length == 2,
      reason: 'the supervisor must re-dial a dead socket on its own',
    );
    expect(
      relay.dialedTokens,
      <String>['token-1', 'token-2'],
      reason: 'a cached token outlives its TTL across a long backoff',
    );
    expect(mintCalls, 2);
  });

  test('the E2E session is created once and survives a re-dial', () async {
    final conn = connection();
    conn.ensureStarted(mechanisms: mechanisms());

    await _waitUntil(() => conn.session != null);
    final session = conn.session;

    relay.push(const AppState());
    await _waitUntil(() => relay.dialedTokens.length == 2);

    expect(
      conn.session,
      same(session),
      reason: 'redialling must not orphan the bound project StreamTransports',
    );
  });

  test('ensureStarted constructs the supervisor exactly once', () async {
    final conn = connection();
    conn.ensureStarted(mechanisms: mechanisms());
    final first = conn.supervisor;
    conn.ensureStarted(mechanisms: mechanisms());

    expect(conn.supervisor, same(first));
  });

  test('dispose() releases the socket instead of orphaning it', () async {
    final conn = RelayConnection(
      machineDeviceId: 'M',
      crypto: CryptoService(),
      relayOverride: relay,
    );
    conn.ensureStarted(mechanisms: mechanisms());
    await _waitUntil(() => relay.dialedTokens.length == 1);

    conn.dispose();

    // An orphaned socket keeps counting against the relay's sessionLimit, so
    // dispose must go through the mechanisms' release, not just drop the
    // supervisor (which deliberately does not release).
    await _waitUntil(
      () => relay.disconnectCalls >= 1,
      reason: 'dispose must release the authenticated socket',
    );
    expect(conn.session, isNull);
  });

  test(
    'a dial that never authenticates backs off instead of hot-looping',
    () async {
      relay.connectError = StateError('relay refused');
      final conn = connection();
      conn.ensureStarted(mechanisms: mechanisms());

      await _waitUntil(() => relay.dialedTokens.isNotEmpty);
      final afterFirst = relay.dialedTokens.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        relay.dialedTokens.length,
        afterFirst,
        reason: 'the socket rung backoff (base 1s) must pace the retry',
      );
      expect(conn.supervisor!.status, isA<Climbing>());
    },
  );

  // ------------------------------------------------------------------ I1
  test('an E2E session that dies under a live socket is re-established — the '
      'ladder is told, not left reading a torn-down session as healthy', () async {
    final conn = connection();
    final mech = climbable();
    conn.ensureStarted(mechanisms: mech);
    await _waitUntil(() => conn.supervisor!.status is Connected);
    expect(mech.establishCalls, 1);

    // A rekey the agent never confirmed: MachineSession tears the session down
    // and reports it. No socket event fires — the relay socket is fine.
    mech.killSession();
    mech.onSessionDown!();

    await _waitUntil(
      () => mech.establishCalls == 2 && conn.supervisor!.status is Connected,
      reason:
          'without a session-down input nothing re-drives the established '
          'rung and the UI shows a healthy machine over a dead session',
    );
    expect(
      relay.dialedTokens,
      hasLength(1),
      reason: 'the socket never died — only the session above it',
    );
  });

  // ------------------------------------------------------------------ M1
  test('an agent that comes back climbs immediately instead of paying a '
      'routable stall', () async {
    // No peer-online from connect(): the agent shows up later, on its own.
    relay.announcePeer = false;
    final conn = connection();
    final mech = climbable();
    conn.ensureStarted(mechanisms: mech);
    await _waitUntil(() => relay.dialedTokens.length == 1);

    relay.announce(true);

    // Well inside the 2s routable stall: if the supervisor reads the presence
    // level one microtask stale it sees `agentOnline == false`, stalls, and
    // only the stall timer gets it moving again.
    await _waitUntil(
      () => conn.supervisor!.status is Connected,
      timeout: const Duration(milliseconds: 400),
      reason:
          'a peer-online must climb the routable rung on the spot, not after '
          'a full routableStallMs',
    );
    expect(mech.establishCalls, 1);
  });

  // ------------------------------------------------------------------ C1
  test('a Blocked connection is not recoverable by rebuilding the transport — '
      'only retry() gets out of it', () async {
    final conn = connection();
    conn.ensureStarted(mechanisms: climbable());
    await _waitUntil(() => conn.supervisor!.status is Connected);

    conn.supervisor!.noteRelayError('LICENSE_REVOKED', retryable: false);
    await _waitUntil(() => conn.supervisor!.status is Blocked);

    // What `ref.invalidate(agentTransportForProvider(...))` does on its own:
    // ensureStarted no-ops on the live supervisor and awaitSession re-reads
    // the status the stream replays to every new listener — still Blocked.
    final supervisor = conn.supervisor;
    conn.ensureStarted(mechanisms: climbable());
    expect(conn.supervisor, same(supervisor));
    await expectLater(
      conn.awaitSession(timeout: const Duration(seconds: 2)),
      throwsA(isA<ConnectionBlockedException>()),
      reason: 'a rebuild alone must not be able to clear a block',
    );

    conn.supervisor!.retry();
    final session = await conn.awaitSession(
      timeout: const Duration(seconds: 5),
    );
    expect(session, isNotNull);
    expect(conn.supervisor!.status, const Connected());
  });

  test(
    'retryAgentConnection() clears the block AND rebuilds the transport that '
    'is holding the ConnectionBlockedException',
    () async {
      final conn = connection();
      conn.ensureStarted(mechanisms: climbable());
      await _waitUntil(() => conn.supervisor!.status is Connected);
      conn.supervisor!.noteRelayError('LICENSE_REVOKED', retryable: false);
      await _waitUntil(() => conn.supervisor!.status is Blocked);

      var builds = 0;
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(
            _MemoryStorageService(<PairedAgent>[
              PairedAgent(
                relayUrl: 'ws://relay.test',
                agentDeviceId: 'M',
                agentName: 'M',
              ),
            ]),
          ),
          relayConnectionManagerProvider.overrideWithValue(_FixedManager(conn)),
          agentTransportForProvider.overrideWith((ref, id) async {
            builds++;
            return null;
          }),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(selectedTargetProvider.notifier)
          .set(const RemoteTarget.legacy('M'));
      await container.read(pairedAgentProvider.future);
      await container.read(agentTransportForProvider('M').future);
      expect(builds, 1);

      await container.read(pairedAgentProvider.notifier).retryAgentConnection();

      expect(conn.supervisor!.status, isNot(isA<Blocked>()));
      await container.read(agentTransportForProvider('M').future);
      expect(
        builds,
        2,
        reason:
            'without the invalidate the error screen keeps rendering the '
            'settled ConnectionBlockedException forever',
      );
    },
  );

  test('retryAgentConnection() reaches the machine supervisor for a COMPOUND '
      'remote project id', () async {
    final conn = connection();
    conn.ensureStarted(mechanisms: climbable());
    await _waitUntil(() => conn.supervisor!.status is Connected);
    // SUPERSEDED is retried against the relay's own sweep window first, so the
    // block only lands once the whole budget is spent.
    for (var i = 0; i < kMaxSupersededRetries; i++) {
      conn.supervisor!.noteRelayError('SUPERSEDED', retryable: false);
    }
    await _waitUntil(() => conn.supervisor!.status is Blocked);

    var builds = 0;
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(
          _MemoryStorageService(const <PairedAgent>[]),
        ),
        relayConnectionManagerProvider.overrideWithValue(_FixedManager(conn)),
        agentTransportForProvider.overrideWith((ref, id) async {
          builds++;
          return null;
        }),
      ],
    );
    addTearDown(container.dispose);

    // A remote PROJECT focus is `<machineUuid>.<projectId>` and never matches
    // a PairedAgent row keyed by the bare machine uuid, so resolving the
    // retry target off the paired list drops this case entirely.
    container
        .read(selectedTargetProvider.notifier)
        .set(const RemoteProject(machineUuid: 'M', projectId: 'p'));
    await container.read(pairedAgentProvider.future);
    await container.read(agentTransportForProvider('M.p').future);

    await container.read(pairedAgentProvider.notifier).retryAgentConnection();

    expect(conn.supervisor!.status, isNot(isA<Blocked>()));
    await container.read(agentTransportForProvider('M.p').future);
    expect(builds, 2);
  });

  // ------------------------------------------------------------------ I2
  test('a revoked device surfaces as Blocked(deviceRevoked), not an endless '
      'socket backoff', () async {
    final conn = connection();
    conn.ensureStarted(
      mechanisms: mechanisms(
        mintToken: () async => throw const DeviceRevokedException(),
      ),
    );

    await _waitUntil(
      () => conn.supervisor!.status is Blocked,
      reason:
          'a mint rejected as revoked is a verdict, not a transient socket '
          'failure the ladder can retry away',
    );
    expect(conn.supervisor!.status, const Blocked(BlockReason.deviceRevoked));
    expect(relay.dialedTokens, isEmpty);
  });

  // ------------------------------------------------------------------ I3
  test('an agent that never announces presence keeps the socket and reaches '
      'Blocked(agentOffline)', () async {
    // The socket authenticates fine; the machine on the other end is simply
    // not running, so no peer-online ever arrives.
    relay.announcePeer = false;
    final conn = connection();
    conn.ensureStarted(mechanisms: mechanisms());

    // Three routable stalls at the 2s default is the real production timing.
    await _waitUntil(
      () => conn.supervisor!.status is Blocked,
      timeout: const Duration(seconds: 20),
      reason: 'the ladder must fall through to the routable rung and stall',
    );
    expect(conn.supervisor!.status, const Blocked(BlockReason.agentOffline));
    expect(
      relay.disconnectCalls,
      0,
      reason:
          'the socket is up and only the PEER is missing — tearing it down '
          'would charge the socket backoff for an offline agent',
    );
    expect(
      relay.dialedTokens,
      hasLength(1),
      reason: 'a stalled routable rung must not re-dial the socket',
    );
  });
}
