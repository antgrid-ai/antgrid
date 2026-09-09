// Verifies the user-visible expansion contract for ProjectsDrawer:
//   1. A project shows its sessions by default (expanded).
//   2. Tapping the project row collapses it (sessions hidden).
//
// Seeding follows the same pattern as drawer_entry_row_status_test.dart:
// buildTestStoreOverrides() opens all four stores; the project is written
// directly to projectStore and the session cache to cachedSessionsStore
// before pumpWidget, so the providers see real data without provider-level
// mocking.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/session_row.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

// The seeded project id and display name used across both tests.
const _projectId = 'test-proj-1';
const _displayName = 'test-proj-1';
const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';

AbProject _project() => AbProject(
  projectId: _projectId,
  folder: '/tmp/$_projectId',
  displayName: _displayName,
  hostDeviceUuid: _projectId,
  hostMachineName: '',
  lastOpenedAt: DateTime.now(),
);

SessionEntry _session() => SessionEntry(
  id: 'sess-1',
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
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

  Future<void> seed() async {
    await stores.projectStore.upsert(_project());
    await stores.cachedSessionsStore.put(_projectId, [_session()]);
    // Drain the debounce timer so flutter_test doesn't see a pending timer
    // after the widget tree is disposed (CachedSessionsStore debounces writes
    // by 200ms; flushNow() cancels the timer and writes synchronously).
    await stores.cachedSessionsStore.flushNow();
  }

  Future<void> seedRemoteMachine() async {
    await stores.recentAgentsStore.upsert(_remoteMachine());
  }

  Widget buildDrawer() {
    return ProviderScope(
      overrides: [
        ...stores.overrides,
        // DrawerEntryRow reads projectStatusProvider — return an empty stream
        // so the row renders without trying to open a real ProjectSession.
        projectStatusProvider(
          _projectId,
        ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
        // ProjectsDrawer → AccountFooter reads currentUserProvider. Return
        // null (not signed in) so the footer renders a static "Sign in" CTA
        // without hitting the network.
        currentUserProvider.overrideWith((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
    );
  }

  testWidgets('a project is expanded by default and shows its sessions', (
    tester,
  ) async {
    await seed();
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    // Expanded by default → at least one SessionRow is visible.
    expect(find.byType(SessionRow), findsWidgets);
  });

  testWidgets('tapping a project row collapses it (sessions hidden)', (
    tester,
  ) async {
    await seed();
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    // Sanity: sessions present before tap.
    expect(find.byType(SessionRow), findsWidgets);

    // Tap the project row's title text to toggle collapse.
    // DrawerEntryRow wraps AbListRow with onTap → collapsedDrawerIdsProvider.notifier.toggle(id).
    await tester.tap(find.text(_displayName));
    await tester.pumpAndSettle();

    // After collapse, SessionsList is no longer rendered → no SessionRow.
    expect(find.byType(SessionRow), findsNothing);
  });

  testWidgets('remote machine uses a group header row and expands projects', (
    tester,
  ) async {
    await seedRemoteMachine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          projectStatusProvider(
            _machineUuid,
          ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
          currentUserProvider.overrideWith((_) async => null),
          accountAgentsProvider.overrideWith((_) async => const []),
          controlPlaneStateProvider(_machineUuid).overrideWith(
            (_) => Stream.value(
              const ControlPlaneState(
                projects: [
                  AdvertisedProject(
                    projectId: 'alpha',
                    label: 'Alpha',
                    path: '/alpha',
                    running: true,
                  ),
                ],
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
      ),
    );
    await tester.pumpAndSettle();

    final rowFinder = find.ancestor(
      of: find.text(_machineName),
      matching: find.byType(AbListRow),
    );
    final row = tester.widget<AbListRow>(rowFinder);
    expect(row.leading, isNull);
    expect(row.title, isA<Row>());
    expect(find.text('Alpha'), findsNothing);

    await tester.tap(find.text(_machineName));
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets(
    'expanded machine explains an advert with remoteAccessEnabled:false',
    (tester) async {
      // The bridge advertises [] while its remote-access switch is off, and the
      // machine-level flag is what lets the subtree say WHY instead of the
      // neutral "Offline — no projects advertised." wording. The copy is the
      // NOT_ALLOWED verb refusal's, pinned via friendlyErrorCopy so the two
      // surfaces can't drift.
      await seedRemoteMachine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            projectStatusProvider(
              _machineUuid,
            ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
            currentUserProvider.overrideWith((_) async => null),
            accountAgentsProvider.overrideWith((_) async => const []),
            controlPlaneStateProvider(_machineUuid).overrideWith(
              (_) => Stream.value(
                const ControlPlaneState(
                  projects: [],
                  remoteAccessEnabled: false,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(_machineName));
      await tester.pumpAndSettle();

      expect(find.text(friendlyErrorCopy('NOT_ALLOWED')!), findsOneWidget);
      expect(find.text('Offline — no projects advertised.'), findsNothing);
    },
  );

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
      await stores.projectStore.upsert(_project());
      await stores.cachedSessionsStore.put(_projectId, [
        _managedSession('1', 'antgrid/session-1'),
        _managedSession('2', 'antgrid/session-2'),
      ]);
      await stores.cachedSessionsStore.flushNow();

      await tester.pumpWidget(buildDrawer());
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
