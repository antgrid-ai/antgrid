import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/storage_service.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// Which ids read as relay-reached, and which machine the focus belongs to.
///
/// Both used to be an exact-id match against the paired-agent list, which
/// answers for neither shape that reaches them: a remote PROJECT is
/// `<machineUuid>.<projectId>` while every machine record is keyed by the bare
/// uuid, and the paired list is empty on any install that never QR-paired.
class _MemoryStorageService extends StorageService {
  _MemoryStorageService(this.agents);
  final List<PairedAgent> agents;
  @override
  Future<List<PairedAgent>> loadPairedAgents() async => List.of(agents);
}

const _machineUuid = 'machine-uuid';

RecentAgent _recent({String? machineName}) => RecentAgent(
  agentDeviceId: _machineUuid,
  agentLabel: 'work laptop',
  agentEd25519Pubkey: 'pub',
  relayUrl: 'ws://relay.test',
  pairedAt: DateTime.utc(2026, 1, 1),
  lastConnectedAt: DateTime.utc(2026, 1, 1),
  hostMachineName: machineName,
);

InventoryAgent _inventory() => InventoryAgent(
  deviceUuid: _machineUuid,
  displayName: 'me@example.com',
  platform: 'linux',
  ed25519Pub: 'pub',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> buildContainer({
    List<PairedAgent> paired = const [],
    List<RecentAgent> recent = const [],
    List<InventoryAgent> inventory = const [],
  }) async {
    useInMemoryPrefs();
    final recentStore = await RecentAgentsStore.open();
    for (final agent in recent) {
      await recentStore.upsert(agent);
    }
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(
          _MemoryStorageService(paired),
        ),
        recentAgentsStoreProvider.overrideWithValue(recentStore),
        accountAgentsProvider.overrideWith((_) async => inventory),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(recentStore.close);
    // Both lists are async-sourced; settle them before asking.
    await container.read(pairedAgentProvider.future);
    await container.read(accountAgentsProvider.future);
    return container;
  }

  group('entryIsRelayProvider', () {
    test('a remote project id resolves through its base machine uuid', () async {
      final container = await buildContainer(recent: [_recent()]);

      expect(
        container.read(entryIsRelayProvider('$_machineUuid.6e5c50e5d6f973a8')),
        isTrue,
      );
    });

    test('a machine known only from the account inventory is relay', () async {
      // The account-trust path: no QR, so no paired row and no cached recent
      // row until the first dial writes one.
      final container = await buildContainer(inventory: [_inventory()]);

      expect(container.read(entryIsRelayProvider(_machineUuid)), isTrue);
      expect(
        container.read(entryIsRelayProvider('$_machineUuid.6e5c50e5d6f973a8')),
        isTrue,
      );
    });

    test('a legacy QR pairing still resolves', () async {
      final container = await buildContainer(
        paired: [
          PairedAgent(
            relayUrl: 'ws://relay.test',
            agentDeviceId: '$_machineUuid.6e5c50e5d6f973a8',
            agentName: 'work laptop',
          ),
        ],
      );

      expect(
        container.read(entryIsRelayProvider('$_machineUuid.6e5c50e5d6f973a8')),
        isTrue,
      );
    });

    test('a local project id names no machine', () async {
      final container = await buildContainer(recent: [_recent()]);

      expect(container.read(entryIsRelayProvider('6e5c50e5d6f973a8')), isFalse);
    });

    test('the sample project is not relay', () async {
      // Its transport reports itself local — that is what keeps it out of the
      // relay bucket and its push registration.
      final container = await buildContainer(recent: [_recent()]);

      expect(container.read(entryIsRelayProvider(kDemoProjectId)), isFalse);
    });
  });

  group('activeAgentProvider', () {
    test('a remote project focus resolves to its machine', () async {
      final container = await buildContainer(
        recent: [_recent(machineName: 'build-server')],
      );
      container
          .read(selectedTargetProvider.notifier)
          .set(
            const RemoteProject(
              machineUuid: _machineUuid,
              projectId: '6e5c50e5d6f973a8',
            ),
          );

      expect(container.read(activeAgentProvider)?.agentName, 'build-server');
    });

    test('a machine with no host name falls back to its pairing label', () async {
      final container = await buildContainer(recent: [_recent()]);
      container
          .read(selectedTargetProvider.notifier)
          .set(const RemoteTarget.legacy(_machineUuid));

      expect(container.read(activeAgentProvider)?.agentName, 'work laptop');
    });

    test('an unknown focus resolves to no machine', () async {
      final container = await buildContainer();
      container
          .read(selectedTargetProvider.notifier)
          .set(const LocalProject('6e5c50e5d6f973a8'));

      expect(container.read(activeAgentProvider), isNull);
    });
  });
}
