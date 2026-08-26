// Resolution coverage for `_buildRelayTransportFor`: which source supplies a
// machine's dial coordinates, and when the provider declines the machine
// entirely and falls through to the local path.
//
// Task 9 replaced the pairing rendezvous with account trust, so the observable
// outcome moved from "autoOpen/reconnect was called" to "the socket was dialled
// at the resolved relayUrl". These tests were rewritten around that: the
// PairingService calls they used to count no longer exist on any path.
//
// NO widget tests — consistent with project feedback_ui_testing guidance.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/connection_identity.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records every dial. `connect()` authenticates instantly so the ladder can
/// climb past the socket rung without a real WebSocket.
class _FakeRelayService extends RelayService {
  _FakeRelayService() : super(crypto: CryptoService());

  final _states = StreamController<AppState>.broadcast();
  final dialedUrls = <String>[];

  /// Models a machine that is simply not at the address being dialled — the
  /// only way a stale endpoint ever announces itself.
  bool failDials = false;

  AppState _cur = const AppState();

  @override
  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();

  @override
  Stream<AppState> get stateStream => _states.stream;

  @override
  Stream<bool> get peerPresenceStream => const Stream.empty();

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
    dialedUrls.add(relayUrl);
    if (failDials) throw StateError('nothing is listening at $relayUrl');
    _cur = const AppState(connectionState: RelayConnectionState.authenticated);
    if (!_states.isClosed) _states.add(_cur);
  }

  @override
  void disconnect() {
    _cur = const AppState();
    if (!_states.isClosed) _states.add(_cur);
  }

  @override
  void dispose() {
    unawaited(_states.close());
  }

  @override
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    // no-op — no real relay in tests
  }
}

/// Hands every machine a connection whose socket is the fake above, so the
/// supervisor's dial never touches a real WebSocket.
class _FakeConnectionManager extends RelayConnectionManager {
  _FakeConnectionManager(this._relay) : super(crypto: CryptoService());

  final RelayService _relay;
  final Map<String, RelayConnection> _conns = {};

  @override
  RelayConnection connectionFor(String machineDeviceId) => _conns.putIfAbsent(
    machineDeviceId,
    () => RelayConnection(
      machineDeviceId: machineDeviceId,
      crypto: CryptoService(),
      relayOverride: _relay,
    ),
  );

  @override
  RelayConnection? peek(String machineDeviceId) => _conns[machineDeviceId];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _remoteUuid = 'remote-agent-uuid';
const _localUuid = 'local-device-uuid';
const _inventoryUrl = 'wss://inventory.example.com/ws';
const _recentUrl = 'wss://recent.example.com/ws';
const _movedUrl = 'wss://moved.example.com/ws';

InventoryAgent _inventoryAgent({String? relayUrl}) => InventoryAgent(
  deviceUuid: _remoteUuid,
  displayName: 'My Remote Agent',
  platform: 'linux',
  ed25519Pub: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  relayUrl: relayUrl ?? _inventoryUrl,
);

RecentAgent _makeRecentAgent(String agentDeviceId, String relayUrl) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: agentDeviceId,
    agentLabel: 'Test Agent',
    agentEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    relayUrl: relayUrl,
    pairedAt: now,
    lastConnectedAt: now,
  );
}

DeviceRecord _connectionRecord() => DeviceRecord(
  userId: 'u-1',
  deviceUuid: 'controller-uuid',
  clientId: 'cid',
  clientSecret: 'csec',
  ed25519Pub: base64Encode(List<int>.filled(32, 1)),
  ed25519Priv: base64Encode(List<int>.filled(32, 2)),
  x25519Pub: base64Encode(List<int>.filled(32, 3)),
  x25519Priv: base64Encode(List<int>.filled(32, 4)),
);


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('agentTransportForProvider — machine resolution', () {
    late _FakeRelayService relay;
    late TestStoreOverrides stores;

    setUp(() async {
      useInMemoryPrefs();
      stores = await buildTestStoreOverrides();
      relay = _FakeRelayService();
    });

    tearDown(() async {
      await stores.close();
    });

    List<Override> baseOverrides({
      List<InventoryAgent> inventory = const [],
      String? localUuid = _localUuid,
      _FakeRelayService? socket,
    }) {
      return [
        ...stores.overrides,
        // Override accountAgentsProvider directly (not the API layer) so the
        // cache is immediately populated. _buildRelayTransportFor uses
        // `.value` to avoid adding async latency for unresolved cases.
        accountAgentsProvider.overrideWith((_) async => inventory),
        localDeviceUuidProvider.overrideWith((_) async => localUuid),
        connectionDeviceRecordProvider.overrideWith(
          (_) async => _connectionRecord(),
        ),
        connectionTokenMinterProvider.overrideWith((_) async => null),
        cryptoServiceProvider.overrideWith((_) => CryptoService()),
        // The supervisor dials the socket itself, so the connection must hand
        // it a relay that authenticates without a real WebSocket.
        relayConnectionManagerProvider.overrideWithValue(
          _FakeConnectionManager(socket ?? relay),
        ),
      ];
    }

    Future<void> pumpUntilDial(ProviderContainer c) async {
      for (var i = 0; i < 200 && relay.dialedUrls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test(
      'an inventory hit with no RecentAgent is dialled at the inventory URL',
      () async {
        final container = ProviderContainer(
          overrides: baseOverrides(inventory: [_inventoryAgent()]),
        );
        addTearDown(container.dispose);
        await container.read(accountAgentsProvider.future);

        // The E2E handshake never completes against the fake relay, so the
        // transport future stays pending — poll the dial instead of awaiting.
        container.read(agentTransportForProvider(_remoteUuid));
        await pumpUntilDial(container);

        expect(relay.dialedUrls, [
          _inventoryUrl,
        ], reason: 'a first-time inventory hit is dialled from the inventory');
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a RecentAgent is dialled at the FRESH inventory URL, not its stale pin',
      () async {
        // _buildRelayTransportFor reads RecentAgentsStore.list() directly (not
        // the Riverpod notifier) so no stream-event delay is needed.
        await stores.recentAgentsStore.upsert(
          _makeRecentAgent(_remoteUuid, _recentUrl),
        );

        final container = ProviderContainer(
          overrides: baseOverrides(inventory: [_inventoryAgent()]),
        );
        addTearDown(container.dispose);
        await container.read(accountAgentsProvider.future);

        container.read(agentTransportForProvider(_remoteUuid));
        await pumpUntilDial(container);

        expect(
          relay.dialedUrls,
          [_inventoryUrl],
          reason:
              'freshness-first: a host that moved relay must not be dialled '
              'at the address pinned on the cached RecentAgent',
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a RecentAgent with no inventory row still dials its cached URL',
      () async {
        await stores.recentAgentsStore.upsert(
          _makeRecentAgent(_remoteUuid, _recentUrl),
        );

        final container = ProviderContainer(overrides: baseOverrides());
        addTearDown(container.dispose);
        await container.read(accountAgentsProvider.future);

        container.read(agentTransportForProvider(_remoteUuid));
        await pumpUntilDial(container);

        expect(relay.dialedUrls, [_recentUrl]);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'returns null when inventory is empty (falls through to local path)',
      () async {
        final container = ProviderContainer(
          overrides: baseOverrides(inventory: const []),
        );
        addTearDown(container.dispose);

        // No inventory hit → local path → no AbProject → null.
        final transport = await container
            .read(agentTransportForProvider('unknown-uuid').future)
            .timeout(const Duration(seconds: 5));

        expect(transport, isNull);
        expect(
          relay.dialedUrls,
          isEmpty,
          reason: 'a local project must never materialize a relay socket',
        );
      },
    );

    test('an inventory-only resolve persists a RecentAgent, so the machine '
        'still resolves once the inventory is gone', () async {
      final withInventory = ProviderContainer(
        overrides: baseOverrides(inventory: [_inventoryAgent()]),
      );
      await withInventory.read(accountAgentsProvider.future);

      withInventory.read(agentTransportForProvider(_remoteUuid));
      await pumpUntilDial(withInventory);
      expect(relay.dialedUrls, [_inventoryUrl]);

      // The write is fire-and-forget, so it lands a beat after the dial.
      for (var i = 0; i < 200 && stores.recentAgentsStore.list().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final rows = stores.recentAgentsStore.list();
      expect(
        rows,
        hasLength(1),
        reason:
            'the inventory path must feed the reconnect list — it is the '
            'only thing that renders the machine while /account/agents is '
            'unreachable',
      );
      final row = rows.first;
      expect(row.agentDeviceId, _remoteUuid);
      expect(row.relayUrl, _inventoryUrl);
      expect(
        row.agentEd25519Pubkey,
        _inventoryAgent().ed25519Pub,
        reason: 'the pubkey pin is the relay-independent reconnect anchor',
      );

      withInventory.dispose();

      // Cold start with the inventory unavailable: the cached row alone must
      // still resolve the machine. A fresh socket fake because the first
      // one's state is already authenticated, which the socket rung would
      // read as "nothing to dial".
      final coldSocket = _FakeRelayService();
      addTearDown(coldSocket.dispose);
      final offline = ProviderContainer(
        overrides: baseOverrides(inventory: const [], socket: coldSocket),
      );
      addTearDown(offline.dispose);
      await offline.read(accountAgentsProvider.future);

      offline.read(agentTransportForProvider(_remoteUuid));
      for (var i = 0; i < 200 && coldSocket.dialedUrls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(coldSocket.dialedUrls, [_inventoryUrl]);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a host that moved relay is re-dialled at its NEW address, without '
        'the machine being rebuilt', () async {
      // The stale-coords dead end: the supervisor caches the coords step's
      // answer and only re-runs it after repeated socket failures, so the
      // step itself has to re-read the account inventory at call time. A
      // closure over the values resolved at provider build hands it the same
      // dead endpoint forever, and the ladder sits on the socket cap with no
      // Blocked reason and an inert Retry.
      var inventory = <InventoryAgent>[_inventoryAgent()];
      relay.failDials = true;

      final container = ProviderContainer(
        overrides: [
          ...stores.overrides,
          accountAgentsProvider.overrideWith((_) async => inventory),
          localDeviceUuidProvider.overrideWith((_) async => _localUuid),
          connectionDeviceRecordProvider.overrideWith(
            (_) async => _connectionRecord(),
          ),
          connectionTokenMinterProvider.overrideWith((_) async => null),
          cryptoServiceProvider.overrideWith((_) => CryptoService()),
          relayConnectionManagerProvider.overrideWithValue(
            _FakeConnectionManager(relay),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountAgentsProvider.future);

      container.read(agentTransportForProvider(_remoteUuid));
      await pumpUntilDial(container);
      expect(relay.dialedUrls.first, _inventoryUrl);

      // The host came back behind a different relay and heartbeated it to the
      // account service. Nothing rebuilds the transport: this machine is held
      // warm and its connection is live. Dials keep failing throughout, so the
      // ONLY way the new address is ever reached is a re-resolve.
      inventory = <InventoryAgent>[_inventoryAgent(relayUrl: _movedUrl)];

      for (var i = 0; i < 2500 && !relay.dialedUrls.contains(_movedUrl); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        relay.dialedUrls,
        contains(_movedUrl),
        reason:
            'the coords step must re-read the inventory, not replay the '
            'answer it computed at provider build',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('an inventory agent that is THIS device is not dialled', () async {
      final container = ProviderContainer(
        overrides: baseOverrides(
          inventory: [_inventoryAgent()],
          localUuid: _remoteUuid,
        ),
      );
      addTearDown(container.dispose);
      await container.read(accountAgentsProvider.future);

      final transport = await container
          .read(agentTransportForProvider(_remoteUuid).future)
          .timeout(const Duration(seconds: 5));

      expect(transport, isNull);
      expect(relay.dialedUrls, isEmpty);
    });
  });
}
