// Tests for the window title bar's trailing actions.
//
// These exercise the real `titleBarProjectActions` seam (the production
// `WindowTitleBarContents` delegates to it), covering the two independent
// derivations: the machine-wide remote-access chip (AbStateChip), which hangs
// off `localDeviceUuidProvider` alone, and the focus-derived RemoteHostChip,
// which comes from the selectedRegistrationIdProvider → projectsProvider lookup.
import 'package:antgrid/design/widgets/ab_state_chip.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/remote_access.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/remote_host_chip.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

class _FakePolicyNotifier extends RemoteAccessPolicyNotifier {
  _FakePolicyNotifier(this._policy);
  final RemoteAccessPolicy _policy;
  @override
  Future<RemoteAccessPolicy> build() async => _policy;
}

const _localUuid = 'local-device-uuid';
const _remoteUuid = 'remote-device-uuid';

AbProject _localProject() => AbProject(
  projectId: 'local-proj',
  folder: '/tmp/local-proj',
  displayName: 'Local',
  hostDeviceUuid: _localUuid,
  hostMachineName: '',
  lastOpenedAt: DateTime.now(),
);

AbProject _remoteProject() => AbProject(
  projectId: 'remote-proj',
  folder: '/tmp/remote-proj',
  displayName: 'Remote',
  hostDeviceUuid: _remoteUuid,
  hostMachineName: 'build-server',
  lastOpenedAt: DateTime.now(),
);

/// Renders the result of the real production [titleBarProjectActions] so the
/// header's lookup + branching is exercised directly (not re-implemented).
class _ActionsHarness extends ConsumerWidget {
  const _ActionsHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Row(mainAxisSize: MainAxisSize.min, children: titleBarProjectActions(ref));
}

/// Pumps the harness with [project] seeded into the store and optionally
/// focused. Pass `selectedId: null` to leave no project focused. Pass
/// `localUuid: null` to model mobile/web, where there is no local host.
/// [platform] drives `isMobilePlatform`; it is reset before returning so the
/// foundation debug-var invariant holds (the tree is already built by then).
Future<void> _pump(
  WidgetTester tester, {
  required TestStoreOverrides stores,
  AbProject? project,
  required String? selectedId,
  TargetPlatform platform = TargetPlatform.macOS,
  String? localUuid = _localUuid,
  bool mobileAccessEnabled = false,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  if (project != null) await stores.projectStore.upsert(project);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        localDeviceUuidProvider.overrideWith((ref) async => localUuid),
        selectedRegistrationIdProvider.overrideWith((_) => selectedId),
        remoteAccessPolicyProvider.overrideWith(
          () => _FakePolicyNotifier(
            RemoteAccessPolicy(enabled: mobileAccessEnabled),
          ),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: _ActionsHarness()),
      ),
    ),
  );
  // Let the localDeviceUuidProvider future resolve. Not pumpAndSettle: a
  // pending policy flip pulses forever and would time out.
  await tester.pump();
  await tester.pump();
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets(
    'remote access off reads "Remote off"',
    (tester) async {
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final project = _localProject();
      await _pump(
        tester,
        stores: stores,
        project: project,
        selectedId: project.projectId,
        mobileAccessEnabled: false,
      );

      expect(find.byType(AbStateChip), findsOneWidget);
      expect(find.text('Remote off'), findsOneWidget);
      expect(find.byType(RemoteHostChip), findsNothing);
    },
  );

  testWidgets(
    'remote access on reads "Remote on"',
    (tester) async {
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final project = _localProject();
      await _pump(
        tester,
        stores: stores,
        project: project,
        selectedId: project.projectId,
        mobileAccessEnabled: true,
      );

      expect(find.byType(AbStateChip), findsOneWidget);
      expect(find.text('Remote on'), findsOneWidget);
      expect(find.byType(RemoteHostChip), findsNothing);
    },
  );

  testWidgets(
    'a focused remote project renders the chip AND keeps the machine switch',
    (tester) async {
      // The switch governs YOUR machine, not the focused project's host, so
      // focusing a remote project must not take it away.
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final project = _remoteProject();
      await _pump(
        tester,
        stores: stores,
        project: project,
        selectedId: project.projectId,
      );

      expect(find.byType(RemoteHostChip), findsOneWidget);
      expect(find.byType(AbStateChip), findsOneWidget);
    },
  );

  testWidgets(
    'no focused project still renders the machine switch, without the chip',
    (tester) async {
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      // A remote project exists in the store but none is focused.
      await _pump(
        tester,
        stores: stores,
        project: _remoteProject(),
        selectedId: null,
      );

      expect(find.byType(RemoteHostChip), findsNothing);
      expect(find.byType(AbStateChip), findsOneWidget);
    },
  );

  testWidgets(
    'no local host uuid renders no switch',
    (tester) async {
      // localDeviceUuidProvider is null where there is no local bridge to
      // govern; withholding the switch there is what keeps it machine-scoped.
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      await _pump(
        tester,
        stores: stores,
        project: _remoteProject(),
        selectedId: null,
        localUuid: null,
      );

      expect(find.byType(AbStateChip), findsNothing);
    },
  );

  testWidgets(
    'mobile form factor renders no actions even for a focused remote project',
    (tester) async {
      // The switch is desktop-only: a phone must have no surface to grant
      // itself the machine.
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final project = _remoteProject();
      await _pump(
        tester,
        stores: stores,
        project: project,
        selectedId: project.projectId,
        platform: TargetPlatform.android,
      );

      expect(find.byType(RemoteHostChip), findsNothing);
      expect(find.byType(AbStateChip), findsNothing);
    },
  );

  // Desktop's window title bar never mounts below kCompactBreakpoint, so the
  // mobile agent page needs its own drawer button and breadcrumb — see
  // AgentPanel.build's mobile-only header.
  testWidgets(
    'at a narrow width AgentPanel shows the drawer button and breadcrumb',
    (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final stores = await buildTestStoreOverrides();
        addTearDown(stores.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [...stores.overrides],
            child: const MaterialApp(home: Scaffold(body: AgentPanel())),
          ),
        );
        await tester.pump();

        expect(find.byTooltip('Projects'), findsOneWidget);
        expect(find.byType(TitleBarBreadcrumb), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  /// Pumps the desktop AgentPanel at 1000px, where [AgentBar] replaces the
  /// mobile header.
  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [...stores.overrides],
        child: const MaterialApp(home: Scaffold(body: AgentPanel())),
      ),
    );
    await tester.pump();
  }

  // The breadcrumb moved OUT of the window title bar and into AgentBar, so the
  // desktop path carries it too now — only the mobile drawer button is still
  // exclusive to the narrow header.
  testWidgets('at a wide width AgentBar carries the breadcrumb', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpWide(tester);

      expect(find.byType(AgentBar), findsOneWidget);
      expect(find.byType(TitleBarBreadcrumb), findsOneWidget);
      expect(find.byTooltip('Projects'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // Every pane control belongs to a surface that stays mounted in every panel
  // mode; a copy here would be stranded in the one mode that unmounts this bar.
  testWidgets('AgentBar carries no layout controls of its own', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpWide(tester);

      expect(find.byTooltip('Expand'), findsNothing);
      expect(find.byTooltip('Restore'), findsNothing);
      expect(find.byTooltip('Collapse panel'), findsNothing);
      expect(find.byTooltip('Hide panel'), findsNothing);
      expect(find.byTooltip('Hide projects'), findsNothing);
      expect(find.byTooltip('Show projects'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
