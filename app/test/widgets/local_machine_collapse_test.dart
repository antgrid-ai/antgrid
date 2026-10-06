// Verifies the "This machine" band's fold over every local project row:
// tapping it hides the local projects and their sessions but leaves the band
// (the only way to unfold) and every remote machine untouched, and the fold is
// remembered across launches.
//
// Seeding follows projects_drawer_expansion_test.dart: real stores written
// before pumpWidget, with only the per-row status streams and the account
// providers overridden.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/session_row.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

const _projectA = 'local-proj-a';
const _projectB = 'local-proj-b';
const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';
const _band = 'This machine';

AbProject _project(String id) => AbProject(
  projectId: id,
  folder: '/tmp/$id',
  displayName: id,
  hostDeviceUuid: id,
  hostMachineName: '',
  lastOpenedAt: DateTime.now(),
);

SessionEntry _session(String id) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
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

  Future<void> seedLocals() async {
    for (final id in [_projectA, _projectB]) {
      await stores.projectStore.upsert(_project(id));
      await stores.cachedSessionsStore.put(id, [_session('$id-s1')]);
    }
    // Cancels the store's write debounce so no timer outlives the tree.
    await stores.cachedSessionsStore.flushNow();
  }

  Widget buildDrawer({Key? scopeKey}) {
    return ProviderScope(
      key: scopeKey,
      overrides: [
        ...stores.overrides,
        for (final id in [_projectA, _projectB])
          projectStatusProvider(
            id,
          ).overrideWith((_) => Stream.value(const ProjectStatus.empty())),
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
    );
  }

  Future<void> tapBand(WidgetTester tester) async {
    await tester.tap(find.text(_band));
    await tester.pumpAndSettle();
  }

  testWidgets('local projects and their sessions are visible by default', (
    tester,
  ) async {
    await seedLocals();
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    expect(find.text(_band), findsOneWidget);
    expect(find.text(_projectA), findsOneWidget);
    expect(find.text(_projectB), findsOneWidget);
    expect(find.byType(SessionRow), findsNWidgets(2));
  });

  testWidgets(
    'tapping the band hides every local project and session but keeps the band',
    (tester) async {
      await seedLocals();
      await tester.pumpWidget(buildDrawer());
      await tester.pumpAndSettle();

      await tapBand(tester);

      expect(find.text(_band), findsOneWidget);
      expect(find.text(_projectA), findsNothing);
      expect(find.text(_projectB), findsNothing);
      expect(find.byType(SessionRow), findsNothing);
    },
  );

  testWidgets('tapping the band again restores the local projects', (
    tester,
  ) async {
    await seedLocals();
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    await tapBand(tester);
    expect(find.text(_projectA), findsNothing);

    await tapBand(tester);

    expect(find.text(_band), findsOneWidget);
    expect(find.text(_projectA), findsOneWidget);
    expect(find.text(_projectB), findsOneWidget);
    expect(find.byType(SessionRow), findsNWidgets(2));
  });

  testWidgets('folding the local band leaves remote machines untouched', (
    tester,
  ) async {
    await seedLocals();
    await stores.recentAgentsStore.upsert(_remoteMachine());
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();

    // Remote machines start collapsed; open this one so its projects render.
    await tester.tap(find.text(_machineName));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);

    await tapBand(tester);

    expect(find.text(_projectA), findsNothing);
    expect(find.text(_projectB), findsNothing);
    expect(find.text(_machineName), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('the fold survives a fresh ProviderScope', (tester) async {
    await seedLocals();
    await tester.pumpWidget(buildDrawer(scopeKey: UniqueKey()));
    await tester.pumpAndSettle();

    await tapBand(tester);
    expect(find.text(_projectA), findsNothing);

    await tester.pumpWidget(buildDrawer(scopeKey: UniqueKey()));
    await tester.pumpAndSettle();

    expect(find.text(_band), findsOneWidget);
    expect(find.text(_projectA), findsNothing);
    expect(find.text(_projectB), findsNothing);

    // Unfolding is remembered too.
    await tapBand(tester);
    await tester.pumpWidget(buildDrawer(scopeKey: UniqueKey()));
    await tester.pumpAndSettle();

    expect(find.text(_projectA), findsOneWidget);
    expect(find.text(_projectB), findsOneWidget);
    expect(find.byType(SessionRow), findsNWidgets(2));
  });
}
