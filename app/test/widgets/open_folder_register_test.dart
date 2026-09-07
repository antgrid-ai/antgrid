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
import 'package:antgrid/launcher/local_agent_launcher.dart';
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

/// A host with a fixed answer for `project:resolve`, or none at all.
///
/// Subclassed rather than faked through a HostController: the point under test
/// is that `registerPickedFolder` persists what the HOST says a folder opens
/// as, and nothing below that call is part of the contract.
class _FakeLauncher extends LocalAgentLauncher {
  _FakeLauncher(this.answer);

  final ResolvedLocalProject? answer;

  @override
  Future<ResolvedLocalProject?> resolveProject(String folder) async => answer;
}

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  Future<WidgetRef> pumpRefHost(
    WidgetTester tester, {
    ResolvedLocalProject? resolves,
  }) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          // Never the real launcher: its shared HostController reads the
          // machine's own host.json, so an unfaked resolve would answer from
          // whatever Antgrid is running on the developer's desktop.
          localAgentLauncherProvider.overrideWithValue(
            _FakeLauncher(resolves),
          ),
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

  // The host folds a linked worktree into its repository's primary checkout,
  // so the id the app persists for one must be the host's, not the hash of the
  // path the user pointed at. The row's own folder and label follow it: the
  // checkout the host serves files, git and sessions from is the workspace
  // this row opens.
  const repo = ResolvedLocalProject(
    projectId: 'primary-checkout-id',
    repoPath: '/repos/antgrid',
    selectedPath: '/repos/antgrid/.wt/feature',
    label: 'antgrid',
    isGitRepository: true,
  );

  testWidgets('a worktree pick is stored as the project the host opens', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester, resolves: repo);

    final id = await tester.runAsync(
      () => registerPickedFolder(ref.container, folder, select: false),
    );

    expect(id, repo.projectId);
    final stored = stores.projectStore.list().single;
    expect(stored.projectId, repo.projectId);
    expect(stored.folder, repo.repoPath);
    expect(stored.displayName, repo.label);
    expect(
      stored.projectId,
      isNot(await tester.runAsync(() => computeProjectId(folder))),
      reason: 'the path hash is the answer the host was asked to replace',
    );
  });

  testWidgets('the id a pick used before the host was asked does not survive', (
    tester,
  ) async {
    // What a pre-resolve pick left behind: a row for this folder under the
    // hash of the folder itself. Kept beside the corrected row it is a second
    // drawer entry for one checkout, and its cached sessions hold a
    // session-bus link keyed on an id no lead project answers to.
    final ref = await pumpRefHost(tester, resolves: repo);
    final stale = (await tester.runAsync(() => computeProjectId(folder)))!;
    await tester.runAsync(
      () => stores.projectStore.upsert(
        AbProject(
          projectId: stale,
          folder: folder,
          displayName: 'feature',
          hostDeviceUuid: 'anon-A',
          hostMachineName: '',
          lastOpenedAt: DateTime.utc(2026, 1, 1),
        ),
      ),
    );

    await tester.runAsync(
      () => registerPickedFolder(ref.container, folder, select: false),
    );

    expect(
      stores.projectStore.list().map((p) => p.projectId),
      [repo.projectId],
      reason: 'one checkout, one row',
    );
  });

  testWidgets('a row for another folder under that id is left alone', (
    tester,
  ) async {
    // `forgetAlias` matches the folder as well as the id, so a real project
    // that happens to collide is never the thing a pick deletes.
    final ref = await pumpRefHost(tester, resolves: repo);
    final stale = (await tester.runAsync(() => computeProjectId(folder)))!;
    await tester.runAsync(
      () => stores.projectStore.upsert(
        AbProject(
          projectId: stale,
          folder: '$folder-elsewhere',
          displayName: 'elsewhere',
          hostDeviceUuid: 'anon-A',
          hostMachineName: '',
          lastOpenedAt: DateTime.utc(2026, 1, 1),
        ),
      ),
    );

    await tester.runAsync(
      () => registerPickedFolder(ref.container, folder, select: false),
    );

    expect(
      stores.projectStore.list().map((p) => p.projectId),
      containsAll(<String>[stale, repo.projectId]),
    );
  });

  testWidgets('a host that cannot answer leaves the pick on the path hash', (
    tester,
  ) async {
    // The pre-verb behaviour, and the one a machine whose host is not up yet
    // still gets: a folder pick must open the folder, never fail on a resolve.
    final ref = await pumpRefHost(tester);

    final id = await tester.runAsync(
      () => registerPickedFolder(ref.container, folder, select: false),
    );

    expect(id, await tester.runAsync(() => computeProjectId(folder)));
    expect(stores.projectStore.list().single.folder, folder);
  });
}
