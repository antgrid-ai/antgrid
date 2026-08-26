import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// Which ids read as relay-reached, and which machine the focus belongs to.
///
/// Both used to be an exact-id match, which answers for neither shape that
/// reaches them: a remote PROJECT is `<machineUuid>.<projectId>` while every
/// machine record is keyed by the bare uuid.
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

InventoryAgent _inventory({String? relayUrl = 'ws://relay.test'}) =>
    InventoryAgent(
      deviceUuid: _machineUuid,
      displayName: 'me@example.com',
      platform: 'linux',
      ed25519Pub: 'pub',
      relayUrl: relayUrl,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> buildContainer({
    List<RecentAgent> recent = const [],
    List<InventoryAgent> inventory = const [],
    String? localUuid = 'this-device',
  }) async {
    useInMemoryPrefs();
    final recentStore = await RecentAgentsStore.open();
    for (final agent in recent) {
      await recentStore.upsert(agent);
    }
    final container = ProviderContainer(
      overrides: [
        recentAgentsStoreProvider.overrideWithValue(recentStore),
        accountAgentsProvider.overrideWith((_) async => inventory),
        // Never the real one: it reads (and mints) the host identity out of the
        // keychain.
        localDeviceUuidProvider.overrideWith((_) async => localUuid),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(recentStore.close);
    // Both are async-sourced; settle them before asking.
    await container.read(accountAgentsProvider.future);
    await container.read(localDeviceUuidProvider.future);
    return container;
  }

  group('entryIsRelayProvider', () {
    test(
      'a remote project id resolves through its base machine uuid',
      () async {
        final container = await buildContainer(recent: [_recent()]);

        expect(
          container.read(
            entryIsRelayProvider('$_machineUuid.6e5c50e5d6f973a8'),
          ),
          isTrue,
        );
      },
    );

    test('a machine known only from the account inventory is relay', () async {
      // The account-trust path: nothing is cached until the first dial writes
      // its reconnect row.
      final container = await buildContainer(inventory: [_inventory()]);

      expect(container.read(entryIsRelayProvider(_machineUuid)), isTrue);
      expect(
        container.read(entryIsRelayProvider('$_machineUuid.6e5c50e5d6f973a8')),
        isTrue,
      );
    });

    test('a machine that has not enabled remote access is not relay', () async {
      // No relayUrl is a host with nothing to dial: `_buildRelayTransportFor`
      // falls through to its local arm, and this must not disagree with what is
      // actually opened.
      final container = await buildContainer(
        inventory: [_inventory(relayUrl: null)],
      );

      expect(container.read(entryIsRelayProvider(_machineUuid)), isFalse);
    });

    test('this device is not relay to itself', () async {
      // Every machine appears in its OWN account inventory, and the transport
      // refuses to dial itself.
      final container = await buildContainer(
        inventory: [_inventory()],
        localUuid: _machineUuid,
      );

      expect(container.read(entryIsRelayProvider(_machineUuid)), isFalse);
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

  group('focusedMachineNameProvider', () {
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

      expect(container.read(focusedMachineNameProvider), 'build-server');
    });

    test(
      'a machine with no host name falls back to its stored label',
      () async {
        final container = await buildContainer(recent: [_recent()]);
        container
            .read(selectedTargetProvider.notifier)
            .set(const RemoteTarget.legacy(_machineUuid));

        expect(container.read(focusedMachineNameProvider), 'work laptop');
      },
    );

    test('the first connect names the machine from the inventory', () async {
      // The reconnect row is upserted fire-and-forget DURING the dial this
      // screen is waiting on, so the inventory is the only source that can
      // answer while it renders.
      final container = await buildContainer(inventory: [_inventory()]);
      container
          .read(selectedTargetProvider.notifier)
          .set(const RemoteTarget.legacy(_machineUuid));

      expect(container.read(focusedMachineNameProvider), 'me@example.com');
    });

    test('an unknown focus resolves to no machine', () async {
      final container = await buildContainer();
      container
          .read(selectedTargetProvider.notifier)
          .set(const LocalProject('6e5c50e5d6f973a8'));

      expect(container.read(focusedMachineNameProvider), isNull);
    });
  });
}
