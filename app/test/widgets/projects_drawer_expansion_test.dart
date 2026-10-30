// The project-first sidebar: one row per project merged across machines, the
// machine scope that filters it, and the Needs you section above it.
//
// Seeding writes straight into the real stores (buildTestStoreOverrides) so the
// providers see real data without provider-level mocking.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/models/project_catalog.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/machine_scope_menu.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/session_row.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

const _projectId = 'local-antgrid';
const _remoteProjectId = 'remote-antgrid';
const _machineUuid = 'machine-1';
const _machineName = 'MacBook Pro';
const _remote = 'github.com/acme/antgrid';

AbProject _project({String name = 'antgrid'}) => AbProject(
  projectId: _projectId,
  folder: '/tmp/$name',
  displayName: name,
  hostDeviceUuid: _projectId,
  hostMachineName: '',
  lastOpenedAt: DateTime.now(),
);

SessionEntry _session(String id, {int lastUsedAt = 1, bool running = false}) =>
    SessionEntry(
      id: id,
      name: 'Session $id',
      createdAt: 0,
      lastUsedAt: lastUsedAt,
      archived: false,
      running: running,
    );

SessionEntry _managedSession(String id, String branch) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 0,
  lastUsedAt: id == '2' ? 2 : 1,
  archived: false,
  running: false,
  checkoutId: 'checkout-$id',
  checkoutKind: 'managed-worktree',
  checkoutBranch: branch,
);

RecentAgent _remoteMachine() => RecentAgent(
  agentDeviceId: _machineUuid,
  agentLabel: 'Remote pair',
  agentEd25519Pubkey: 'pub',
  relayUrl: 'wss://relay.example.com',
  pairedAt: DateTime(2026, 1, 1),
  lastConnectedAt: DateTime(2026, 1, 2),
  hostMachineName: _machineName,
);

InventoryAgent _heartbeat({required bool fresh}) => InventoryAgent(
  deviceUuid: _machineUuid,
  displayName: _machineName,
  platform: 'macos',
  ed25519Pub: 'pub',
  lastSeenAt: fresh
      ? DateTime.now()
      : DateTime.now().subtract(const Duration(days: 1)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  Future<void> seedLocal(List<SessionEntry> sessions) async {
    await stores.projectStore.upsert(_project());
    await stores.cachedSessionsStore.put(_projectId, sessions);
    // Drain the debounce timer so flutter_test sees no pending timer after the
    // tree is disposed.
    await stores.cachedSessionsStore.flushNow();
  }

  /// The same repository on a remote machine, plus that machine's catalog and
  /// the local catalog naming the shared origin.
  Future<void> seedRemoteCopy(List<SessionEntry> sessions) async {
    await stores.recentAgentsStore.upsert(_remoteMachine());
    stores.cachedSessionsStore
      ..putCatalog(kLocalMachineKey, const [
        CatalogProject(
          projectId: _projectId,
          gitRemote: _remote,
          gitRemoteProbed: true,
        ),
      ])
      ..putCatalog(_machineUuid, const [
        CatalogProject(
          projectId: _remoteProjectId,
          label: 'antgrid',
          gitRemote: _remote,
          gitRemoteProbed: true,
        ),
      ]);
    await stores.cachedSessionsStore.put(
      '$_machineUuid.$_remoteProjectId',
      sessions,
    );
    await stores.cachedSessionsStore.flushNow();
  }

  Widget buildDrawer({bool machineOnline = true}) {
    return ProviderScope(
      overrides: [
        ...stores.overrides,
        projectStatusProvider(
          _projectId,
        ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
        // The footer's account row: signed out renders a static CTA with no
        // network.
        currentUserProvider.overrideWith((_) async => null),
        accountAgentsProvider.overrideWith(
          (_) async => [_heartbeat(fresh: machineOnline)],
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
    );
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(ProjectsDrawer)));

  testWidgets('a quiet project starts folded and opens on tap', (tester) async {
    await seedLocal([_session('a')]);
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    expect(find.text('antgrid'), findsOneWidget);
    expect(find.byType(SessionRow), findsNothing);

    await tester.tap(find.text('antgrid'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRow), findsOneWidget);

    await tester.tap(find.text('antgrid'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionRow), findsNothing);
  });

  testWidgets('one repo on two machines is one row, its sessions tagged by machine', (
    tester,
  ) async {
    await seedLocal([_session('local', lastUsedAt: 1)]);
    await seedRemoteCopy([_session('remote', lastUsedAt: 2)]);
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    expect(find.text('antgrid'), findsOneWidget);
    await tester.tap(find.text('antgrid'));
    await tester.pumpAndSettle();

    expect(find.byType(SessionRow), findsNWidgets(2));
    // The tag sits where a pointer reveals the kebab — on touch the kebab is
    // always there, so this is a desktop assertion.
    expect(find.text(_machineName), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('an offline machine is out of scope until picked in the menu', (
    tester,
  ) async {
    await seedRemoteCopy([_session('remote')]);
    await tester.pumpWidget(buildDrawer(machineOnline: false));
    await tester.pumpAndSettle();

    // Its only project is on a machine the default scope leaves out.
    expect(find.text('antgrid'), findsNothing);
    expect(find.text('No projects on the machines in scope.'), findsOneWidget);

    await tester.tap(find.byType(MachineScopeButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_machineName).last);
    await tester.pumpAndSettle();
    // Close the menu.
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(find.text('antgrid'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
  });

  testWidgets('Show all machines brings a hidden project back', (tester) async {
    await seedRemoteCopy([_session('remote')]);
    await tester.pumpWidget(buildDrawer(machineOnline: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show all machines'));
    await tester.pumpAndSettle();
    expect(find.text('antgrid'), findsOneWidget);
  });

  testWidgets('a session waiting on the user is listed under Needs you', (
    tester,
  ) async {
    await seedLocal([_session('a', running: true)]);
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();
    expect(find.text('NEEDS YOU'), findsNothing);

    containerOf(tester)
        .read(remoteSessionStatusProvider.notifier)
        .setLocalSessionStatuses({
          _projectId: {'a': AgentWorkStatus.attention},
        });
    await tester.pump();

    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('This machine · antgrid'), findsOneWidget);
  });

  testWidgets('the scope menu says when a machine has remote access off', (
    tester,
  ) async {
    await seedRemoteCopy([_session('remote')]);
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();
    containerOf(tester)
        .read(machineAdvertisedProjectsProvider.notifier)
        .setAdvert(_machineUuid, (projectCount: 0, remoteAccessEnabled: false));

    await tester.tap(find.byType(MachineScopeButton));
    await tester.pumpAndSettle();
    expect(find.text('remote off'), findsOneWidget);
  });

  for (final layout in <({String name, Size size})>[
    (name: 'phone', size: const Size(390, 844)),
    (name: 'desktop', size: const Size(1200, 800)),
  ]) {
    testWidgets('${layout.name} keeps managed sessions flat and one line each', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = layout.size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await seedLocal([
        _managedSession('1', 'antgrid/session-1'),
        _managedSession('2', 'antgrid/session-2'),
      ]);

      await tester.pumpWidget(buildDrawer());
      await tester.pumpAndSettle();
      await tester.tap(find.text('antgrid'));
      await tester.pumpAndSettle();

      expect(find.byType(SessionRow), findsNWidgets(2));
      // The branch is deliberately not on the row: it is a generated name that
      // says nothing the session name doesn't, and a second line doubles the
      // height of every isolated session in a list built for scanning.
      expect(find.text('antgrid/session-1'), findsNothing);
      expect(find.text('antgrid/session-2'), findsNothing);
    });
  }
}
