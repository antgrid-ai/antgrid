// The drawer's per-project task nodes partition the SAME store the tasks
// surface reads. That only works while two things hold, and neither is
// self-evident from the call sites: the fetch stays wide enough that narrowing
// the surface cannot empty a node, and the narrowing the server stopped doing
// is actually done on the client instead. Both are pinned here.
import 'dart:convert';

import 'package:antgrid/models/task.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _task({
  required int number,
  String status = 'open',
  String? projectId,
  Object? assignee,
  String sortKey = 'm',
}) => {
  'number': number,
  'title': 'Task $number',
  'body': '',
  'status': status,
  'sortKey': sortKey,
  'source': 'local',
  'projectId': projectId,
  'assignee': assignee,
  'otherAssignees': const [],
  'labels': const [],
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
};

void main() {
  group('TaskFilter.serverQuery stays wide enough for the drawer', () {
    test('the open set is fetched whatever the scope narrows to', () {
      // `mine` and `running` both narrow the SURFACE hard. If either reached
      // the wire, every drawer node would empty the moment one was picked.
      for (final scope in TaskScope.values) {
        final q = TaskFilter(scope: scope).serverQuery;
        expect(
          q.statuses.containsAll(kOpenStatuses),
          isTrue,
          reason: 'scope $scope must still fetch every open task',
        );
        expect(q.assignee, isNull, reason: 'scope $scope narrowed by assignee');
        expect(q.projectId, isNull, reason: 'scope $scope narrowed by project');
      }
    });

    test('a closed chip widens the fetch, and only while it is held', () {
      // Task history is unbounded — it must never be pulled by default.
      expect(
        const TaskFilter().serverQuery.statuses.contains(TaskStatus.done),
        isFalse,
      );
      final withDone = const TaskFilter(
        scope: TaskScope.done,
      ).serverQuery.statuses;
      expect(withDone.contains(TaskStatus.done), isTrue);
      expect(withDone.containsAll(kOpenStatuses), isTrue);
    });

    test('a filter that only narrows does not refetch', () {
      // TaskQuery has value equality and drives the fetch; two filters that
      // differ only in what the client resolves must compare equal.
      expect(
        const TaskFilter(scope: TaskScope.allOpen).serverQuery,
        const TaskFilter(scope: TaskScope.mine).serverQuery,
      );
      expect(
        const TaskFilter().serverQuery,
        const TaskFilter(projectId: 'p-1').serverQuery,
      );
    });
  });

  group('the join and the partition', () {
    ProviderContainer containerFor(MockClient client) {
      final container = ProviderContainer(
        overrides: [
          tasksApiProvider.overrideWithValue(
            TasksApi(
              licenseApiUrl: 'https://api.test',
              cookieProvider: () async => 'session=abc',
              httpClient: client,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'repoKey resolves to the account project a task is filed against',
      () async {
        final container = containerFor(
          MockClient(
            (req) async => http.Response(
              jsonEncode({
                'projects': [
                  {
                    'id': 'p-1',
                    'repoKey': 'github.com/acme/site',
                    'displayName': 'Site',
                  },
                  // A row that arrived without a key must not become a `''` entry
                  // that every keyless project row would then match on.
                  {'id': 'p-2', 'repoKey': '', 'displayName': 'Nameless'},
                ],
              }),
              200,
            ),
          ),
        );

        await container.read(taskProjectsProvider.future);
        final map = container.read(taskProjectIdByRepoKeyProvider);
        expect(map['github.com/acme/site'], 'p-1');
        expect(map.containsKey(''), isFalse);
      },
    );

    test('a project partition holds its own OPEN tasks only', () async {
      final container = containerFor(
        MockClient((req) async {
          if (req.url.path == '/labels') {
            return http.Response(jsonEncode({'labels': []}), 200);
          }
          return http.Response(
            jsonEncode({
              'tasks': [
                _task(number: 1, projectId: 'p-1', sortKey: 'a'),
                _task(number: 2, projectId: 'p-1', sortKey: 'b'),
                _task(number: 3, projectId: 'p-2'),
                _task(number: 4, projectId: 'p-1', status: 'done'),
                _task(number: 5, projectId: 'p-1', status: 'cancelled'),
                // Filed against no project: it belongs to no node.
                _task(number: 6),
              ],
            }),
            200,
          );
        }),
      );

      await container.read(taskListProvider.future);
      final rows = container.read(openTasksForProjectProvider('p-1'));
      expect(rows.map((t) => t.number), [1, 2]);
      expect(
        container.read(openTasksForProjectProvider('p-2')).single.number,
        3,
      );
      expect(container.read(openTasksForProjectProvider('p-9')), isEmpty);
    });

    test('narrowing the surface leaves the drawer partition whole', () async {
      // The regression this whole design exists to prevent: the surface and the
      // node share one store, so a surface filter must never reach the node.
      final container = containerFor(
        MockClient((req) async {
          if (req.url.path == '/labels') {
            return http.Response(jsonEncode({'labels': []}), 200);
          }
          return http.Response(
            jsonEncode({
              'tasks': [
                _task(number: 1, projectId: 'p-1'),
                _task(
                  number: 2,
                  projectId: 'p-1',
                  assignee: {'kind': 'member', 'userId': 'u-other'},
                ),
              ],
            }),
            200,
          );
        }),
      );

      await container.read(taskListProvider.future);
      expect(container.read(openTasksForProjectProvider('p-1')), hasLength(2));

      container.read(taskFilterProvider.notifier).setScope(TaskScope.mine);
      await container.read(taskListProvider.future);

      expect(
        container.read(openTasksForProjectProvider('p-1')),
        hasLength(2),
        reason: 'the surface picking "Mine" must not empty a project node',
      );
    });
  });

  group('the narrowing the server stopped doing now runs on the client', () {
    ProviderContainer surfaceWith(List<Map<String, Object?>> tasks) {
      final container = ProviderContainer(
        overrides: [
          tasksApiProvider.overrideWithValue(
            TasksApi(
              licenseApiUrl: 'https://api.test',
              cookieProvider: () async => 'session=abc',
              httpClient: MockClient((req) async {
                if (req.url.path == '/labels') {
                  return http.Response(jsonEncode({'labels': []}), 200);
                }
                return http.Response(jsonEncode({'tasks': tasks}), 200);
              }),
            ),
          ),
          currentUserProvider.overrideWith(
            (_) async => CurrentUser(userId: 'u-me', email: 'me@test'),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'scope "mine" keeps only the tasks assigned to the signed-in user',
      () async {
        final container = surfaceWith([
          _task(number: 1, assignee: {'kind': 'member', 'userId': 'u-me'}),
          _task(number: 2, assignee: {'kind': 'member', 'userId': 'u-other'}),
          _task(number: 3),
        ]);
        await container.read(currentUserProvider.future);
        await container.read(taskListProvider.future);

        container.read(taskFilterProvider.notifier).setScope(TaskScope.mine);
        expect(
          container.read(visibleTasksProvider).value!.map((t) => t.number),
          [1],
        );
      },
    );

    test(
      'a status chip narrows the rendered list, not just the fetch',
      () async {
        final container = surfaceWith([
          _task(number: 1, status: 'open', sortKey: 'a'),
          _task(number: 2, status: 'in_progress', sortKey: 'b'),
        ]);
        await container.read(currentUserProvider.future);
        await container.read(taskListProvider.future);

        container
            .read(taskFilterProvider.notifier)
            .toggleStatus(TaskStatus.inProgress);
        expect(
          container.read(visibleTasksProvider).value!.map((t) => t.number),
          [2],
        );
      },
    );

    test('a project filter narrows the rendered list', () async {
      final container = surfaceWith([
        _task(number: 1, projectId: 'p-1', sortKey: 'a'),
        _task(number: 2, projectId: 'p-2', sortKey: 'b'),
      ]);
      await container.read(currentUserProvider.future);
      await container.read(taskListProvider.future);

      container.read(taskFilterProvider.notifier).setProject('p-2');
      expect(container.read(visibleTasksProvider).value!.map((t) => t.number), [
        2,
      ]);
    });
  });
}
