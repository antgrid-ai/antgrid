// Tests for the agent panel header's per-project action logic.
//
// These exercise the real `localProjectActions` seam (the production
// `_AgentStatusHeader` delegates to it), including the
// selectedRegistrationIdProvider → projectsProvider lookup: a per-project
// mobile-access toggle (AbMobileCta) for local projects, a RemoteHostChip for
// remote projects, and nothing when no project is focused.
import 'package:antgrid/design/widgets/ab_mobile_cta.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/mobile_devices_hub.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/remote_host_chip.dart';
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

/// Fake hub notifier that returns a fixed phones list without touching the real
/// loopback host control client. Mutation methods are unused in these
/// render-only tests.
class _FakeHubNotifier extends MobileDevicesHubNotifier {
  _FakeHubNotifier(this._list);
  final PhonesList _list;
  @override
  Future<PhonesList> build() async => _list;
}

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

/// Renders the result of the real production [localProjectActions] so the
/// header's lookup + branching is exercised directly (not re-implemented).
class _ActionsHarness extends ConsumerWidget {
  const _ActionsHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Row(mainAxisSize: MainAxisSize.min, children: localProjectActions(ref));
}

/// Pumps the harness with [project] seeded into the store and optionally
/// focused. Pass `selectedId: null` to leave no project focused. [platform]
/// drives `isMobilePlatform`; it is reset before returning so the foundation
/// debug-var invariant holds (the tree is already built by then).
Future<void> _pump(
  WidgetTester tester, {
  required TestStoreOverrides stores,
  AbProject? project,
  required String? selectedId,
  TargetPlatform platform = TargetPlatform.macOS,
  PhonesList? phones,
  MobileAccessPolicy? policy,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  if (project != null) await stores.projectStore.upsert(project);
  final hubList =
      phones ?? const PhonesList(phones: [], knownProjects: []);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        localDeviceUuidProvider.overrideWith((ref) async => _localUuid),
        selectedRegistrationIdProvider.overrideWith((_) => selectedId),
        mobileDevicesHubProvider.overrideWith(() => _FakeHubNotifier(hubList)),
        mobileAccessPolicyProvider.overrideWith(
          () => _FakePolicyNotifier(policy ?? const MobileAccessPolicy(projectIds: [])),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: _ActionsHarness()),
      ),
    ),
  );
  // Let the localDeviceUuidProvider future resolve.
  await tester.pump();
  await tester.pump();
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets(
    'local project with no phone allowing it shows "Enable mobile access"',
    (tester) async {
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final project = _localProject();
      await _pump(
        tester,
        stores: stores,
        project: project,
        selectedId: project.projectId,
        policy: const MobileAccessPolicy(projectIds: []),
      );

      expect(find.byType(AbMobileCta), findsOneWidget);
      expect(find.text('Enable mobile access'), findsOneWidget);
      expect(find.byType(RemoteHostChip), findsNothing);
    },
  );

  testWidgets(
    'local project allowed by a paired phone shows "Disable mobile access"',
    (tester) async {
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);

      final project = _localProject();
      await _pump(
        tester,
        stores: stores,
        project: project,
        selectedId: project.projectId,
        policy: MobileAccessPolicy(projectIds: [project.projectId]),
      );

      expect(find.byType(AbMobileCta), findsOneWidget);
      expect(find.text('Disable mobile access'), findsOneWidget);
      expect(find.byType(RemoteHostChip), findsNothing);
    },
  );

  testWidgets(
    'remote project header renders RemoteHostChip',
    (tester) async {
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
      expect(find.byType(AbMobileCta), findsNothing);
    },
  );

  testWidgets(
    'no focused project renders no actions',
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
      expect(find.byType(AbMobileCta), findsNothing);
    },
  );

  testWidgets(
    'mobile form factor renders no actions even for a focused remote project',
    (tester) async {
      // Mobile-access promotion is a desktop-host concept — never surfaced on
      // phones, regardless of the focused project.
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
}
