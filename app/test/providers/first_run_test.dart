import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/now_ticker.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/services/devices_api.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/storage/project_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

RecentSessionRow _row(String id) => RecentSessionRow(
  session: SessionEntry(
    id: id,
    name: id,
    createdAt: 0,
    lastUsedAt: 1,
    archived: false,
    running: false,
  ),
  origin: const RecentOrigin(
    isLocal: true,
    registrationId: 'p',
    projectId: 'p',
    machineUuid: null,
    projectName: 'proj',
    deviceName: 'This device',
  ),
);

DeviceSummary _device({
  required String kind,
  required String platform,
  String name = 'Device',
}) => DeviceSummary(
  id: 'id-$kind-$platform',
  deviceId: 'uuid-$kind-$platform',
  kind: kind,
  platform: platform,
  displayName: name,
);

/// Canned [DevicesApi] so the REAL otherAccountMobileDevicesProvider (with its
/// kind/platform filter) can run without network.
class _FakeDevicesApi extends DevicesApi {
  _FakeDevicesApi(this._devices)
    : super(licenseApiUrl: 'http://unused', cookieProvider: () async => null);

  final List<DeviceSummary> _devices;

  @override
  Future<List<DeviceSummary>> list() async => _devices;
}

Map<String, bool> _doneById(List<FirstRunStep> steps) => {
  for (final s in steps) s.id: s.done,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktopFirstRunStepsProvider', () {
    Future<(ProviderContainer, FirstRunStore)> build({
      bool? signedIn,
      bool withProject = false,
      List<RecentSessionRow> recents = const [],
      List<DeviceSummary> phones = const [],
      Set<String> latched = const {},
    }) async {
      useInMemoryPrefs();
      final firstRunStore = await FirstRunStore.open();
      if (latched.isNotEmpty) {
        await firstRunStore.write(FirstRunState(completedSteps: latched));
      }
      final projectStore = await ProjectStore.open();
      if (withProject) {
        await projectStore.upsert(
          AbProject(
            projectId: 'p',
            folder: '/tmp/p',
            displayName: 'proj',
            hostDeviceUuid: null,
            hostMachineName: 'here',
            lastOpenedAt: DateTime(2026),
          ),
        );
      }
      final container = ProviderContainer(
        overrides: [
          firstRunStoreProvider.overrideWithValue(firstRunStore),
          projectStoreProvider.overrideWithValue(projectStore),
          signedInProvider.overrideWith((_) => signedIn),
          recentSessionsProvider.overrideWith((_) => recents),
          otherAccountMobileDevicesProvider.overrideWith((_) async => phones),
        ],
      );
      addTearDown(container.dispose);
      return (container, firstRunStore);
    }

    test('all steps start unchecked with no signals', () async {
      final (container, _) = await build(signedIn: null);
      final done = _doneById(container.read(desktopFirstRunStepsProvider));
      expect(done, {
        FirstRunStepIds.signIn: false,
        FirstRunStepIds.openProject: false,
        FirstRunStepIds.startSession: false,
        FirstRunStepIds.connectPhone: false,
      });
    });

    test('steps check off as their live signals arrive', () async {
      final (container, _) = await build(
        signedIn: true,
        withProject: true,
        recents: [_row('s1')],
        phones: [_device(kind: 'app', platform: 'ios', name: 'iPhone')],
      );
      // Keep the autoDispose chain alive across the device fetch.
      final sub = container.listen(desktopFirstRunStepsProvider, (_, _) {});
      await container.read(otherAccountMobileDevicesProvider.future);
      // Let the AsyncData notification propagate to the steps provider.
      await Future<void>.delayed(Duration.zero);
      final done = _doneById(sub.read());
      expect(done.values, everyElement(isTrue));
    });

    test('a latched step stays checked when its live signal regresses',
        () async {
      final (container, _) = await build(
        signedIn: false,
        latched: {FirstRunStepIds.signIn, FirstRunStepIds.connectPhone},
      );
      final done = _doneById(container.read(desktopFirstRunStepsProvider));
      expect(done[FirstRunStepIds.signIn], isTrue);
      expect(done[FirstRunStepIds.connectPhone], isTrue);
      expect(done[FirstRunStepIds.openProject], isFalse);
    });
  });

  group('otherAccountMobileDevicesProvider', () {
    test('keeps only mobile kind:app records — agents and desktop controllers '
        'are filtered out', () async {
      useInMemoryPrefs();
      final firstRunStore = await FirstRunStore.open();
      final container = ProviderContainer(
        overrides: [
          firstRunStoreProvider.overrideWithValue(firstRunStore),
          signedInProvider.overrideWith((_) => true),
          // Deterministic single tick — the real periodic stream would leave a
          // pending timer.
          nowMinuteProvider.overrideWith((_) => Stream.value(DateTime(2026))),
          devicesApiProvider.overrideWithValue(
            _FakeDevicesApi([
              _device(kind: 'agent', platform: 'windows', name: 'Rig'),
              _device(kind: 'app', platform: 'windows', name: 'Rig (controller)'),
              _device(kind: 'app', platform: 'Android', name: 'Pixel'),
              _device(kind: 'app', platform: 'ios', name: 'iPhone'),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        otherAccountMobileDevicesProvider,
        (_, _) {},
      );
      final devices = await container.read(
        otherAccountMobileDevicesProvider.future,
      );
      sub.close();
      expect(devices.map((d) => d.displayName), ['Pixel', 'iPhone']);
    });
  });

  group('mobileFirstRunStepsProvider', () {
    Future<ProviderContainer> build({
      List<InventoryAgent> agents = const [],
    }) async {
      useInMemoryPrefs();
      final firstRunStore = await FirstRunStore.open();
      final container = ProviderContainer(
        overrides: [
          firstRunStoreProvider.overrideWithValue(firstRunStore),
          accountAgentsProvider.overrideWith((_) async => agents),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('starts fully unchecked on a fresh account', () async {
      final container = await build();
      final sub = container.listen(mobileFirstRunStepsProvider, (_, _) {});
      await container.read(accountAgentsProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(_doneById(sub.read()).values, everyElement(isFalse));
    });

    test('machine inventory, project adverts, and selection drive the steps',
        () async {
      final container = await build(
        agents: [
          InventoryAgent(
            deviceUuid: 'm1',
            displayName: 'Rig',
            platform: 'windows',
            ed25519Pub: 'AA==',
          ),
        ],
      );
      final sub = container.listen(mobileFirstRunStepsProvider, (_, _) {});
      await container.read(accountAgentsProvider.future);
      await Future<void>.delayed(Duration.zero);
      var done = _doneById(sub.read());
      expect(done[FirstRunStepIds.machineLinked], isTrue);
      expect(done[FirstRunStepIds.remoteOn], isFalse);
      expect(done[FirstRunStepIds.openedProject], isFalse);

      // Machine advertises projects → the "Remote is on" proxy flips.
      container
          .read(machineAdvertisedProjectsProvider.notifier)
          .setCount('m1', 2);
      done = _doneById(sub.read());
      expect(done[FirstRunStepIds.remoteOn], isTrue);

      // A machine that disconnects is cleared from the live map, but the
      // latched step (written by the checklist widget) would keep it checked;
      // here, unlatched, it honestly regresses.
      container.read(machineAdvertisedProjectsProvider.notifier).clear('m1');
      done = _doneById(sub.read());
      expect(done[FirstRunStepIds.remoteOn], isFalse);

      // Opening a project = a selected target.
      container
          .read(selectedTargetProvider.notifier)
          .set(const LocalProject('p1'));
      done = _doneById(sub.read());
      expect(done[FirstRunStepIds.openedProject], isTrue);
    });
  });

  group('firstRunChecklistVisibleProvider + controller persistence', () {
    test('dismiss hides the checklist and survives a reopen', () async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      final container = ProviderContainer(
        overrides: [firstRunStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      expect(container.read(firstRunChecklistVisibleProvider), isTrue);

      container.read(firstRunProvider.notifier).dismissChecklist();
      expect(container.read(firstRunChecklistVisibleProvider), isFalse);
      // Fire-and-forget persist has landed in the WithCache cache already.
      expect((await FirstRunStore.open()).read().checklistDismissed, isTrue);
    });

    test('completion hides the checklist forever, even when signals regress',
        () async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      final container = ProviderContainer(
        overrides: [firstRunStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      container.read(firstRunProvider.notifier).latchSteps({
        FirstRunStepIds.signIn,
        FirstRunStepIds.openProject,
      });
      container.read(firstRunProvider.notifier).latchSteps({
        FirstRunStepIds.startSession,
        FirstRunStepIds.connectPhone,
      });
      container.read(firstRunProvider.notifier).markChecklistCompleted();
      expect(container.read(firstRunChecklistVisibleProvider), isFalse);

      // A fresh container over the same prefs (an app restart) stays hidden
      // and keeps every latched step.
      final restarted = ProviderContainer(
        overrides: [
          firstRunStoreProvider.overrideWithValue(await FirstRunStore.open()),
        ],
      );
      addTearDown(restarted.dispose);
      expect(restarted.read(firstRunChecklistVisibleProvider), isFalse);
      expect(restarted.read(firstRunProvider).completedSteps, {
        FirstRunStepIds.signIn,
        FirstRunStepIds.openProject,
        FirstRunStepIds.startSession,
        FirstRunStepIds.connectPhone,
      });
    });

    test('nudge dismissals persist independently of the checklist', () async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      final container = ProviderContainer(
        overrides: [firstRunStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      container.read(firstRunProvider.notifier).dismissNudgeSoft();
      container.read(firstRunProvider.notifier).dismissNudgeDevice();
      final s = (await FirstRunStore.open()).read();
      expect(s.nudgeSoftDismissed, isTrue);
      expect(s.nudgeDeviceDismissed, isTrue);
      expect(s.checklistDismissed, isFalse);
    });
  });
}
