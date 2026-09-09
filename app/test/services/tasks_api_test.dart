import 'dart:convert';

import 'package:antgrid/models/task.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _taskJson = {
  'number': 7,
  'title': 'Fix the drawer',
  'body': 'It jitters on resize.',
  'status': 'in_progress',
  'priority': 1,
  'projectId': 'p-1',
  'sortKey': 'm',
  'source': 'local',
  'assignee': {'kind': 'member', 'userId': 'u-1'},
  'labels': [
    {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a', 'projectId': null},
  ],
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-02T10:00:00.000Z',
};

TasksApi _api(MockClient client, {String? cookie = 'session=abc'}) => TasksApi(
  licenseApiUrl: 'https://api.test',
  cookieProvider: () async => cookie,
  httpClient: client,
);

MockClient _answers(String body, int status, {void Function(http.Request)? on}) {
  return MockClient((req) async {
    on?.call(req);
    return http.Response(body, status, headers: const {});
  });
}

/// Runs [call] against a route that refuses with [status] + [code], and returns
/// the exception the client raised.
Future<TaskApiException> _refusalFrom(
  Future<void> Function(TasksApi api) call, {
  required int status,
  String? code,
  Map<String, Object?> extra = const {},
}) async {
  final api = _api(
    _answers(jsonEncode({'error': ?code, ...extra}), status),
  );
  try {
    await call(api);
  } on TaskApiException catch (e) {
    return e;
  }
  fail('expected a TaskApiException for $status/$code');
}

void main() {
  group('requests', () {
    test('list sends one status param per status, plus the cookie', () async {
      late http.Request seen;
      final api = _api(
        _answers('{"tasks":[]}', 200, on: (req) => seen = req),
      );
      await api.listTasks(
        status: {TaskStatus.open, TaskStatus.blocked},
        projectId: 'p-1',
        assignee: 'me',
        limit: 50,
      );
      expect(seen.method, 'GET');
      expect(seen.url.path, '/tasks');
      expect(seen.url.queryParametersAll['status'], ['open', 'blocked']);
      expect(seen.url.queryParameters['projectId'], 'p-1');
      expect(seen.url.queryParameters['assignee'], 'me');
      expect(seen.url.queryParameters['limit'], '50');
      expect(seen.headers['cookie'], 'session=abc');
    });

    test('a task is addressed by number, never by a uuid', () async {
      late http.Request seen;
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen = req,
        ),
      );
      await api.getTask(7);
      expect(seen.url.path, '/tasks/7');
    });

    test('an absent patch field is omitted; an explicit null is sent', () async {
      late http.Request seen;
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen = req,
        ),
      );
      await api.updateTask(7, const TaskPatch(title: 'Renamed'));
      var body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body, {'title': 'Renamed'});
      expect(body.containsKey('assignee'), isFalse);

      await api.updateTask(7, const TaskPatch(assignee: null, priority: null));
      body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body.containsKey('assignee'), isTrue);
      expect(body['assignee'], isNull);
      expect(body.containsKey('priority'), isTrue);
      expect(body['priority'], isNull);
    });

    test('an external assignee is never written back', () async {
      late http.Request seen;
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen = req,
        ),
      );
      await api.updateTask(
        7,
        const TaskPatch(
          assignee: TaskExternalAssignee(
            externalId: 'gh-1',
            login: 'octocat',
          ),
        ),
      );
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['assignee'], isNull);
    });

    test('move names both neighbours by number', () async {
      late http.Request seen;
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen = req,
        ),
      );
      await api.moveTask(7, previousNumber: 3, nextNumber: null);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/tasks/7/move');
      expect(jsonDecode(seen.body), {
        'previousNumber': 3,
        'nextNumber': null,
      });
    });

    test('the label verbs hit their three distinct routes', () async {
      final seen = <String>[];
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen.add('${req.method} ${req.url.path}'),
        ),
      );
      await api.attachLabel(7, 'l-1');
      await api.detachLabel(7, 'l-1');
      await api.setLabels(7, ['l-1', 'l-2']);
      expect(seen, [
        'POST /tasks/7/labels',
        'DELETE /tasks/7/labels/l-1',
        'PUT /tasks/7/labels',
      ]);
    });

    test('a conflict resolve names the field and the side', () async {
      late http.Request seen;
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen = req,
        ),
      );
      await api.resolveConflict(number: 7, field: 'title', take: 'local');
      expect(seen.method, 'POST');
      expect(seen.url.path, '/tasks/7/conflict/resolve');
      expect(jsonDecode(seen.body), {'field': 'title', 'take': 'local'});
    });

    test('no session cookie refuses before any request goes out', () async {
      var called = false;
      final api = _api(
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
        cookie: null,
      );
      await expectLater(
        api.listTasks(),
        throwsA(
          isA<TaskApiException>().having(
            (e) => e.error,
            'error',
            TaskApiError.unauthenticated,
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('responses', () {
    test('a listed task decodes with its labels and assignee', () async {
      final api = _api(
        _answers(jsonEncode({'tasks': [_taskJson]}), 200),
      );
      final tasks = await api.listTasks();
      expect(tasks, hasLength(1));
      final task = tasks.single;
      expect(task.number, 7);
      expect(task.ref, 'ANT-7');
      expect(task.status, TaskStatus.inProgress);
      expect(task.labels.single.name, 'bug');
      expect((task.assignee as TaskMemberAssignee).userId, 'u-1');
    });

    test('a row the app cannot read is dropped, not fatal', () async {
      final api = _api(
        _answers(
          jsonEncode({
            'tasks': [
              _taskJson,
              {'number': 8, 'status': 'invented_status'},
            ],
          }),
          200,
        ),
      );
      expect(await api.listTasks(), hasLength(1));
    });

    test('a body with no task at all is a refusal, not a null', () async {
      final api = _api(_answers('{"ok":true}', 200));
      await expectLater(
        api.getTask(7),
        throwsA(
          isA<TaskApiException>().having(
            (e) => e.error,
            'error',
            TaskApiError.unknown,
          ),
        ),
      );
    });

    test('labels decode from the labels route', () async {
      final api = _api(
        _answers(
          jsonEncode({
            'labels': [
              {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a'},
            ],
          }),
          200,
        ),
      );
      final labels = await api.listLabels();
      expect(labels.single.color, 'd73a4a');
    });
  });

  group('publishing', () {
    // The enforcement point is the API, not the form: the field is always on
    // the wire, so a build that forgot to draw a switch fails the create
    // instead of inheriting the project default.
    test('create always states publish, either way', () async {
      late http.Request seen;
      final api = _api(
        _answers(jsonEncode({'task': _taskJson}), 200, on: (req) => seen = req),
      );
      await api.createTask(title: 'x', publish: false);
      var body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['publish'], isFalse);
      expect(body.containsKey('publishRepoId'), isFalse);

      await api.createTask(title: 'x', publish: true, publishRepoId: 'repo-1');
      body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['publish'], isTrue);
      expect(body['publishRepoId'], 'repo-1');
    });

    test('publish and unlink each take their own route', () async {
      final seen = <String>[];
      final api = _api(
        _answers(
          jsonEncode({'task': _taskJson}),
          200,
          on: (req) => seen.add('${req.method} ${req.url.path} ${req.body}'),
        ),
      );
      await api.publishTask(number: 7, repoId: 'repo-1');
      await api.publishTask(number: 7);
      await api.unlinkTask(number: 7);
      expect(seen[0], 'POST /tasks/7/publish {"repoId":"repo-1"}');
      // Omitted, not null: the server may only infer a destination when the
      // project has exactly one.
      expect(seen[1], 'POST /tasks/7/publish {}');
      expect(seen[2], 'POST /tasks/7/unlink {}');
    });

    test('targets are asked for by project and decode to a slug', () async {
      late http.Request seen;
      final api = _api(
        _answers(
          jsonEncode({
            'targets': [
              {
                'id': 'repo-1',
                'owner': 'antgrid',
                'name': 'antgrid',
                'visibility': 'public',
                'publishNewByDefault': true,
              },
              {'id': 'repo-2', 'owner': 'antgrid'},
            ],
          }),
          200,
          on: (req) => seen = req,
        ),
      );
      final targets = await api.listPublishTargets(projectId: 'p-1');
      expect(seen.method, 'GET');
      expect(seen.url.path, '/tasks/publish-targets');
      expect(seen.url.queryParameters['projectId'], 'p-1');
      // A half-target is dropped rather than rendered as a destination.
      expect(targets, hasLength(1));
      expect(targets.single.slug, 'antgrid/antgrid');
      expect(targets.single.publishNewByDefault, isTrue);
    });

    test('a project with nowhere to publish answers an empty list', () async {
      final api = _api(_answers('{"targets":[]}', 200));
      expect(await api.listPublishTargets(projectId: 'p-1'), isEmpty);
    });
  });

  group('every refusal maps to something a person can act on', () {
    Future<void> list(TasksApi api) => api.listTasks();
    Future<void> create(TasksApi api) => api.createTask(title: 'x', publish: false);
    Future<void> move(TasksApi api) => api.moveTask(7, previousNumber: 1);
    Future<void> attach(TasksApi api) => api.attachLabel(7, 'l-1');
    Future<void> newLabel(TasksApi api) =>
        api.createLabel(name: 'bug', color: 'd73a4a');
    Future<void> resolve(TasksApi api) =>
        api.resolveConflict(number: 7, field: 'title', take: 'local');
    Future<void> publish(TasksApi api) =>
        api.publishTask(number: 7, repoId: 'repo-1');
    Future<void> unlink(TasksApi api) => api.unlinkTask(number: 7);

    final cases = <String, (Future<void> Function(TasksApi), int, String?)>{
      'unauthenticated': (list, 401, 'UNAUTHENTICATED'),
      'noAccount': (list, 403, 'NO_ACCOUNT'),
      'notFound': (list, 404, null),
      'invalidTitle': (create, 400, 'INVALID_TITLE'),
      'projectNotFound': (create, 400, 'PROJECT_NOT_FOUND'),
      'assigneeNotMember': (create, 400, 'ASSIGNEE_NOT_MEMBER'),
      'labelNotFound': (attach, 400, 'LABEL_NOT_FOUND'),
      'labelOutOfScope': (attach, 400, 'LABEL_OUT_OF_SCOPE'),
      'neighboursOutOfOrder': (move, 400, 'NEIGHBOURS_OUT_OF_ORDER'),
      // A second tap, or a resolve that landed on another device first.
      'notConflicted': (resolve, 409, 'NOT_CONFLICTED'),
      'localValueUnreadable': (resolve, 409, 'LOCAL_VALUE_UNREADABLE'),
      'labelsLocalUnsupported': (resolve, 400, 'LABELS_LOCAL_UNSUPPORTED'),
      'invalidLabelName': (newLabel, 400, 'INVALID_LABEL_NAME'),
      'invalidLabelColor': (newLabel, 400, 'INVALID_LABEL_COLOR'),
      'publishNotAvailable': (create, 409, 'PUBLISH_NOT_AVAILABLE'),
      'publishRepoAmbiguous': (create, 409, 'PUBLISH_REPO_AMBIGUOUS'),
      'publishRepoNotFound': (publish, 404, 'PUBLISH_REPO_NOT_FOUND'),
      'alreadyLinked': (publish, 409, 'ALREADY_LINKED'),
      'notLinked': (unlink, 409, 'NOT_LINKED'),
      'badRequest': (create, 400, 'BAD_REQUEST'),
      'server': (list, 500, null),
    };

    for (final entry in cases.entries) {
      test('${entry.key} carries copy, not a status code', () async {
        final (call, status, code) = entry.value;
        final e = await _refusalFrom(call, status: status, code: code);
        expect(e.error.name, entry.key);
        expect(e.message, isNotEmpty);
        expect(e.message, isNot(contains('$status')));
        expect(e.statusCode, status);
      });
    }

    test('ASSIGNEE_NOT_MEMBER carries the userId it refused', () async {
      final e = await _refusalFrom(
        (api) => api.createTask(title: 'x', publish: false),
        status: 400,
        code: 'ASSIGNEE_NOT_MEMBER',
        extra: const {'userId': 'u-9'},
      );
      expect(e.userId, 'u-9');
    });

    test('LABEL_OUT_OF_SCOPE carries the labelId, so one chip can drop', () async {
      final e = await _refusalFrom(
        (api) => api.attachLabel(7, 'l-9'),
        status: 400,
        code: 'LABEL_OUT_OF_SCOPE',
        extra: const {'labelId': 'l-9'},
      );
      expect(e.labelId, 'l-9');
    });

    test('a 404 on a label says label, not task', () async {
      final task = await _refusalFrom((api) => api.getTask(7), status: 404);
      final api = _api(_answers('{}', 404));
      TaskApiException? label;
      try {
        await api.deleteLabel('l-1');
      } on TaskApiException catch (e) {
        label = e;
      }
      expect(task.message, contains('task'));
      expect(label!.message, contains('label'));
    });

    test('only network and server invite an automatic retry', () async {
      final network = await _refusalFrom(
        (api) => api.listTasks(),
        status: 500,
      );
      expect(network.isRetryable, isTrue);
      final refused = await _refusalFrom(
        (api) => api.createTask(title: '', publish: false),
        status: 400,
        code: 'INVALID_TITLE',
      );
      expect(refused.isRetryable, isFalse);
    });

    // The bare 404 arm would otherwise swallow this one and tell the user the
    // TASK is gone, sending them off to look for something that is still there.
    test('a 404 about the repo does not read as a missing task', () async {
      final e = await _refusalFrom(
        (api) => api.publishTask(number: 7, repoId: 'repo-9'),
        status: 404,
        code: 'PUBLISH_REPO_NOT_FOUND',
      );
      expect(e.error, TaskApiError.publishRepoNotFound);
      expect(e.message, isNot(contains('no longer exists')));
      expect(e.message, contains('repo'));
    });

    test('a transport failure reads as the network, not as a refusal', () async {
      final api = _api(
        MockClient((_) async => throw http.ClientException('no route')),
      );
      await expectLater(
        api.listTasks(),
        throwsA(
          isA<TaskApiException>()
              .having((e) => e.error, 'error', TaskApiError.network)
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.message, 'message', contains('internet')),
        ),
      );
    });
  });

  group('listProjects', () {
    test('reads the account list and its display names', () async {
      late Uri asked;
      final api = _api(
        _answers(
          jsonEncode({
            'projects': [
              {
                'id': 'p-1',
                'repoKey': 'github.com/acme/site',
                'displayName': 'Site',
              },
              {'id': 'p-2', 'repoKey': 'github.com/acme/api', 'displayName': ''},
            ],
          }),
          200,
          on: (req) => asked = req.url,
        ),
      );

      final projects = await api.listProjects();
      expect(asked.path, '/account/projects');
      expect(projects.map((p) => p.id), ['p-1', 'p-2']);
      expect(projects.first.displayName, 'Site');
      // A row with no label falls back to its repo rather than rendering blank:
      // the name is the only handle the picker offers.
      expect(projects.last.displayName, 'github.com/acme/api');
    });

    test('an entry with no id is dropped, not the whole list', () async {
      final api = _api(
        _answers(
          jsonEncode({
            'projects': [
              {'repoKey': 'github.com/acme/x', 'displayName': 'X'},
              {
                'id': 'p-2',
                'repoKey': 'github.com/acme/y',
                'displayName': 'Y',
              },
            ],
          }),
          200,
        ),
      );

      expect((await api.listProjects()).map((p) => p.id), ['p-2']);
    });

    test('a body without a projects list is an empty list', () async {
      final api = _api(_answers(jsonEncode({'ok': true}), 200));
      expect(await api.listProjects(), isEmpty);
    });
  });
}
