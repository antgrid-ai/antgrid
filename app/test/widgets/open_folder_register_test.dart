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

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/launcher/project_id.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/keychain_device_store.dart';
import 'package:antgrid/util/path_basename.dart';
import 'package:antgrid/widgets/open_folder_button.dart';

import '../helpers/fake_device_store.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

/// Default fake resolver: answers exactly what the app-side fallback would
/// have synthesised itself (`kind: 'plain'`, no host involved).
LocalProjectResolver _plainResolver() =>
    (folder) async => ResolvedLocalProject(
      projectId: await computeProjectId(folder),
      repoPath: folder,
      selectedPath: folder,
      label: pathBasename(folder),
      isGitRepository: false,
      kind: 'plain',
    );

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  Future<WidgetRef> pumpRefHost(
    WidgetTester tester, {
    LocalProjectResolver? resolver,
  }) async {
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
          // Without this override registerPickedFolder would call
          // ensureHost() and try to spawn a real bridge host.
          localProjectResolverProvider.overrideWithValue(
            resolver ?? _plainResolver(),
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

  testWidgets(
    'a managed-checkout resolve folds onto the existing primary row and '
    'focuses the matching cached session, without minting a second row',
    (tester) async {
      const primaryId = 'primary-id';
      const checkoutId = 'ck-1';
      final ref = await pumpRefHost(
        tester,
        resolver: (f) async => const ResolvedLocalProject(
          projectId: primaryId,
          repoPath: '/repo',
          selectedPath: '/repo/wt/checkout',
          label: 'repo',
          isGitRepository: true,
          kind: 'managed-checkout',
          checkoutId: checkoutId,
        ),
      );
      await tester.runAsync(
        () => stores.projectStore.upsert(
          AbProject(
            projectId: primaryId,
            folder: '/repo',
            displayName: 'repo',
            hostDeviceUuid: null,
            hostMachineName: '',
            lastOpenedAt: DateTime.utc(2026, 1, 1),
          ),
        ),
      );
      await tester.runAsync(
        () => stores.cachedSessionsStore.put(primaryId, [
          const SessionEntry(
            id: 'session-on-checkout',
            name: 'Checkout session',
            createdAt: 1,
            lastUsedAt: 2,
            archived: false,
            running: false,
            checkoutId: checkoutId,
          ),
        ]),
      );

      final id = await tester.runAsync(
        () => registerPickedFolder(ref.container, '/repo/wt/checkout'),
      );

      expect(id, primaryId);
      expect(
        ref.read(projectsProvider).where((p) => p.projectId == primaryId),
        hasLength(1),
        reason: 'the checkout must fold onto the primary row, not add one',
      );
      expect(ref.read(selectedRegistrationIdProvider), primaryId);
      expect(
        ref.read(pendingActiveSessionIdProvider),
        'session-on-checkout',
        reason: 'focus should land on the checkout the user actually picked',
      );
    },
  );

  testWidgets(
    'a resolver failure falls back to the app-side path hash',
    (tester) async {
      final ref = await pumpRefHost(
        tester,
        resolver: (f) async =>
            throw HostControlException('TRANSPORT', 'host unreachable'),
      );

      final id = await tester.runAsync(
        () => registerPickedFolder(ref.container, folder),
      );
      final expectedId = await tester.runAsync(() => computeProjectId(folder));

      expect(id, expectedId);
      final stored = stores.projectStore.list().singleWhere(
        (p) => p.projectId == id,
      );
      expect(stored.folder, folder);
    },
  );
}
