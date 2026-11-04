import 'package:antgrid/models/drawer_entry.dart';
import 'package:antgrid/models/project_catalog.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/machine_scope.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/machine_scope_store.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

MachineInfo machine(String id, {bool online = true}) =>
    MachineInfo(id: id, name: id, isLocal: false, online: online);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => useInMemoryPrefs());

  group('MachineScope', () {
    test('online machines are in by default, offline ones out', () {
      const scope = MachineScope();
      expect(scope.includes('a', online: true), isTrue);
      expect(scope.includes('b', online: false), isFalse);
    });

    test('an unchecked online machine stays out; a checked offline one is in', () {
      final scope = const MachineScope()
          .toggled('a', online: true)
          .toggled('b', online: false);
      expect(scope.includes('a', online: true), isFalse);
      expect(scope.includes('b', online: false), isTrue);
      // Coming back online does not undo an explicit uncheck.
      expect(scope.isChecked('a', online: true), isFalse);
    });

    test('hide offline drops even a picked offline machine, and restores it when turned off', () {
      final picked = const MachineScope().toggled('b', online: false);
      final hidden = picked.withHideOffline(true);
      expect(hidden.includes('b', online: false), isFalse);
      expect(hidden.isChecked('b', online: false), isTrue);
      expect(hidden.withHideOffline(false).includes('b', online: false), isTrue);
    });

    test('select all checks every machine, offline ones included', () {
      final scope = const MachineScope()
          .toggled('a', online: true)
          .withHideOffline(true)
          .selectAll(['a', 'b']);
      expect(scope.includes('a', online: true), isTrue);
      expect(scope.includes('b', online: false), isTrue);
      expect(scope.hideOffline, isFalse);
    });
  });

  group('machineScopeProvider', () {
    test('persists choices across containers', () async {
      final store = await MachineScopeStore.open();
      final first = ProviderContainer(
        overrides: [machineScopeStoreProvider.overrideWithValue(store)],
      );
      first.read(machineScopeProvider.notifier)
        ..toggle('a', online: true)
        ..setHideOffline(true);
      first.dispose();
      // Let the detached write land.
      await Future<void>.delayed(Duration.zero);

      final second = ProviderContainer(
        overrides: [
          machineScopeStoreProvider.overrideWithValue(
            await MachineScopeStore.open(),
          ),
        ],
      );
      addTearDown(second.dispose);
      final scope = second.read(machineScopeProvider);
      expect(scope.excluded, {'a'});
      expect(scope.hideOffline, isTrue);
    });

    test('with no store it still works, in memory', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(machineScopeProvider.notifier).toggle('a', online: true);
      expect(c.read(machineScopeProvider).excluded, {'a'});
    });
  });

  group('machineScopeLabel', () {
    final machines = [
      machine('mbp'),
      machine('stu'),
      machine('old', online: false),
    ];

    test('default scope over a mix of online and offline reads all machines', () {
      expect(machineScopeLabel(machines, const MachineScope()), 'All machines');
    });

    test('everything in scope reads all machines', () {
      final scope = const MachineScope().selectAll(['mbp', 'stu', 'old']);
      expect(machineScopeLabel(machines, scope), 'All machines');
    });

    test('a single machine is named', () {
      final scope = const MachineScope().toggled('stu', online: true);
      expect(machineScopeLabel(machines, scope), 'mbp');
    });

    test('otherwise a count', () {
      final scope = const MachineScope()
          .toggled('stu', online: true)
          .toggled('old', online: false);
      expect(machineScopeLabel(machines, scope), '2 of 3 machines');
    });
  });

  group('buildMachineDirectory', () {
    final now = DateTime(2026, 10, 30, 12);
    RemoteAgentEntry recent(String uuid, String name) => RemoteAgentEntry(
      RecentAgent(
        agentDeviceId: uuid,
        agentLabel: name,
        agentEd25519Pubkey: 'pk',
        relayUrl: 'wss://relay',
        pairedAt: DateTime(2026),
        lastConnectedAt: DateTime(2026, 10, 29),
        hostMachineName: name,
      ),
    );
    InventoryAgent inventory(String uuid, {DateTime? lastSeenAt}) =>
        InventoryAgent(
          deviceUuid: uuid,
          displayName: uuid,
          platform: 'linux',
          ed25519Pub: 'pk',
          lastSeenAt: lastSeenAt,
        );

    List<MachineInfo> build({
      List<DrawerEntry>? entries,
      List<InventoryAgent> inv = const [],
      Map<String, bool> connected = const {},
    }) => buildMachineDirectory(
      entries: entries ?? [recent('mbp', 'MacBook Pro')],
      inventory: inv,
      includeLocal: true,
      localName: 'This machine',
      localOnline: true,
      connected: connected,
      remoteAccess: const {'mbp': false},
      now: now,
    );

    test('this device first, then remote machines', () {
      final machines = build();
      expect(machines.map((m) => m.id), [kLocalMachineKey, 'mbp']);
      expect(machines.last.name, 'MacBook Pro');
      expect(machines.last.remoteAccessEnabled, isFalse);
    });

    test('a recent heartbeat reads online; a stale one offline', () {
      expect(
        build(inv: [inventory('mbp', lastSeenAt: now.subtract(const Duration(minutes: 1)))])
            .last
            .online,
        isTrue,
      );
      final stale = build(
        inv: [inventory('mbp', lastSeenAt: now.subtract(const Duration(hours: 5)))],
      ).last;
      expect(stale.online, isFalse);
      expect(stale.lastSeenAt, now.subtract(const Duration(hours: 5)));
    });

    test('a connected socket is online whatever the heartbeat says', () {
      expect(build(connected: const {'mbp': true}).last.online, isTrue);
    });

    test('our own last connection is shown as seen, but is no evidence of being up', () {
      final m = build().last;
      expect(m.online, isFalse);
      expect(m.lastSeenAt, DateTime(2026, 10, 29));
    });

    test('a machine listed twice appears once', () {
      final machines = build(
        entries: [recent('mbp', 'MacBook Pro'), recent('mbp', 'MacBook Pro')],
      );
      expect(machines.where((m) => m.id == 'mbp'), hasLength(1));
    });
  });
}
