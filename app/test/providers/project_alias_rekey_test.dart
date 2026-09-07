// A project row keyed on an id no bridge holds, healed when the host opens it.
//
// The pick asks the host what a folder opens as, but only PEEKS for one — so a
// folder picked before any host was warm keeps the selected path's hash. For a
// linked worktree that is not the id the bridge serves it under, and nothing
// re-resolves a row afterwards: only a re-pick asks again, and a drawer tap
// never does. The row then names a project no bridge holds for as long as it
// exists, and `_leadRef` publishes that id to a peer machine as this machine's
// identity.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/projects.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

void main() {
  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() => stores.close());

  const worktree = '/repos/antgrid/.wt/feature';
  const stale = 'hash-of-the-worktree-path';
  const resolved = ResolvedLocalProject(
    projectId: 'primary-checkout-id',
    repoPath: '/repos/antgrid',
    selectedPath: worktree,
    label: 'antgrid',
    isGitRepository: true,
  );

  Future<WidgetRef> pumpRefHost(WidgetTester tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: stores.overrides,
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

  Future<void> seedStale(WidgetTester tester, {String folder = worktree}) =>
      tester.runAsync(
        () => stores.projectStore.upsert(
          AbProject(
            projectId: stale,
            folder: folder,
            displayName: 'feature',
            hostDeviceUuid: 'device-A',
            hostMachineName: '',
            lastOpenedAt: DateTime.utc(2026, 1, 1),
          ),
        ),
      ).then((_) {});

  testWidgets('a row the host opens elsewhere is re-keyed to what it opened', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester);
    await seedStale(tester);

    await tester.runAsync(
      () => ref
          .read(projectsProvider.notifier)
          .adoptResolvedId(
            staleId: stale,
            folder: worktree,
            resolved: resolved,
          ),
    );

    final rows = stores.projectStore.list();
    expect(
      rows.where((p) => p.projectId == stale),
      isEmpty,
      reason: 'the alias names a project no bridge holds and must not survive',
    );
    final row = rows.singleWhere((p) => p.projectId == resolved.projectId);
    // The repo path travels with the id: the Capability Card is read from this
    // folder, so a row re-keyed but still pointing at the worktree would keep
    // answering the worktree's branch.
    expect(row.folder, resolved.repoPath);
    expect(row.displayName, resolved.label);
    expect(row.hostDeviceUuid, 'device-A');
  });

  testWidgets('the workspace lands on the row that replaced the alias', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester);
    await seedStale(tester);
    ref.read(selectedTargetProvider.notifier).set(const LocalProject(stale));

    await tester.runAsync(
      () => ref
          .read(projectsProvider.notifier)
          .adoptResolvedId(
            staleId: stale,
            folder: worktree,
            resolved: resolved,
          ),
    );

    // `forgetAlias` clears the selection it invalidates, so without the
    // re-select the user is left on an empty shell for a project still open.
    expect(ref.read(selectedRegistrationIdProvider), resolved.projectId);
  });

  testWidgets('a row already standing under the resolved id is left alone', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester);
    await seedStale(tester);
    await tester.runAsync(
      () => stores.projectStore.upsert(
        AbProject(
          projectId: resolved.projectId,
          folder: resolved.repoPath,
          displayName: 'antgrid',
          hostDeviceUuid: 'device-A',
          hostMachineName: '',
          lastOpenedAt: DateTime.utc(2026, 9, 1),
        ),
      ),
    );

    await tester.runAsync(
      () => ref
          .read(projectsProvider.notifier)
          .adoptResolvedId(
            staleId: stale,
            folder: worktree,
            resolved: resolved,
          ),
    );

    final row = stores.projectStore.list().singleWhere(
      (p) => p.projectId == resolved.projectId,
    );
    expect(
      row.lastOpenedAt,
      DateTime.utc(2026, 9, 1),
      reason: 'adopting the alias timestamps would reorder the drawer',
    );
    expect(stores.projectStore.list().where((p) => p.projectId == stale), isEmpty);
  });

  testWidgets('a row stamped from a different folder is not touched', (
    tester,
  ) async {
    final ref = await pumpRefHost(tester);
    await seedStale(tester, folder: '/somewhere/else');

    await tester.runAsync(
      () => ref
          .read(projectsProvider.notifier)
          .adoptResolvedId(
            staleId: stale,
            folder: worktree,
            resolved: resolved,
          ),
    );

    // The id collides but the row is about another folder, so the resolve this
    // followed says nothing about it.
    expect(stores.projectStore.list().where((p) => p.projectId == stale), isNotEmpty);
  });
}
