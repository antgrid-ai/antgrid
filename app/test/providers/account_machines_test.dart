import 'dart:async';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/account_machines.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

class _FixedRecents extends RecentAgentsNotifier {
  _FixedRecents(this.seed);
  final List<RecentAgent> seed;
  @override
  List<RecentAgent> build() => seed;
}

RecentAgent _recent(String id, String label, int minute, {String? host}) =>
    RecentAgent(
      agentDeviceId: id,
      agentLabel: label,
      agentEd25519Pubkey: 'pub',
      relayUrl: 'wss://relay',
      pairedAt: DateTime.utc(2026),
      lastConnectedAt: DateTime.utc(2026, 1, 1, 0, minute),
      hostMachineName: host,
    );

InventoryAgent _account(String id, String name, {String? machine}) =>
    InventoryAgent(
      deviceUuid: id,
      displayName: name,
      platform: 'windows',
      ed25519Pub: 'pub',
      machineName: machine,
    );

ProviderContainer _container({
  List<RecentAgent> recents = const [],
  List<InventoryAgent> accounts = const [],
  String? own,
  Future<List<InventoryAgent>>? pendingAccounts,
  List<Override> extra = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      recentAgentsProvider.overrideWith(() => _FixedRecents(recents)),
      accountAgentsProvider.overrideWith(
        (ref) => pendingAccounts ?? Future.value(accounts),
      ),
      localDeviceUuidProvider.overrideWith((ref) async => own),
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _settled(ProviderContainer c) async {
  await c.read(accountAgentsProvider.future);
  await c.read(localDeviceUuidProvider.future);
}

void _platform(TargetPlatform p) {
  debugDefaultTargetPlatformOverride = p;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

void main() {
  group('desktop', () {
    setUp(() => _platform(TargetPlatform.windows));

    test('local comes first and account names beat recent names', () async {
      final c = _container(
        recents: [_recent('m1', 'Recent name', 1, host: 'Recent host')],
        accounts: [_account('m1', 'Display', machine: 'Account name')],
      );
      await _settled(c);
      final machines = c.read(accountMachinesProvider);
      expect(machines.keys.first, kLocalMachineKey);
      expect(machines, {
        kLocalMachineKey: 'Local machine',
        'm1': 'Account name',
      });
    });

    test('compound recent ids collapse to the machine uuid', () async {
      final c = _container(recents: [_recent('m1.proj', 'Laptop', 1)]);
      await _settled(c);
      expect(c.read(accountMachinesProvider).keys, contains('m1'));
    });

    test('this device is not listed as a remote of itself', () async {
      final c = _container(
        accounts: [_account('self', 'Me'), _account('m1', 'Laptop')],
        own: 'self',
      );
      await _settled(c);
      expect(c.read(accountMachinesProvider), {
        kLocalMachineKey: 'Local machine',
        'm1': 'Laptop',
      });
    });

    test('target follows the pick and defaults to local', () async {
      final c = _container(accounts: [_account('m1', 'Laptop')]);
      await _settled(c);
      expect(c.read(machineTargetProvider), isNull);

      c.read(machinePickProvider.notifier).set(kLocalMachineKey);
      expect(c.read(machineTargetProvider), isNull);

      c.read(machinePickProvider.notifier).set('m1');
      expect(c.read(machineTargetProvider), 'm1');

      c.read(machinePickProvider.notifier).set('gone');
      expect(c.read(machineTargetProvider), isNull);
    });
  });

  group('phone', () {
    setUp(() => _platform(TargetPlatform.iOS));

    test('the map has no local entry', () async {
      final c = _container(accounts: [_account('m1', 'Laptop')]);
      await _settled(c);
      expect(c.read(accountMachinesProvider), {'m1': 'Laptop'});
    });

    test('the default is the most recently connected recent', () async {
      final c = _container(
        recents: [_recent('a', 'A', 5), _recent('b', 'B', 9)],
        accounts: [_account('z', 'Z')],
      );
      await _settled(c);
      expect(c.read(machineTargetProvider), 'b');
    });

    test('without recents the first account machine is the default', () async {
      final c = _container(accounts: [_account('x', 'X'), _account('y', 'Y')]);
      await _settled(c);
      expect(c.read(machineTargetProvider), 'x');
    });

    test('no machines means no target', () async {
      final c = _container();
      await _settled(c);
      expect(c.read(machineTargetProvider), isNull);
    });

    test('a pick in the list wins and a stale pick falls back', () async {
      final c = _container(
        recents: [_recent('a', 'A', 5), _recent('b', 'B', 9)],
      );
      await _settled(c);
      c.read(machinePickProvider.notifier).set('a');
      expect(c.read(machineTargetProvider), 'a');
      c.read(machinePickProvider.notifier).set('gone');
      expect(c.read(machineTargetProvider), 'b');
    });
  });

  group('demo', () {
    test('builds no inventory and has no target, even on desktop', () {
      _platform(TargetPlatform.windows);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(demoModeProvider.notifier).set(true);
      c.read(machinePickProvider.notifier).set('m1');

      expect(c.read(accountMachinesProvider), isEmpty);
      expect(c.read(machineTargetProvider), isNull);
      expect(c.read(machinesSettlingProvider), isFalse);
      expect(c.exists(accountAgentsProvider), isFalse);
      expect(c.exists(localDeviceUuidProvider), isFalse);
      expect(c.exists(recentAgentsProvider), isFalse);
    });
  });

  group('machinesSettlingProvider', () {
    test('is true only while empty and the inventory has no value', () async {
      _platform(TargetPlatform.iOS);
      final never = Completer<List<InventoryAgent>>();
      final loading = _container(pendingAccounts: never.future);
      expect(loading.read(machinesSettlingProvider), isTrue);

      final loaded = _container(accounts: [_account('m1', 'Laptop')]);
      await _settled(loaded);
      expect(loaded.read(machinesSettlingProvider), isFalse);

      final empty = _container();
      await _settled(empty);
      expect(empty.read(machinesSettlingProvider), isFalse);
    });

    test('is false while a recent already fills the list', () {
      _platform(TargetPlatform.iOS);
      final never = Completer<List<InventoryAgent>>();
      final c = _container(
        recents: [_recent('a', 'A', 1)],
        pendingAccounts: never.future,
      );
      expect(c.read(machinesSettlingProvider), isFalse);
    });
  });

  group('machineConnectedProvider', () {
    test('a remote id follows its supervisor status', () async {
      _platform(TargetPlatform.iOS);
      final c = _container(
        extra: [
          supervisorStatusProvider(
            'm1',
          ).overrideWith((ref) => Stream.value(const Connected())),
          supervisorStatusProvider(
            'm2',
          ).overrideWith((ref) => Stream<SupervisorStatus?>.value(null)),
        ],
      );
      final on = c.listen(machineConnectedProvider('m1'), (_, _) {});
      final off = c.listen(machineConnectedProvider('m2'), (_, _) {});
      await c.read(supervisorStatusProvider('m1').future);
      await c.read(supervisorStatusProvider('m2').future);
      await Future<void>.delayed(Duration.zero);
      expect(on.read(), isTrue);
      expect(off.read(), isFalse);
    });

    test('a phone with no machine is never connected', () {
      _platform(TargetPlatform.android);
      final c = _container();
      expect(c.read(machineConnectedProvider(null)), isFalse);
    });

    test('the desktop host follows the host phase', () async {
      _platform(TargetPlatform.windows);
      final c = _container(
        extra: [
          hostStatusProvider.overrideWith(
            (ref) => Stream.value(const HostStatus(HostPhase.up)),
          ),
        ],
      );
      final sub = c.listen(machineConnectedProvider(null), (_, _) {});
      await c.read(hostStatusProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(sub.read(), isTrue);
    });
  });
}
