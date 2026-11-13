// The projects drawer is one Carbon surface: a single scope at its root, no
// `Ab*` widget under it, and every control a full target on a phone. These
// tests mount every row type at once so a row that drifts back to the old
// design system, or a target that shrinks, fails here rather than in review.
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/launcher/host_controller.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart'
    show projectStatusProvider;
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/host_status.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/account_footer.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/widgets/drawer_entry_row.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:antgrid/widgets/update_row.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/demo_harness.dart';
import '../helpers/hover.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _machineUuid = 'machine-1';
const _machineName = 'RadhaAI';
const _warmProjectId = 'alpha-local';
const _warmName = 'Alpha local';
const _bareProjectId = 'beta-local';
const _bareName = 'Beta local';
const _advertisedProjectId = 'gamma';
const _advertisedName = 'Gamma';
const _sessionName = 'Trace the reflow';

/// The scope that wraps the drawer is the one `Ab*` name the guard has to let
/// through when it scans the whole overlay rather than the scope's subtree.
const _allowScope = {'AbAgentMark', 'AbCarbonScope'};

AbProject _project(String id, String name) => AbProject(
  projectId: id,
  folder: '/tmp/$id',
  displayName: name,
  hostDeviceUuid: id,
  hostMachineName: '',
  lastOpenedAt: DateTime(2026, 1, 1),
);

SessionEntry _session() => SessionEntry(
  id: 'sess-1',
  name: _sessionName,
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
);

RecentAgent _machine() => RecentAgent(
  agentDeviceId: _machineUuid,
  agentLabel: 'Remote pair',
  agentEd25519Pubkey: 'pub',
  relayUrl: 'wss://relay.example.com',
  pairedAt: DateTime(2026, 1, 1),
  lastConnectedAt: DateTime(2026, 1, 2),
  hostMachineName: _machineName,
);

Finder _actionsFor(String name) => find.byWidgetPredicate(
  (w) => w is CarbonOverflowMenu && w.semanticLabel == 'Actions for $name',
  description: 'overflow menu "Actions for $name"',
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
  description: 'button "$label"',
);

Finder _navLink(String label) => find.byWidgetPredicate(
  (w) => w is CarbonSideNavLink && w.label == label,
  description: 'side nav link "$label"',
);

/// Runs [body] with [platform] in force, lifting it inside the body:
/// flutter_test asserts every foundation debug var is unset the moment the
/// body returns, before any teardown runs.
Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Tall enough that the whole drawer is laid out at once: the project list is
/// reorderable, and a row scrolled out of it is never built.
void _useTallView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 2000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

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
    await stores.projectStore.upsert(_project(_warmProjectId, _warmName));
    await stores.projectStore.upsert(_project(_bareProjectId, _bareName));
    await stores.cachedSessionsStore.put(_warmProjectId, [_session()]);
    // Cancels the store's write debounce so no timer outlives the tree.
    await stores.cachedSessionsStore.flushNow();
    await stores.recentAgentsStore.upsert(_machine());
  }

  List<Override> populated() => [
    ...stores.overrides,
    currentUserProvider.overrideWith((_) async => null),
    accountAgentsProvider.overrideWith((_) async => <InventoryAgent>[]),
    for (final id in const [_warmProjectId, _bareProjectId, _machineUuid])
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
              projectId: _advertisedProjectId,
              label: _advertisedName,
              path: '/gamma',
              running: true,
            ),
          ],
        ),
      ),
    ),
  ];

  /// Every row type at once: local band, a warm project with a session, a bare
  /// project, a remote machine band and its advertised project.
  Future<void> pumpPopulated(WidgetTester tester) async {
    _useTallView(tester);
    await seed();
    await tester.pumpWidget(
      ProviderScope(
        overrides: populated(),
        child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(_machineName));
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    testWidgets('${platform.name}: one Carbon scope and no Ab widget inside '
        'it, with every row type mounted', (tester) async {
      await _onPlatform(platform, () async {
        await pumpPopulated(tester);

        expect(find.byType(LocalMachineBand), findsOneWidget);
        expect(find.byType(MachineDrawerHeaderRow), findsOneWidget);
        expect(find.byType(DrawerEntryRow), findsWidgets);
        expect(find.byType(AdvertisedProjectRow), findsOneWidget);
        expect(find.byType(SessionRow), findsOneWidget);
        expect(find.byType(AccountFooter), findsOneWidget);
        expect(find.byType(AbCarbonScope), findsOneWidget);
        expect(abWidgetsInScope(tester), isEmpty);

        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('${platform.name}: the guard holds with the row menus open', (
      tester,
    ) async {
      await _onPlatform(platform, () async {
        await pumpPopulated(tester);

        for (final name in const [_bareName, _sessionName]) {
          await hoverRow(tester, find.text(name));
          await tester.tap(_actionsFor(name));
          await tester.pumpAndSettle();
          // Scanned from the overlay: an open menu is mounted outside the
          // drawer's own subtree.
          expect(
            abWidgetsInScope(
              tester,
              scope: find.byType(Overlay).first,
              allow: _allowScope,
            ),
            isEmpty,
            reason: 'the $name menu mounts an Ab widget',
          );
          await tester.tapAt(const Offset(990, 1990));
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(const SizedBox());
      });
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('${platform.name}: every control is at least a 44pt target', (
      tester,
    ) async {
      await _onPlatform(platform, () async {
        await pumpPopulated(tester);

        final drawer = find.byType(ProjectsDrawer);
        void expectTall(Finder finder, String what) {
          final found = find.descendant(of: drawer, matching: finder);
          expect(found, findsWidgets, reason: 'no $what mounted');
          for (final e in found.evaluate()) {
            final size = (e.renderObject! as RenderBox).size;
            expect(
              size.height,
              greaterThanOrEqualTo(44 - 0.01),
              reason: '$what is ${size.height} tall',
            );
          }
        }

        expectTall(find.byType(CarbonSideNavLink), 'side nav link');
        expectTall(find.byType(CarbonSideNavMenu), 'side nav menu');
        expectTall(_button('Refresh'), 'refresh button');
        expectTall(_actionsFor(_bareName), 'project overflow menu');
        expectTall(_actionsFor(_sessionName), 'session overflow menu');
        expectTall(_button('New session'), 'new session button');

        await tester.pumpWidget(const SizedBox());
      });
    });
  }

  group('empty drawer', () {
    List<Override> emptyOverrides(void Function() onFetch) => [
      ...stores.overrides,
      accountAgentsProvider.overrideWith((_) async {
        onFetch();
        return <InventoryAgent>[];
      }),
      currentUserProvider.overrideWith((_) async => null),
    ];

    Future<void> pumpEmpty(
      WidgetTester tester,
      void Function() onFetch,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: emptyOverrides(onFetch),
          child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a phone is pointed at connecting a machine', (tester) async {
      await _onPlatform(TargetPlatform.android, () async {
        await pumpEmpty(tester, () {});
        expect(find.text('No projects yet'), findsOneWidget);
        expect(
          find.text('Connect a machine to see its projects here.'),
          findsOneWidget,
        );
        expect(find.text('Open folder'), findsNothing);
        expect(abWidgetsInScope(tester), isEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('a desktop is offered the folder picker in place', (
      tester,
    ) async {
      await _onPlatform(TargetPlatform.windows, () async {
        await pumpEmpty(tester, () {});
        expect(find.text('No projects yet'), findsOneWidget);
        expect(find.text('Open a folder to get started.'), findsOneWidget);
        expect(find.text('Open folder'), findsOneWidget);
        expect(abWidgetsInScope(tester), isEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('pulling down from zero rows re-fetches the inventory', (
      tester,
    ) async {
      await _onPlatform(TargetPlatform.android, () async {
        var fetches = 0;
        await pumpEmpty(tester, () => fetches++);
        expect(fetches, 1);

        // The empty state is a scrollable so overscroll has something to grab.
        await tester.drag(find.text('No projects yet'), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(fetches, 2);
        await tester.pumpWidget(const SizedBox());
      });
    });
  });

  testWidgets('the sample project hides refresh, the account footer and the '
      'update row', (tester) async {
    await _onPlatform(TargetPlatform.windows, () async {
      final container = await demoContainer();
      container.read(demoModeProvider.notifier).set(true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
        ),
      );
      await tester.pump();

      expect(_navLink('Scheduler'), findsOneWidget);
      expect(_button('Refresh'), findsNothing);
      expect(find.byType(AccountFooter), findsNothing);
      expect(find.byType(UpdateRow), findsNothing);
      expect(
        find.descendant(
          of: find.byType(LocalMachineBand),
          matching: find.byType(CarbonStatusDot),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Scheduler closes the phone drawer it was opened from', (
    tester,
  ) async {
    await _onPlatform(TargetPlatform.android, () async {
      final scaffoldKey = GlobalKey<ScaffoldState>();
      final container = await demoContainer(
        extraOverrides: [
          currentUserProvider.overrideWith((_) async => null),
          accountAgentsProvider.overrideWith((_) async => <InventoryAgent>[]),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              key: scaffoldKey,
              drawer: const Drawer(child: ProjectsDrawer()),
              body: const SizedBox(),
            ),
          ),
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      expect(scaffoldKey.currentState!.isDrawerOpen, isTrue);

      await tester.tap(_navLink('Scheduler'));
      await tester.pumpAndSettle();

      expect(container.read(workbenchSurfaceProvider), WorkbenchSurface.scheduler);
      expect(
        scaffoldKey.currentState!.isDrawerOpen,
        isFalse,
        reason: 'the destination would stay hidden behind the open drawer',
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}
