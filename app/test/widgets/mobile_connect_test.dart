import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/machine_directory.dart';
import 'package:antgrid/providers/mobile_connection.dart';
import 'package:antgrid/providers/project_work_status.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/mobile_machine_store.dart';
import 'package:antgrid/widgets/mobile/mobile_connect.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

MachineInfo _machine(
  String id, {
  bool online = true,
  bool? remote,
  String platform = 'macos',
}) => MachineInfo(
  id: id,
  name: id,
  isLocal: false,
  online: online,
  remoteAccessEnabled: remote,
  platform: platform,
  lastSeenAt: DateTime.now(),
);

/// The status screen the canvas would show, driven by the real provider.
class _Flow extends ConsumerWidget {
  const _Flow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(mobileConnectStatusProvider);
    if (status.phase == MobileConnectPhase.connected) {
      return const Center(child: ConnectedMachineButton());
    }
    return MobileConnectScreen(status: status);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;
  late MobileMachineStore machineStore;
  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
    machineStore = await MobileMachineStore.open();
  });
  tearDown(() => stores.close());

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    List<MachineInfo>? machines,
    Future<ControlPlaneClient?> Function()? dial,
  }) async {
    final manager = MachineConnectionManager(crypto: CryptoService());
    addTearDown(manager.disposeAll);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          currentUserProvider.overrideWith((_) async => null),
          mobileConnectEnabledProvider.overrideWithValue(true),
          mobileMachineStoreProvider.overrideWithValue(machineStore),
          accountAgentsProvider.overrideWith((_) async => <InventoryAgent>[]),
          machineDirectoryProvider.overrideWithValue(
            machines ??
                [
                  _machine('MacBook'),
                  _machine('Studio', platform: 'linux'),
                  _machine('ThinkPad', online: false),
                  _machine('Desktop', remote: false, platform: 'windows'),
                ],
          ),
          recentSessionsProvider.overrideWithValue(const []),
          recentSessionStatusesProvider.overrideWithValue(const {}),
          relayConnectionManagerProvider.overrideWithValue(manager),
          // Never answers unless the test says otherwise: a dial in flight.
          controlPlaneClientForProvider.overrideWith(
            (_, _) => (dial ?? () => Completer<ControlPlaneClient?>().future)(),
          ),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const Scaffold(body: _Flow()),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(_Flow)));
  }

  testWidgets(
    'the picker groups machines by whether the phone can reach them',
    (tester) async {
      await machineStore.write(lastMachineId: 'Studio', connectedAt: null);
      await pump(tester);

      expect(find.text('Choose a machine'), findsOneWidget);
      expect(find.text('ONLINE'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('REMOTE ACCESS OFF'), findsOneWidget);
      expect(find.text('last used'), findsOneWidget);
      expect(find.text('Linux · online'), findsOneWidget);
      expect(
        find.text('Turn on remote access on that machine to connect from here'),
        findsOneWidget,
      );
      // The last-used machine leads the online list.
      expect(
        tester.getTopLeft(find.text('Studio')).dy,
        lessThan(tester.getTopLeft(find.text('MacBook')).dy),
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Desktop, remote access off')),
        findsOneWidget,
      );
    },
  );

  testWidgets('an offline machine cannot be picked', (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('ThinkPad'));
    await tester.pump();
    expect(c.read(mobileConnectionProvider).machineId, isNull);
  });

  testWidgets('picking a machine connects to it, and Cancel goes back', (
    tester,
  ) async {
    final c = await pump(tester);
    await tester.tap(find.text('MacBook'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(c.read(mobileConnectionProvider).machineId, 'MacBook');
    expect(machineStore.read().lastMachineId, 'MacBook');
    expect(find.textContaining('Connecting to'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Reaching the machine, in progress'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.read(mobileConnectionProvider).machineId, isNull);
    expect(find.text('Choose a machine'), findsOneWidget);
  });

  testWidgets('a machine that never answers offers Try again', (tester) async {
    await pump(tester);
    await tester.tap(find.text('MacBook'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pump(kMobileConnectTimeout);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('connect to'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Choose another machine'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Choose a machine'), findsOneWidget);
  });

  testWidgets('a refused dial fails without waiting out the timeout', (
    tester,
  ) async {
    await pump(tester, dial: () async => throw StateError('offline'));
    await tester.tap(find.text('MacBook'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('asleep or off the network'), findsOneWidget);
  });

  testWidgets('connected: the machine heads the home and opens the switcher', (
    tester,
  ) async {
    final c = await pump(tester);
    await tester.tap(find.text('MacBook'));
    await tester.pump(const Duration(milliseconds: 100));
    c.read(machineLiveConnectionProvider.notifier).set('MacBook', true);
    c.read(machineAdvertisedProjectsProvider.notifier).setAdvert('MacBook', (
      projectCount: 1,
      remoteAccessEnabled: true,
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.bySemanticsLabel('Connected to MacBook, idle. Switch machine'),
      findsOneWidget,
    );

    await tester.tap(find.byType(ConnectedMachineButton));
    await tester.pumpAndSettle();
    expect(find.text('Switch machine'), findsOneWidget);
    expect(find.text('Connected · idle'), findsWidgets);
    expect(find.text('Remote access is off on this machine'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(c.read(mobileConnectionProvider).machineId, isNull);
    expect(find.text('Choose a machine'), findsOneWidget);
  });

  testWidgets('remote access off is named as the reason', (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('MacBook'));
    await tester.pump(const Duration(milliseconds: 100));
    c.read(machineAdvertisedProjectsProvider.notifier).setAdvert('MacBook', (
      projectCount: 0,
      remoteAccessEnabled: false,
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Remote access is off'), findsOneWidget);
  });
}
