import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/demo/demo_identity.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/open_checkout.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/storage/project_store.dart';

import '../helpers/prefs_test_mock.dart';

/// The gate on the session kebab's working-directory rows (Open folder, Open in
/// `<editor>`, Copy path). Those resolve their path over the LOOPBACK control
/// plane, so they may only be offered for a checkout this device hosts.
///
/// Cover for the shipped bug: the rows were gated on a remote-blocklist keyed
/// by exact id against the paired-agent list, which a remote project's compound
/// `<machineUuid>.<projectId>` id can never match — so every remote session
/// offered them.
void main() {
  const localUuid = 'local-device-uuid';
  late ProjectStore projectStore;

  Future<ProviderContainer> containerFor({
    String? deviceUuid = localUuid,
  }) async {
    useInMemoryPrefs();
    projectStore = await ProjectStore.open();
    final container = ProviderContainer(
      overrides: [
        projectStoreProvider.overrideWithValue(projectStore),
        localDeviceUuidProvider.overrideWith((_) async => deviceUuid),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> addProject(
    ProviderContainer container, {
    required String projectId,
    required String? hostDeviceUuid,
  }) => container
      .read(projectsProvider.notifier)
      .upsert(
        AbProject(
          projectId: projectId,
          folder: '/repos/antgrid',
          displayName: 'antgrid',
          hostDeviceUuid: hostDeviceUuid,
          hostMachineName: 'desk',
          lastOpenedAt: DateTime.now(),
        ),
      );

  test('a project hosted by this device is local', () async {
    final container = await containerFor();
    await addProject(
      container,
      projectId: '6e5c50e5d6f973a8',
      hostDeviceUuid: localUuid,
    );

    expect(
      await container.read(
        entryIsLocalCheckoutProvider('6e5c50e5d6f973a8').future,
      ),
      isTrue,
    );
  });

  test(
    'a pre-v2 project with no recorded host is local-to-this-device',
    () async {
      // Matches `AbProject.isLocalFor`: a null hostDeviceUuid only ever came from
      // a project opened on this install, before the field existed.
      final container = await containerFor();
      await addProject(
        container,
        projectId: '6e5c50e5d6f973a8',
        hostDeviceUuid: null,
      );

      expect(
        await container.read(
          entryIsLocalCheckoutProvider('6e5c50e5d6f973a8').future,
        ),
        isTrue,
      );
    },
  );

  test('a remote machine\'s project is not local', () async {
    final container = await containerFor();
    // The regression: a remote project is `<machineUuid>.<projectId>` and is
    // never in the local store at all.
    expect(
      await container.read(
        entryIsLocalCheckoutProvider('uuidA.6e5c50e5d6f973a8').future,
      ),
      isFalse,
    );
  });

  test('a project recorded against ANOTHER device is not local', () async {
    final container = await containerFor();
    await addProject(
      container,
      projectId: '6e5c50e5d6f973a8',
      hostDeviceUuid: 'some-other-device',
    );

    expect(
      await container.read(
        entryIsLocalCheckoutProvider('6e5c50e5d6f973a8').future,
      ),
      isFalse,
    );
  });

  test('a bare machine uuid is not local', () async {
    final container = await containerFor();

    expect(
      await container.read(entryIsLocalCheckoutProvider('uuidA').future),
      isFalse,
    );
  });

  test('the sample project is not local — it owns no checkout', () async {
    final container = await containerFor();

    expect(
      await container.read(entryIsLocalCheckoutProvider(kDemoProjectId).future),
      isFalse,
    );
  });

  test('an unresolved device uuid answers false rather than guessing', () async {
    // Mobile/web, and the window before a desktop uuid is minted: local-vs-remote
    // is undecidable, and the safe answer is the one that offers nothing.
    final container = await containerFor(deviceUuid: null);
    await addProject(
      container,
      projectId: '6e5c50e5d6f973a8',
      hostDeviceUuid: localUuid,
    );

    expect(
      await container.read(
        entryIsLocalCheckoutProvider('6e5c50e5d6f973a8').future,
      ),
      isFalse,
    );
  });
}
