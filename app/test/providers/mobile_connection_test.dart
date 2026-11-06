import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/mobile_connection.dart';
import 'package:antgrid/providers/recent_sessions.dart'
    show MachineAdvertSummary, machineAdvertisedProjectsProvider;
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/mobile_machine_store.dart';

import '../helpers/prefs_test_mock.dart';

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
    late DateTime now;
    setUp(() async {
      useInMemoryPrefs();
      store = await MobileMachineStore.open();
      now = DateTime.utc(2026, 11, 6, 12);
    });

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          eagerControlPlanesEnabledProvider.overrideWithValue(true),
          mobileMachineStoreProvider.overrideWithValue(store),
          mobileConnectionClockProvider.overrideWithValue(() => now),
          accountAgentsProvider.overrideWith(
            (_) async => const <InventoryAgent>[],
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    /// The phone last had a connection up to `mbp` [ago] before now.
    Future<void> lastConnected(Duration ago) =>
        store.write(lastMachineId: 'mbp', connectedAt: now.subtract(ago));

    void goLive(ProviderContainer c, String id) {
      c.read(machineLiveConnectionProvider.notifier).set(id, true);
      c.read(machineAdvertisedProjectsProvider.notifier).setAdvert(id, (
        projectCount: 1,
        remoteAccessEnabled: true,
      ));
    }

    Future<void> flush() => Future<void>.delayed(Duration.zero);

    test('starts at the picker with nothing saved', () {
      final c = container();
      expect(c.read(mobileConnectionProvider).machineId, isNull);
    });

    test(
      'a tap remembers the machine; reaching it starts the window',
      () async {
        final c = container();
        c.read(mobileConnectionProvider.notifier).connect('mbp');
        await flush();
        expect(store.read().lastMachineId, 'mbp');
        expect(store.read().connectedAt, isNull);

        goLive(c, 'mbp');
        await flush();
        expect(store.read().connectedAt, now);
      },
    );

    test('a machine never reached does not hold the next launch', () async {
      await lastConnected(const Duration(hours: 1));
      container().read(mobileConnectionProvider.notifier).connect('stu');
      await flush();
      expect(store.read().lastMachineId, 'stu');
      expect(store.read().connectedAt, isNull);
    });

    test('reopens on the last machine within the window', () async {
      await lastConnected(const Duration(hours: 23));
      expect(container().read(mobileConnectionProvider).machineId, 'mbp');
    });

    test('asks again once the window has passed', () async {
      await lastConnected(kMobileMachineStickyWindow);
      final s = container().read(mobileConnectionProvider);
      expect(s.machineId, isNull);
      expect(s.lastMachineId, 'mbp');
    });

    test('a window stamped in the future counts as passed', () async {
      await lastConnected(const Duration(days: -30));
      expect(container().read(mobileConnectionProvider).machineId, isNull);
    });

    test('a machine that left the account is let go', () async {
      await lastConnected(const Duration(hours: 1));
      final c = container();
      final n = c.read(mobileConnectionProvider.notifier);
      n.forget('stu');
      expect(c.read(mobileConnectionProvider).machineId, 'mbp');
      n.forget('mbp');
      await flush();
      expect(c.read(mobileConnectionProvider).machineId, isNull);
      expect(store.read().connectedAt, isNull);
    });

    test('each connection restarts the window', () async {
      final c = container();
      c.read(mobileConnectionProvider.notifier).connect('mbp');
      now = now.add(const Duration(hours: 20));
      goLive(c, 'mbp');
      await flush();
      expect(store.read().connectedAt, now);
    });

    test('backgrounding while connected restarts the window', () async {
      final c = container();
      c.read(mobileConnectionProvider.notifier).connect('mbp');
      goLive(c, 'mbp');
      now = now.add(const Duration(minutes: 5));
      c.read(mobileConnectionProvider.notifier).stampIfConnected();
      await flush();
      expect(store.read().connectedAt, now);
    });

    test('backgrounding while not connected leaves the window', () async {
      final c = container();
      c.read(mobileConnectionProvider.notifier).connect('mbp');
      goLive(c, 'mbp');
      final reached = now;
      c.read(machineLiveConnectionProvider.notifier).set('mbp', false);
      now = now.add(const Duration(hours: 2));
      c.read(mobileConnectionProvider.notifier).stampIfConnected();
      await flush();
      expect(store.read().connectedAt, reached);
    });

    test('disconnecting ends the window but keeps the last machine', () async {
      final c = container();
      c.read(mobileConnectionProvider.notifier).connect('mbp');
      goLive(c, 'mbp');
      c.read(mobileConnectionProvider.notifier).disconnect();
      await flush();
      expect(store.read().lastMachineId, 'mbp');
      expect(store.read().connectedAt, isNull);
      final next = container();
      expect(next.read(mobileConnectionProvider).machineId, isNull);
      expect(next.read(mobileConnectionProvider).lastMachineId, 'mbp');
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

    test('a timeout the connection then outran no longer counts', () {
      final c = container();
      final n = c.read(mobileConnectionProvider.notifier);
      n.connect('mbp');
      n.markTimedOut('mbp');
      expect(c.read(mobileConnectionProvider).timedOut, isTrue);
      goLive(c, 'mbp');
      expect(c.read(mobileConnectionProvider).timedOut, isFalse);
      // A later blip is a reconnect in progress, not a failure.
      c.read(machineLiveConnectionProvider.notifier).set('mbp', false);
      expect(
        mobileConnectStatus(
          machineId: 'mbp',
          live: false,
          advert: null,
          clientFailed: false,
          timedOut: c.read(mobileConnectionProvider).timedOut,
        ).phase,
        MobileConnectPhase.connecting,
      );
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
