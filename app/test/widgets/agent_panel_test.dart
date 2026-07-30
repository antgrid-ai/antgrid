// Tests for the window title bar's trailing actions.
//
// These exercise the real `titleBarProjectActions` seam (the production
// `WindowTitleBarContents` delegates to it), covering the two independent
// derivations: the machine-wide mobile-access switch (AbMobileCta), which hangs
// off `localDeviceUuidProvider` alone, and the focus-derived RemoteHostChip,
// which comes from the selectedRegistrationIdProvider → projectsProvider lookup.
import 'package:antgrid/design/widgets/ab_mobile_cta.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/remote_host_chip.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

class _FakePolicyNotifier extends MobileAccessPolicyNotifier {
  _FakePolicyNotifier(this._policy);
  final MobileAccessPolicy _policy;
  @override
  Future<MobileAccessPolicy> build() async => _policy;
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
        mobileAccessPolicyProvider.overrideWith(
          () => _FakePolicyNotifier(
            MobileAccessPolicy(enabled: mobileAccessEnabled),
          ),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: _ActionsHarness()),
      ),
    ),
  );
  // Let the localDeviceUuidProvider future resolve. Not pumpAndSettle: an
  // enabled AbMobileCta pulses forever and would time out.
  await tester.pump();
  await tester.pump();
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets(
    'mobile access off shows "Enable mobile access"',
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

      expect(find.byType(AbMobileCta), findsOneWidget);
      expect(find.text('Enable mobile access'), findsOneWidget);
      expect(find.byType(RemoteHostChip), findsNothing);
    },
  );

  testWidgets(
    'mobile access on shows "Disable mobile access"',
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

      expect(find.byType(AbMobileCta), findsOneWidget);
      expect(find.text('Disable mobile access'), findsOneWidget);
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
      expect(find.byType(AbMobileCta), findsOneWidget);
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
      expect(find.byType(AbMobileCta), findsOneWidget);
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

      expect(find.byType(AbMobileCta), findsNothing);
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
      expect(find.byType(AbMobileCta), findsNothing);
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

  testWidgets(
    'at a wide width AgentPanel shows neither the drawer button nor the breadcrumb',
    (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
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

        expect(find.byTooltip('Projects'), findsNothing);
        expect(find.byType(TitleBarBreadcrumb), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
