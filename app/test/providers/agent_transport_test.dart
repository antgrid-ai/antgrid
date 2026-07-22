// Tests for the lazy auto-pair safety net in _buildRelayTransportFor
// (Task 13). The provider must call PairingService.autoOpen when it sees an
// inventory hit for a projectId that has no RecentAgent yet, and must call
// PairingService.reconnect when a RecentAgent already exists.
//
// NO widget tests — consistent with project feedback_ui_testing guidance.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/pairing_service.dart';
import 'package:antgrid/services/phone_identity.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Tracks calls to autoOpen / reconnect. Extends PairingService but overrides
/// the two methods under test; real network I/O is never reached.
class _FakePairingService extends PairingService {
  int autoOpenCalls = 0;
  int reconnectCalls = 0;

  _FakePairingService(
    RelayService relay,
    PhoneIdentity phoneIdentity,
    RecentAgentsStore recentAgentsStore,
  ) : super(
        relay: relay,
        phoneIdentity: phoneIdentity,
        recentAgentsStore: recentAgentsStore,
        registrationId: 'test-registration',
        random: Random(0),
      );

  @override
  Future<RecentAgent> autoOpen(
    InventoryAgent agent,
    DeviceIdentity identity,
  ) async {
    autoOpenCalls++;
    return _makeRecentAgent(
      agent.deviceUuid,
      agent.relayUrl ?? 'wss://relay.example.com/ws',
    );
  }

  @override
  Future<RecentAgent> reconnect(RecentAgent ra, DeviceIdentity identity) async {
    reconnectCalls++;
    return ra.copyWith(lastConnectedAt: DateTime.now());
  }
}

/// A [RelayService] subclass whose messageStream is always empty and whose
/// sendMessage is a no-op. RelayTransport.connect() sends a state.snapshot
/// request that times out as an RpcException — which is caught inside
/// connect() and falls through, so the transport still returns successfully.
class _FakeRelayService extends RelayService {
  _FakeRelayService() : super(crypto: CryptoService());

  @override
  Stream<IncomingRouteMessage> get messageStream => const Stream.empty();

  @override
  Stream<AppState> get stateStream => const Stream.empty();

  @override
  AppState get currentState => const AppState();

  @override
  void sendMessage(
    String to,
    String channel,
    Uint8List payload, {
    FrameKind kind = FrameKind.sealed,
  }) {
    // no-op — no real relay in tests
  }

  @override
  Stream<PairApprovalMessage> get pairApprovalStream => const Stream.empty();

  @override
  Stream<PairRejectedMessage> get pairRejectedStream => const Stream.empty();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _remoteUuid = 'remote-agent-uuid';
const _localUuid = 'local-device-uuid';

InventoryAgent _inventoryAgent({String? relayUrl}) => InventoryAgent(
  deviceUuid: _remoteUuid,
  displayName: 'My Remote Agent',
  platform: 'linux',
  ed25519Pub: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  relayUrl: relayUrl ?? 'wss://relay.example.com/ws',
);

RecentAgent _makeRecentAgent(String agentDeviceId, String relayUrl) {
  final now = DateTime.now();
  return RecentAgent(
    agentDeviceId: agentDeviceId,
    agentLabel: 'Test Agent',
    agentEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    relayUrl: relayUrl,
    phoneDeviceId: 'phone-device-id',
    phoneEd25519Pubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    pairedAt: now,
    lastConnectedAt: now,
  );
}

// ---------------------------------------------------------------------------
// AsyncNotifier stubs
// ---------------------------------------------------------------------------

class _EmptyPairedAgentNotifier extends PairedAgentNotifier {
  @override
  Future<List<PairedAgent>> build() async => const [];
}

class _StubDeviceIdentityNotifier extends DeviceIdentityNotifier {
  @override
  Future<DeviceIdentity> build() async {
    return DeviceIdentity(
      deviceId: 'phone-device-id',
      name: 'Test Phone',
      ed25519PrivateKey: Uint8List(64),
      ed25519PublicKey: Uint8List(32),
      x25519PrivateKey: Uint8List(32),
      x25519PublicKey: Uint8List(32),
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('agentTransportForProvider — inventory-hit safety net', () {
    late _FakePairingService fakePairing;
    late PhoneIdentity phoneIdentity;
    late TestStoreOverrides stores;

    setUp(() async {
      useInMemoryPrefs();
      stores = await buildTestStoreOverrides();
      final relay = _FakeRelayService();
      phoneIdentity = PhoneIdentity.inMemory();
      fakePairing = _FakePairingService(
        relay,
        phoneIdentity,
        stores.recentAgentsStore,
      );
    });

    tearDown(() async {
      await stores.close();
    });

    List<Override> baseOverrides({
      List<InventoryAgent> inventory = const [],
      String? localUuid = _localUuid,
    }) {
      return [
        ...stores.overrides,
        // Simulate no pre-existing PairedAgents (the race condition).
        pairedAgentProvider.overrideWith(() => _EmptyPairedAgentNotifier()),
        // Override accountAgentsProvider directly (not the API layer) so the
        // cache is immediately populated. _buildRelayTransportFor uses
        // `.value` to avoid adding async latency for unresolved cases.
        accountAgentsProvider.overrideWith((_) async => inventory),
        localDeviceUuidProvider.overrideWith((_) async => localUuid),
        deviceIdentityProvider.overrideWith(
          () => _StubDeviceIdentityNotifier(),
        ),
        // Per-id routing: _buildRelayTransportFor reads the PairingService from
        // the family keyed by the projectId, not the deprecated shared shim.
        pairingServiceForProvider(_remoteUuid).overrideWithValue(fakePairing),
        // New routing path derives the per-connection handshake seed via
        // phoneIdentity.ensureKeypair; the real secure-storage impl throws
        // without plugins, so inject the in-memory identity.
        phoneIdentityProvider.overrideWithValue(phoneIdentity),
        cryptoServiceProvider.overrideWith((_) => CryptoService()),
      ];
    }

    test(
      'calls autoOpen once when inventory has a hit but no RecentAgent exists',
      () async {
        final container = ProviderContainer(
          overrides: baseOverrides(inventory: [_inventoryAgent()]),
        );
        addTearDown(container.dispose);

        // Pre-warm accountAgentsProvider so its cached value is available
        // synchronously when _buildRelayTransportFor reads .value.
        await container.read(accountAgentsProvider.future);

        // Per-id routing: open() runs the PairFlow (here autoOpen) then a v2
        // handshake that never completes against the fake relay, so the
        // transport future stays pending. We only assert the flow fired — poll
        // the call counter rather than awaiting the full open().
        container.read(agentTransportForProvider(_remoteUuid));
        for (var i = 0; i < 100 && fakePairing.autoOpenCalls == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(
          fakePairing.autoOpenCalls,
          1,
          reason: 'autoOpen must be called for a first-time inventory hit',
        );
        expect(fakePairing.reconnectCalls, 0);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'calls reconnect once when a RecentAgent already exists',
      () async {
        // Pre-populate the store so the store's list() is non-empty.
        // _buildRelayTransportFor reads RecentAgentsStore.list() directly
        // (not the Riverpod notifier) so no stream-event delay is needed.
        final existing = _makeRecentAgent(
          _remoteUuid,
          'wss://relay.example.com/ws',
        );
        await stores.recentAgentsStore.upsert(existing);

        final container = ProviderContainer(
          overrides: baseOverrides(inventory: [_inventoryAgent()]),
        );
        addTearDown(container.dispose);

        // See the autoOpen test: open()'s handshake never settles on the fake
        // relay, so poll the reconnect counter instead of awaiting the future.
        container.read(agentTransportForProvider(_remoteUuid));
        for (var i = 0; i < 100 && fakePairing.reconnectCalls == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(
          fakePairing.reconnectCalls,
          1,
          reason: 'reconnect must be called when a RecentAgent exists',
        );
        expect(fakePairing.autoOpenCalls, 0);
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
        expect(fakePairing.autoOpenCalls, 0);
        expect(fakePairing.reconnectCalls, 0);
      },
    );
  });
}
