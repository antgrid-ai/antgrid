// Regression tests for the folder-pick flow's focus side effect.
//
// Picking a folder from the New Session composer must NOT focus the project
// (`selectProject`): on the landing (no focused project) that focus change
// flipped AppShell's route to WorkspaceShell mid-flow — a visible workspace
// flash, an unmounted picker whose WidgetRef died before it could set the
// composer target, and (for a brand-new folder) _bootstrapSessions bouncing
// the surface straight back. Selection is an explicit opt-in for callers that
// really mean "open this folder now".
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/launcher/project_id.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/widgets/open_folder_button.dart';

import '../helpers/fake_device_store.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  Future<WidgetRef> pumpRefHost(WidgetTester tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          // No provisioned device record: _resolveLocalHostUuid falls through
          // to the (mocked) SharedPreferences anonymous-uuid path.
          keychainDeviceStoreProvider.overrideWithValue(
            KeychainDeviceStore(storage: InMemoryDeviceSecretStorage(null)),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  final folder = '${Directory.systemTemp.path}/antgrid-register-picked-folder';

  testWidgets(
    'registerPickedFolder(select: false) upserts the project without changing focus',
    (tester) async {
      final ref = await pumpRefHost(tester);

      final id = await tester.runAsync(
        () => registerPickedFolder(ref.container, folder, select: false),
      );

      expect(id, isNotNull);
      expect(
        ref.read(projectsProvider).where((p) => p.projectId == id),
        isNotEmpty,
        reason: 'the picked folder must still be upserted as a project',
      );
      expect(
        ref.read(selectedRegistrationIdProvider),
        isNull,
        reason: 'picking a folder as a composer target must not focus it',
      );
    },
  );

  testWidgets('re-picking a folder re-stamps a stale host identity', (
    tester,
  ) async {
    // A row left on an identity this device no longer answers with — what a
    // folder opened during sign-in provisioning carries. Bumping only
    // `lastOpenedAt` (what this used to do) left it failing `isLocalFor`
    // forever: no working-directory actions, and a "Remote host" chip for a
    // folder the user just pointed at on this machine.
    final ref = await pumpRefHost(tester);
    final id = (await tester.runAsync(() => computeProjectId(folder)))!;
    await tester.runAsync(
      () => stores.projectStore.upsert(
        AbProject(
          projectId: id,
          folder: folder,
          displayName: 'stale',
          hostDeviceUuid: 'anon-A',
          hostMachineName: '',
          lastOpenedAt: DateTime.utc(2026, 1, 1),
        ),
      ),
    );

    await tester.runAsync(
      () => registerPickedFolder(ref.container, folder, select: false),
    );

    final localUuid = await tester.runAsync(
      () => ref.container.read(localDeviceUuidProvider.future),
    );
    final stored = stores.projectStore.list().singleWhere(
      (p) => p.projectId == id,
    );
    expect(stored.hostDeviceUuid, isNot('anon-A'));
    expect(stored.hostDeviceUuid, localUuid);
    expect(stored.isLocalFor(localUuid!), isTrue);
  });

  testWidgets('registerPickedFolder defaults to selecting the folder project', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester);

    final id = await tester.runAsync(
      () => registerPickedFolder(ref.container, folder),
    );

    expect(id, isNotNull);
    expect(ref.read(selectedRegistrationIdProvider), id);
  });
}
