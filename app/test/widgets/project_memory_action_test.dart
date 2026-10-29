// The drawer is the only entry to Project Memory: a revealed action on both
// local and advertised-remote project rows, absent under the sample project.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
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
const _tip = 'Project memory';

Finder _title(String name) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data ?? '').toLowerCase() == 'memory · ${name.toLowerCase()}',
);

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

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 2000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
          memoryRequestProvider.overrideWith((ref, target) {
            targets.add(target);
            return (request) async => {
              'available': false,
              'enabled': false,
              'paused': false,
              'project_paused': false,
              'search_status': 'ready',
              'recovery_status': 'ready',
              'pending_operations': 0,
            };
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(_machineName));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(ProjectsDrawer)));
  }

  Finder rowOf(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(HoverableDrawerRow),
  );

  desktopTest('a local project row opens its own Project Memory', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byTooltip(_tip), findsNothing);
    await hoverRow(tester, find.text(_localName));
    final action = find.descendant(
      of: rowOf(_localName),
      matching: find.byTooltip(_tip),
    );
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.byType(MemoryScreen), findsOneWidget);
    expect(_title(_localName), findsOneWidget);
    expect(
      targets,
      contains(const MemoryTarget.project(_localId, label: _localName)),
    );
  });

  desktopTest('an advertised remote project row opens by its registration id', (
    tester,
  ) async {
    await pump(tester);
    await hoverRow(tester, find.text(_remoteName));
    final action = find.descendant(
      of: rowOf(_remoteName),
      matching: find.byTooltip(_tip),
    );
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(_title(_remoteName), findsOneWidget);
    expect(
      targets,
      contains(
        const MemoryTarget.project(
          '$_machineUuid.$_remoteProjectId',
          label: _remoteName,
        ),
      ),
    );
  });

  desktopTest('the sample project offers no memory action', (tester) async {
    final container = await pump(tester);
    container.read(demoModeProvider.notifier).set(true);
    await tester.pumpAndSettle();
    final sample = demoDrawerEntries().single.displayName;
    expect(find.text(sample), findsOneWidget);
    await hoverRow(tester, find.text(sample));
    expect(find.byTooltip('New session'), findsOneWidget);
    expect(find.byTooltip(_tip), findsNothing);
  });
}
