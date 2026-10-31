import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/mobile_connection.dart';
import 'package:antgrid/providers/recent_sessions.dart'
    show MachineAdvertSummary;
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/mobile_machine_store.dart';

import '../helpers/prefs_test_mock.dart';

InventoryAgent _agent(String id, {Duration? seenAgo}) => InventoryAgent(
  deviceUuid: id,
  displayName: id,
  platform: 'macos',
  ed25519Pub: 'pub',
  lastSeenAt: seenAgo == null ? null : DateTime.now().subtract(seenAgo),
);

void main() {
  group('mobileConnectStatus', () {
    MobileConnectStatus status({
      String? machineId = 'mbp',
      bool? live,
      MachineAdvertSummary? advert,
      bool clientFailed = false,
      bool timedOut = false,
    }) => mobileConnectStatus(
      machineId: machineId,
      live: live,
      advert: advert,
      clientFailed: clientFailed,
      timedOut: timedOut,
    );
    const advert = (projectCount: 2, remoteAccessEnabled: true);

    test('no machine is the picker', () {
      expect(status(machineId: null).phase, MobileConnectPhase.choose);
    });

    test('connected needs the live socket and the project list', () {
      expect(status(live: true).phase, MobileConnectPhase.connecting);
      expect(status(live: true).reached, isTrue);
      expect(status(advert: advert).phase, MobileConnectPhase.connecting);
      expect(
        status(live: true, advert: advert).phase,
        MobileConnectPhase.connected,
      );
    });

    test('a failed dial or a timeout fails the attempt', () {
      expect(
        status(clientFailed: true).failure,
        MobileConnectFailure.unreachable,
      );
      expect(status(timedOut: true).phase, MobileConnectPhase.failed);
    });

    test('a connection that arrives after the timeout still wins', () {
      expect(
        status(live: true, advert: advert, timedOut: true).phase,
        MobileConnectPhase.connected,
      );
    });

    test('remote access off is a failure even with the socket up', () {
      final s = status(
        live: true,
        advert: (projectCount: 0, remoteAccessEnabled: false),
      );
      expect(s.phase, MobileConnectPhase.failed);
      expect(s.failure, MobileConnectFailure.remoteAccessOff);
    });
  });

  group('mobileConnectionProvider', () {
    late MobileMachineStore store;
    setUp(() async {
      useInMemoryPrefs();
      store = await MobileMachineStore.open();
    });

    ProviderContainer container({
      Future<List<InventoryAgent>> Function()? inventory,
    }) {
      final c = ProviderContainer(
        overrides: [
          eagerControlPlanesEnabledProvider.overrideWithValue(true),
          mobileMachineStoreProvider.overrideWithValue(store),
          accountAgentsProvider.overrideWith(
            (_) => (inventory ?? () async => <InventoryAgent>[])(),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('starts at the picker with nothing saved', () {
      final c = container();
      expect(c.read(mobileConnectionProvider).machineId, isNull);
      expect(c.read(mobileConnectionProvider).reconnectNextTime, isTrue);
    });

    test('connecting remembers the machine for next time', () async {
      final c = container();
      c.read(mobileConnectionProvider.notifier).connect('mbp');
      await Future<void>.delayed(Duration.zero);
      expect(store.read().lastMachineId, 'mbp');
    });

    test('reconnects to the last machine when it is up', () async {
      await store.write(lastMachineId: 'mbp', reconnect: true);
      final c = container(
        inventory: () async => [_agent('mbp', seenAgo: Duration.zero)],
      );
      expect(c.read(mobileConnectionProvider).machineId, 'mbp');
      await c.read(accountAgentsProvider.future);
      await Future<void>.delayed(Duration.zero);
      final s = c.read(mobileConnectionProvider);
      expect(s.machineId, 'mbp');
      expect(s.restored, isFalse);
    });

    test(
      'drops to the picker when the last machine turns out offline',
      () async {
        await store.write(lastMachineId: 'mbp', reconnect: true);
        final c = container(
          inventory: () async => [
            _agent('mbp', seenAgo: const Duration(hours: 1)),
          ],
        );
        c.read(mobileConnectionProvider);
        await c.read(accountAgentsProvider.future);
        await Future<void>.delayed(Duration.zero);
        expect(c.read(mobileConnectionProvider).machineId, isNull);
        expect(c.read(mobileConnectionProvider).lastMachineId, 'mbp');
      },
    );

    test('always asks when reconnecting is off', () async {
      await store.write(lastMachineId: 'mbp', reconnect: false);
      final c = container();
      final s = c.read(mobileConnectionProvider);
      expect(s.machineId, isNull);
      expect(s.lastMachineId, 'mbp');
      expect(s.reconnectNextTime, isFalse);
    });

    test('a timeout for a machine the user has left is ignored', () {
      final c = container();
      final n = c.read(mobileConnectionProvider.notifier);
      n.connect('mbp');
      n.connect('stu');
      n.markTimedOut('mbp');
      expect(c.read(mobileConnectionProvider).timedOut, isFalse);
      n.markTimedOut('stu');
      expect(c.read(mobileConnectionProvider).timedOut, isTrue);
      n.retry();
      expect(c.read(mobileConnectionProvider).timedOut, isFalse);
    });

    test('the phone dials and shows only the chosen machine', () {
      final c = container();
      expect(c.read(eagerControlPlaneTargetsProvider), isEmpty);
      expect(c.read(scopedMachineIdsProvider), isEmpty);
      c.read(mobileConnectionProvider.notifier).connect('mbp');
      expect(c.read(eagerControlPlaneTargetsProvider), {'mbp'});
      expect(c.read(scopedMachineIdsProvider), {'mbp'});
      c.read(mobileConnectionProvider.notifier).disconnect();
      expect(c.read(eagerControlPlaneTargetsProvider), isEmpty);
    });

    test(
      'off without a store, so the desktop-shaped tests keep their canvas',
      () {
        final c = ProviderContainer(
          overrides: [
            eagerControlPlanesEnabledProvider.overrideWithValue(true),
          ],
        );
        addTearDown(c.dispose);
        expect(c.read(mobileConnectEnabledProvider), isFalse);
      },
    );
  });

  test('platformLabel names the inventory tags', () {
    expect(platformLabel('macos'), 'macOS');
    expect(platformLabel('Windows'), 'Windows');
    expect(platformLabel('linux'), 'Linux');
    expect(platformLabel('ios'), isNull);
    expect(platformLabel(null), isNull);
  });
}
