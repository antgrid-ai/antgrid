// A task names its repository by account project; the sidebar lists folders. The
// join between them is the repoKey, and everything the tasks surface offers when
// the two do not meet (open or clone) hangs off getting that join right.
import 'package:antgrid/models/ab_project.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/drawer_expansion.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/models/task.dart';
import 'package:antgrid/providers/projects.dart';
import 'package:antgrid/providers/task_project_source.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProjects extends ProjectsNotifier {
  _FakeProjects(this._projects);
  final List<AbProject> _projects;

  @override
  List<AbProject> build() => _projects;
}

AbProject _local(String id, {String? repoKey}) => AbProject(
  projectId: id,
  folder: '/work/$id',
  displayName: id,
  hostDeviceUuid: null,
  hostMachineName: '',
  lastOpenedAt: DateTime.utc(2026, 9, 1),
  repoKey: repoKey,
);

const _account = TaskProject(
  id: 'acct-1',
  repoKey: 'github.com/acme/fluentui-blazor-dev-v5',
  displayName: 'fluentui-blazor-dev-v5',
);

ProviderContainer _container(List<AbProject> local) {
  final container = ProviderContainer(
    overrides: [
      projectsProvider.overrideWith(() => _FakeProjects(local)),
      taskProjectsProvider.overrideWith((ref) async => const [_account]),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('clone url is https for a real host and absent for a local: key', () {
    expect(
      cloneUrlForRepoKey('github.com/acme/repo'),
      'https://github.com/acme/repo.git',
    );
    expect(cloneUrlForRepoKey('local:machine/repo'), isNull);
    expect(cloneUrlForRepoKey(''), isNull);
  });

  test('no local folder shares the repoKey → local is null', () async {
    final container = _container([
      _local('antgrid', repoKey: 'github.com/acme/antgrid'),
      _local('learnstack'),
    ]);
    await container.read(taskProjectsProvider.future);

    final source = container.read(taskProjectSourceProvider('acct-1'));
    expect(source, isNotNull);
    expect(source!.local, isNull);
    expect(
      source.cloneUrl,
      'https://github.com/acme/fluentui-blazor-dev-v5.git',
    );
  });

  test(
    'a folder with the same repoKey is the match, whatever it is named',
    () async {
      final container = _container([
        _local('antgrid', repoKey: 'github.com/acme/antgrid'),
        _local(
          'my-checkout',
          repoKey: 'github.com/acme/fluentui-blazor-dev-v5',
        ),
      ]);
      await container.read(taskProjectsProvider.future);

      expect(
        container.read(taskProjectSourceProvider('acct-1'))!.local?.projectId,
        'my-checkout',
      );
    },
  );

  test('a folder whose repoKey is unknown never matches', () async {
    final container = _container([_local('unlearned')]);
    await container.read(taskProjectsProvider.future);

    expect(container.read(taskProjectSourceProvider('acct-1'))!.local, isNull);
  });

  test('a task with no project offers nothing', () async {
    final container = _container([]);
    await container.read(taskProjectsProvider.future);

    expect(container.read(taskProjectSourceProvider(null)), isNull);
    expect(container.read(taskProjectSourceProvider('unknown')), isNull);
  });

  group('a copy of the repository on another machine', () {
    const machine = 'machine-uuid-1';
    const repoKey = 'github.com/acme/fluentui-blazor-dev-v5';

    ProviderContainer withMachine({
      Set<String> expanded = const {machine},
      String advertisedKey = repoKey,
    }) {
      final container = ProviderContainer(
        overrides: [
          projectsProvider.overrideWith(() => _FakeProjects(const [])),
          taskProjectsProvider.overrideWith((ref) async => const [_account]),
          controlPlaneStateProvider.overrideWith(
            (ref, id) => Stream.value(
              ControlPlaneState(
                projects: [
                  AdvertisedProject(
                    projectId: 'proj-9',
                    label: 'fluentui',
                    running: true,
                    repoKey: advertisedKey,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(expandedDrawerIdsProvider.notifier).state = expanded;
      return container;
    }

    /// Subscribes the way the task screen does, then lets both the project list
    /// and the machine's advert arrive.
    Future<void> settle(ProviderContainer container) async {
      container.listen(taskProjectSourceProvider('acct-1'), (_, _) {});
      await container.read(taskProjectsProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('an expanded machine holding the repo makes it reachable', () async {
      final container = withMachine();
      await settle(container);

      final source = container.read(taskProjectSourceProvider('acct-1'))!;
      expect(source.local, isNull);
      expect(source.reachable, isTrue);
      expect(source.targetIds, ['$machine.proj-9']);
      expect(source.remote.single.label, 'fluentui');
    });

    test('a machine that is not open is never asked', () async {
      final container = withMachine(expanded: const {});
      await settle(container);

      final source = container.read(taskProjectSourceProvider('acct-1'))!;
      expect(source.remote, isEmpty);
      expect(source.reachable, isFalse);
    });

    test(
      'the focused remote project counts even if its row is collapsed',
      () async {
        final container = withMachine(expanded: const {});
        container
            .read(selectedTargetProvider.notifier)
            .set(
              const RemoteProject(machineUuid: machine, projectId: 'proj-9'),
            );
        await settle(container);

        expect(container.read(taskProjectSourceProvider('acct-1'))!.targetIds, [
          '$machine.proj-9',
        ]);
      },
    );

    test('a different repository on that machine does not match', () async {
      final container = withMachine(advertisedKey: 'github.com/acme/other');
      await settle(container);

      expect(
        container.read(taskProjectSourceProvider('acct-1'))!.remote,
        isEmpty,
      );
    });
  });
}
