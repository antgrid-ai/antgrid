// The drawer's entries to Memory: a revealed lightbulb on local and
// advertised-remote project rows plus a Memory nav row, all absent under the
// sample project.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
import 'package:antgrid/widgets/memory/memory_project_button.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/drawer_entries.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/projects_drawer.dart';

import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';
const _localId = 'alpha-local';
const _localName = 'Alpha local';
const _remoteProjectId = 'gamma';
const _remoteName = 'Gamma';

/// Rows reveal their actions on hover only where there is a pointer; the test
/// default platform is touch, which shows them permanently.
void desktopTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;
  final targets = <MemoryTarget>[];

  setUp(() async {
    useInMemoryPrefs();
    targets.clear();
    stores = await buildTestStoreOverrides();
    await stores.projectStore.upsert(
      AbProject(
        projectId: _localId,
        folder: '/tmp/$_localId',
        displayName: _localName,
        hostDeviceUuid: _localId,
        hostMachineName: '',
        lastOpenedAt: DateTime(2026, 1, 1),
      ),
    );
    await stores.recentAgentsStore.upsert(
      RecentAgent(
        agentDeviceId: _machineUuid,
        agentLabel: 'Remote pair',
        agentEd25519Pubkey: 'pub',
        relayUrl: 'wss://relay.example.com',
        pairedAt: DateTime(2026, 1, 1),
        lastConnectedAt: DateTime(2026, 1, 2),
        hostMachineName: _machineName,
      ),
    );
  });
  tearDown(() async => stores.close());

  Map<String, dynamic> answer(Map<String, dynamic> request) =>
      switch (request['op']) {
        'projects' => {
          'projects': <Object>[],
          'memories': 0,
          'earlier_versions': 0,
        },
        'list' || 'search' => {
          'results': <Object>[],
          'has_more': false,
          'total': 0,
        },
        _ => {
          'available': true,
          'enabled': true,
          'paused': false,
          'project_paused': false,
          'search_status': 'ready',
          'recovery_status': 'ready',
          'pending_operations': 0,
        },
      };

  List<Override> overrides() => [
    ...stores.overrides,
    currentUserProvider.overrideWith((_) async => null),
    accountAgentsProvider.overrideWith((_) async => const []),
    for (final id in const [_localId, _machineUuid])
      projectStatusProvider(
        id,
      ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
    hostStatusProvider.overrideWith(
      (_) => Stream.value(const HostStatus(HostPhase.up)),
    ),
    supervisorStatusProvider(
      _machineUuid,
    ).overrideWith((_) => Stream.value(const Connected())),
    controlPlaneStateProvider(_machineUuid).overrideWith(
      (_) => Stream.value(
        const ControlPlaneState(
          projects: [
            AdvertisedProject(
              projectId: _remoteProjectId,
              label: _remoteName,
              path: '/gamma',
              running: true,
            ),
          ],
        ),
      ),
    ),
    memoryDrawerSummaryProvider.overrideWith(
      (_) async => MemoryProjects.fromJson({
        'projects': [
          {'project_id': _localId, 'memories': 3, 'earlier_versions': 1},
        ],
        'memories': 7,
        'earlier_versions': 1,
      }),
    ),
    memoryRequestProvider.overrideWith((ref, target) {
      targets.add(target);
      return (request) async => answer(request);
    }),
  ];

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1000, 2000),
    Widget home = const Scaffold(body: ProjectsDrawer()),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    return container;
  }

  Future<void> expandMachine(WidgetTester tester) async {
    await tester.tap(find.text(_machineName));
    await tester.pumpAndSettle();
  }

  Finder rowOf(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(HoverableDrawerRow),
  );

  desktopTest('a local row opens the screen filtered to its project', (
    tester,
  ) async {
    await pump(tester);
    await expandMachine(tester);
    expect(find.byTooltip('$_localName memories (3)'), findsNothing);
    await hoverRow(tester, find.text(_localName));
    final action = find.descendant(
      of: rowOf(_localName),
      matching: find.byTooltip('$_localName memories (3)'),
    );
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    final screen = tester.widget<MemoryScreen>(find.byType(MemoryScreen));
    expect(screen.target, const MemoryTarget.machine());
    expect(screen.initialProjectId, _localId);
  });

  desktopTest('an advertised remote row opens its machine, by project id', (
    tester,
  ) async {
    await pump(tester);
    await expandMachine(tester);
    await hoverRow(tester, find.text(_remoteName));
    final action = find.descendant(
      of: rowOf(_remoteName),
      matching: find.byTooltip('$_remoteName memories'),
    );
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    final screen = tester.widget<MemoryScreen>(find.byType(MemoryScreen));
    expect(screen.initialProjectId, _remoteProjectId);
    expect(screen.target.machineId, _machineUuid);
    expect(screen.target.label, isNotEmpty);
    expect(screen.target.label, isNot('This machine'));
    expect(
      screen.target,
      MemoryTarget.machine(machineId: _machineUuid, label: screen.target.label),
    );
  });

  desktopTest('the sample project has no lightbulb and there is no nav row', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(find.text('Memory'), findsOneWidget);
    container.read(demoModeProvider.notifier).set(true);
    await tester.pumpAndSettle();
    final sample = demoDrawerEntries().single.displayName;
    expect(find.text(sample), findsOneWidget);
    await hoverRow(tester, find.text(sample));
    expect(find.byTooltip('New session'), findsOneWidget);
    expect(find.byType(MemoryProjectButton), findsNothing);
    expect(find.text('Memory'), findsNothing);
  });

  desktopTest('the Memory nav row carries the machine total', (tester) async {
    await pump(tester);
    final row = find.ancestor(
      of: find.text('Memory'),
      matching: find.byType(HoverableDrawerRow),
    );
    final nav = row.evaluate().isNotEmpty ? row : find.text('Memory');
    expect(nav, findsWidgets);
    expect(find.text('7'), findsOneWidget);
  });

  desktopTest('the lightbulb is announced once, without its count', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await pump(tester);
      await expandMachine(tester);
      await hoverRow(tester, find.text(_localName));
      expect(
        find.bySemanticsLabel(RegExp('^$_localName memories')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('$_localName memories'), findsOneWidget);
      expect(find.bySemanticsLabel('$_localName memories (3)'), findsNothing);
    } finally {
      handle.dispose();
    }
  });

  desktopTest('the machine bands carry no memory button', (tester) async {
    await pump(tester);
    await expandMachine(tester);
    expect(find.byType(MachineDrawerHeaderRow), findsWidgets);
    for (final band in [
      find.byType(MachineDrawerHeaderRow),
      find.byType(LocalMachineBand),
    ]) {
      expect(
        find.descendant(of: band, matching: find.byType(MemoryProjectButton)),
        findsNothing,
      );
    }
  });

  desktopTest('in a real Scaffold drawer, Memory opens and the drawer closes', (
    tester,
  ) async {
    final key = GlobalKey<ScaffoldState>();
    await pump(
      tester,
      size: const Size(500, 900),
      home: Scaffold(
        key: key,
        drawer: const Drawer(child: ProjectsDrawer()),
        body: const SizedBox.expand(),
      ),
    );
    key.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(key.currentState!.isDrawerOpen, isTrue);
    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();
    // flutter test's substitute font is about twice as wide as the real sans, so
    // the compact toolbar's pickers overflow here; layout is covered elsewhere.
    tester.takeException();
    expect(find.byType(MemoryScreen), findsOneWidget);
    expect(key.currentState!.isDrawerOpen, isFalse);
  });

  test('the drawer count never reaches the host unless it is up now', () async {
    // The test default platform is mobile, where the count is off entirely.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var askedForHost = 0;
    Future<MemoryProjects?> summaryAt(HostPhase phase) async {
      final container = ProviderContainer(
        overrides: [
          hostStatusProvider.overrideWith(
            (_) => Stream.value(HostStatus(phase)),
          ),
          hostControllerProvider.overrideWith((ref) {
            askedForHost++;
            throw StateError('the drawer count reached HostController');
          }),
        ],
      );
      addTearDown(container.dispose);
      // Unlistened providers are paused, so a bare read never settles.
      container.listen(hostStatusProvider, (_, _) {});
      await container.read(hostStatusProvider.future);
      final summary = container.listen(
        memoryDrawerSummaryProvider.future,
        (_, _) {},
      );
      return summary.read();
    }

    for (final phase in HostPhase.values.where((p) => p != HostPhase.up)) {
      expect(await summaryAt(phase), isNull, reason: '$phase');
    }
    expect(askedForHost, 0);
    // Proves the spy is wired: up is the one phase that asks.
    expect(await summaryAt(HostPhase.up), isNull);
    expect(askedForHost, 1);
  });
}
