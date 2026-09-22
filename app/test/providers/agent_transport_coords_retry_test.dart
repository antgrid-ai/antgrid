import '../helpers/test_license_token_minter.dart';
import '../helpers/test_peer_runtime.dart';
// The coords step must keep answering from the LIVE account inventory for as
// long as the ladder runs — including after a user Retry, which disposes and
// rebuilds the transport element while the connection it started keeps running.
//
// `retryAgentConnection()` calls `supervisor.retry()` and then
// `ref.invalidate(agentTransportForProvider(id))` without releasing the
// connection. The rebuilt element's freshly-built `PeerConnectionMechanisms` is
// discarded by `ensureStarted` (the supervisor already exists), so whatever
// owns the coords resolution has to outlive the element that first built it.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/peer_runtime.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/connection/connection_supervisor.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machine = 'machine-uuid';
const _agentPubB64 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _urlA = 'wss://relay-a.example/ws';
const _urlB = 'wss://relay-b.example/ws';

/// Every dial loses, so the socket rung never latches and the ladder keeps
/// asking the coords step where this machine lives — which is the behaviour
/// under test.
class _DialRecordingRelay extends RelayService {
  _DialRecordingRelay() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final _presence = StreamController<bool>.broadcast();
  final _errors = StreamController<ErrorMessage>.broadcast();
  final dialedUrls = <String>[];
  final AppState _cur = const AppState();

  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();
  @override
  Stream<AppState> get stateStream => _states.stream;
  @override
  Stream<bool> get peerPresenceStream => _presence.stream;
  @override
  Stream<ErrorMessage> get errorStream => _errors.stream;
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
    dialedUrls.add(relayUrl);
    throw RelayConnectException(
      code: 'NATIVE_CONNECT_FAILED',
      retryable: true,
      message: 'nothing listening',
    );
  }

  @override
  void disconnect() {}

  Future<PeerSendOutcome> sendFrame(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) async {
    sendMessage(to, channel, payload, kind: kind);
    return PeerSendOutcome.accepted;
  }

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
    if (!_errors.isClosed) await _errors.close();
  }
}

class _FakeConnectionManager extends MachineConnectionManager {
  _FakeConnectionManager(this._relay) : super(crypto: CryptoService());

  final RelayService _relay;
  final Map<String, MachineConnection> _conns = {};

  @override
  MachineConnection connectionFor(String machineDeviceId) => _conns.putIfAbsent(
    machineDeviceId,
    () => MachineConnection(
      machineDeviceId: machineDeviceId,
      crypto: CryptoService(),
      relayOverride: _relay,
    ),
  );

  @override
  MachineConnection? peek(String machineDeviceId) => _conns[machineDeviceId];
}

Future<DeviceRecord> _connectionRecord() async {
  final seed = List<int>.generate(32, (i) => (i * 5 + 1) % 256);
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  return DeviceRecord(
    userId: 'u-1',
    deviceUuid: 'controller-device-uuid',
    clientId: 'cid',
    clientSecret: 'csec',
    ed25519Pub: base64Encode(pub.bytes),
    ed25519Priv: base64Encode(seed),
    x25519Pub: base64Encode(List<int>.filled(32, 5)),
    x25519Priv: base64Encode(List<int>.filled(32, 6)),
  );
}

RecentAgent _recent(String id, String relayUrl) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: id,
    agentLabel: id,
    agentEd25519Pubkey: _agentPubB64,
    relayUrl: relayUrl,
    pairedAt: now,
    lastConnectedAt: now,
  );
}

InventoryAgent _inventory(String id, String relayUrl) => InventoryAgent(
  deviceUuid: id,
  displayName: 'Remote',
  platform: 'linux',
  ed25519Pub: _agentPubB64,
  relayUrl: relayUrl,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;
  late _DialRecordingRelay relay;
  late DeviceRecord record;
  late List<InventoryAgent> inventory;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
    relay = _DialRecordingRelay();
    record = await _connectionRecord();
    inventory = [_inventory(_machine, _urlA)];
  });

  tearDown(() async {
    await relay.closeStreams();
    await stores.close();
  });

  Future<void> waitFor(
    bool Function() until, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!until() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'initial coordinates await loading inventory before using a cached key',
    () async {
      await stores.recentAgentsStore.upsert(_recent(_machine, _urlA));
      final pending = Completer<List<InventoryAgent>>();
      final c = ProviderContainer(
        overrides: [
          ...stores.overrides,
          accountAgentsProvider.overrideWith((_) => pending.future),
        ],
      );
      addTearDown(c.dispose);
      var resolved = false;
      final result = c
          .read(connectionCoordsResolverProvider)
          .resolve(
            base: _machine,
            refreshInventory: false,
            fallback: const ConnCoords(
              relayUrl: _urlA,
              agentEd25519PubB64: _agentPubB64,
            ),
          )
          .then((value) {
            resolved = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);
      pending.complete([
        InventoryAgent(
          deviceUuid: _machine,
          displayName: 'Remote',
          platform: 'linux',
          ed25519Pub: 'fresh-key',
          relayUrl: _urlB,
        ),
      ]);
      final coords = await result;
      expect(coords.agentEd25519PubB64, 'fresh-key');
      expect(coords.relayUrl, _urlB);
    },
  );

  test('a Retry that disposes the transport element must not freeze the coords '
      'step on its build-time endpoint', () async {
    await stores.recentAgentsStore.upsert(_recent(_machine, _urlA));
    final c = ProviderContainer(
      overrides: [
        ...stores.overrides,
        // These fixtures isolate coordinates and E2E identity from HTTP enrollment.
        peerRuntimeProvider.overrideWith((ref) async {
          final runtime = TestPeerRuntime();
          ref.onDispose(runtime.dispose);
          return runtime;
        }),
        accountAgentsProvider.overrideWith((_) async => inventory),
        localDeviceUuidProvider.overrideWith((_) async => 'this-device'),
        connectionDeviceRecordProvider.overrideWith((_) async => record),
        connectionTokenMinterProvider.overrideWith(
          (_) async => TestLicenseTokenMinter(),
        ),
        cryptoServiceProvider.overrideWith((_) => CryptoService()),
        relayConnectionManagerProvider.overrideWithValue(
          _FakeConnectionManager(relay),
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(accountAgentsProvider.future);

    // A live listener, as the workspace shell has: the invalidate below then
    // disposes AND rebuilds the element, exactly as it does in the app.
    c.listen(agentTransportForProvider(_machine), (_, _) {});
    await waitFor(() => relay.dialedUrls.isNotEmpty);
    expect(relay.dialedUrls.first, _urlA, reason: 'first dial uses the cache');

    // Exactly what `retryAgentConnection()` does: hand the supervisor its retry
    // input, then invalidate the family entry — never releasing the connection.
    void retryLikeProduction() {
      c
          .read(relayConnectionManagerProvider)
          .peek(_machine)
          ?.supervisor
          ?.retry();
      c.invalidate(agentTransportForProvider(_machine));
    }

    retryLikeProduction();
    // Let the rebuild land, so the element that built the live mechanisms is
    // gone by the time the next coords resolution runs.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // The host moved relay; /account/agents already says so.
    inventory = [_inventory(_machine, _urlB)];

    final dialsBefore = relay.dialedUrls.length;
    retryLikeProduction();
    await waitFor(
      () =>
          relay.dialedUrls.length > dialsBefore &&
          relay.dialedUrls.last == _urlB,
    );

    expect(
      relay.dialedUrls.last,
      _urlB,
      reason:
          'coords must still resolve against the live inventory after the '
          'element that built the mechanisms was disposed by a Retry',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
