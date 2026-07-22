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
        () => registerPickedFolder(ref, folder, select: false),
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

  testWidgets('registerPickedFolder defaults to selecting the folder project', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester);

    final id = await tester.runAsync(() => registerPickedFolder(ref, folder));

    expect(id, isNotNull);
    expect(ref.read(selectedRegistrationIdProvider), id);
  });
}
