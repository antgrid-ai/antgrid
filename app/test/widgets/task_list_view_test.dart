import 'dart:async';
import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/agent_work_status.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/widgets/tasks/task_list_view.dart';
import 'package:antgrid/widgets/tasks/task_provenance_view.dart';
import 'package:antgrid/widgets/tasks/task_row.dart';
import 'package:antgrid/widgets/tasks/task_status_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _task({
  int number = 1,
  String title = 'Fix the drawer',
  String status = 'open',
  List<Map<String, Object?>> labels = const [],
  Object? assignee,
  List<Map<String, Object?>> otherAssignees = const [],
  String sortKey = 'm',
  String source = 'local',
  String? externalProvider,
  String? externalUrl,
  String? syncState,
}) => {
  'number': number,
  'title': title,
  'body': '',
  'status': status,
  'sortKey': sortKey,
  'source': source,
  'externalProvider': externalProvider,
  'externalUrl': externalUrl,
  'syncState': syncState,
  'assignee': assignee,
  'otherAssignees': otherAssignees,
  'labels': labels,
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
};

/// A client that answers `/tasks` with [tasks] and `/labels` with [labels].
MockClient _serving({
  List<Map<String, Object?>> tasks = const [],
  List<Map<String, Object?>> labels = const [],
}) {
  return MockClient((req) async {
    if (req.url.path == '/labels') {
      return http.Response(jsonEncode({'labels': labels}), 200);
    }
    return http.Response(jsonEncode({'tasks': tasks}), 200);
  });
}

ProviderContainer _container({
  required MockClient client,
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      tasksApiProvider.overrideWithValue(
        TasksApi(
          licenseApiUrl: 'https://api.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Widget child = const TaskListView(),
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('a fetch in flight shows loading, never the empty state', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    final container = _container(client: MockClient((_) => gate.future));
    await _pump(tester, container);
    await tester.pump();

    expect(find.text('Loading tasks…'), findsOneWidget);
    expect(find.text('Nothing assigned to you'), findsNothing);

    gate.complete(http.Response('{"tasks":[]}', 200));
    await tester.pumpAndSettle();
  });

  testWidgets('an empty scope offers the way out of it', (tester) async {
    final container = _container(client: _serving());
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('No tasks yet'), findsOneWidget);
    expect(find.text('New task'), findsOneWidget);

    container.read(taskFilterProvider.notifier).setScope(TaskScope.mine);
    await tester.pumpAndSettle();

    expect(find.text('Nothing assigned to you'), findsOneWidget);
    expect(find.text('Browse unassigned'), findsOneWidget);
  });

  testWidgets('a refusal renders its copy, not a status code', (tester) async {
    final container = _container(
      client: MockClient(
        (_) async => http.Response('{"error":"NO_ACCOUNT"}', 403),
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('belongs to no Antgrid account'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('403'), findsNothing);
  });

  testWidgets('the offline case names the network, not the machines', (
    tester,
  ) async {
    final container = _container(
      client: MockClient((_) async => throw http.ClientException('no route')),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(
      find.text('The task list needs the internet, not a running machine.'),
      findsOneWidget,
    );
  });

  testWidgets('rows render the ref, the title and their labels', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 12,
            title: 'Fix the drawer',
            assignee: const {'kind': 'member', 'userId': 'u-1'},
            labels: const [
              {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a'},
              {'id': 'l-2', 'name': 'ui', 'color': '0e8a16'},
            ],
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(TaskRow), findsOneWidget);
    expect(find.text('ANT-12'), findsOneWidget);
    expect(find.text('Fix the drawer'), findsOneWidget);
    expect(find.text('bug'), findsOneWidget);
    expect(find.text('ui'), findsOneWidget);
  });

  testWidgets('a third label collapses to a count rather than wrapping', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            assignee: const {'kind': 'member', 'userId': 'u-1'},
            labels: const [
              {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a'},
              {'id': 'l-2', 'name': 'ui', 'color': '0e8a16'},
              {'id': 'l-3', 'name': 'perf', 'color': 'ffffff'},
            ],
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('+1'), findsOneWidget);
    expect(find.text('perf'), findsNothing);
  });

  // GitHub holds up to ten assignees and Antgrid keeps one, so the row has to
  // admit the others exist without spending the line on them.
  testWidgets('co-assignees collapse to a count beside the assignee', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 11,
            source: 'github',
            externalProvider: 'github',
            assignee: const {'kind': 'member', 'userId': 'u-1'},
            otherAssignees: const [
              {'kind': 'external', 'externalId': '5', 'login': 'octocat'},
              {'kind': 'member', 'userId': 'u-2'},
            ],
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.text('+2'), findsOneWidget);
    // Naming them is the detail sheet's job; the row would stop scanning.
    expect(find.text('@octocat'), findsNothing);
  });

  testWidgets('a task with no co-assignees shows no count', (tester) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 11,
            assignee: const {'kind': 'member', 'userId': 'u-1'},
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(TaskRow), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });

  // Provenance is the row half of the untrusted-body mitigation: whose words a
  // task carries has to be answerable by scanning, before anything is opened.
  testWidgets('a task written in Antgrid carries no provenance mark', (
    tester,
  ) async {
    final container = _container(client: _serving(tasks: [_task(number: 7)]));
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(TaskRow), findsOneWidget);
    expect(find.byType(TaskProvenanceMark), findsNothing);
  });

  testWidgets('an imported task is marked, and only by a glyph', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 8,
            source: 'github',
            externalProvider: 'github',
            syncState: 'synced',
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(TaskProvenanceMark), findsOneWidget);
    expect(find.byTooltip('Imported from GitHub'), findsOneWidget);
    // A sentence on the row would cost the line the list is scanned by.
    expect(find.textContaining('Imported from'), findsNothing);
  });

  testWidgets('a sync conflict is distinguishable from a plain import', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 9,
            source: 'github',
            externalProvider: 'github',
            syncState: 'conflict',
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    // The mark is not a control — the row already opens the task — so the
    // tooltip has to name where the two versions and the way out of them are.
    expect(
      find.byTooltip(
        'Imported from GitHub · edited in both places — open the task to '
        'settle it',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unlinked task keeps its provenance and says it is dropped', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 10,
            source: 'github',
            externalProvider: 'github',
            syncState: 'unlinked',
          ),
        ],
      ),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('Imported from GitHub · no longer linked'),
      findsOneWidget,
    );
  });

  testWidgets('an agent blocked on a person says so on the row', (
    tester,
  ) async {
    final container = _container(
      client: _serving(
        tasks: [
          _task(
            number: 5,
            status: 'in_progress',
            assignee: const {'kind': 'member', 'userId': 'u-1'},
          ),
        ],
      ),
      overrides: [
        taskRunPresenceProvider.overrideWithValue(const {
          5: TaskRunPresence(
            status: AgentWorkStatus.attention,
            sessionName: 'drawer-fix',
          ),
        }),
      ],
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    expect(find.byType(TaskRunMark), findsOneWidget);
    final mark = tester.widget<TaskRunMark>(find.byType(TaskRunMark));
    expect(mark.run.status, AgentWorkStatus.attention);
  });

  testWidgets('the attention mark is warning-toned and spells out the wait', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: const Scaffold(
          body: TaskRunMark(
            run: TaskRunPresence(status: AgentWorkStatus.attention),
            showLabel: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Waiting on you'), findsOneWidget);
  });

  testWidgets('a working agent does not borrow the attention wording', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: const Scaffold(
          body: TaskRunMark(
            run: TaskRunPresence(status: AgentWorkStatus.working),
            showLabel: true,
          ),
        ),
      ),
    );
    // Not pumpAndSettle: the live states pulse forever, which is the point.
    await tester.pump();
    expect(find.text('Working'), findsOneWidget);
    expect(find.text('Waiting on you'), findsNothing);
  });

  testWidgets('the label filter narrows without refetching', (tester) async {
    var listCalls = 0;
    final container = _container(
      client: MockClient((req) async {
        if (req.url.path == '/labels') {
          return http.Response(
            jsonEncode({
              'labels': [
                {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a'},
              ],
            }),
            200,
          );
        }
        // The filter bar's repo picker (`_RepoFilterChip`) watches this on
        // every build too — excluded so `listCalls` still counts only the
        // fetch this test is actually pinning the count of.
        if (req.url.path == '/account/projects') {
          return http.Response(jsonEncode({'projects': []}), 200);
        }
        listCalls++;
        return http.Response(
          jsonEncode({
            'tasks': [
              _task(
                number: 1,
                title: 'Labelled',
                assignee: const {'kind': 'member', 'userId': 'u-1'},
                labels: const [
                  {'id': 'l-1', 'name': 'bug', 'color': 'd73a4a'},
                ],
              ),
              _task(
                number: 2,
                title: 'Bare',
                assignee: const {'kind': 'member', 'userId': 'u-1'},
              ),
            ],
          }),
          200,
        );
      }),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();
    expect(find.byType(TaskRow), findsNWidgets(2));
    expect(listCalls, 1);

    container.read(taskFilterProvider.notifier).toggleLabel('l-1');
    await tester.pumpAndSettle();

    expect(find.text('Labelled'), findsOneWidget);
    expect(find.text('Bare'), findsNothing);
    expect(listCalls, 1);
  });

  testWidgets('a mutation refusal reverts and says why, with a retry', (
    tester,
  ) async {
    var patched = false;
    final container = _container(
      client: MockClient((req) async {
        if (req.method == 'PATCH') {
          patched = true;
          return http.Response('{"error":"INVALID_TITLE"}', 400);
        }
        if (req.url.path == '/labels') {
          return http.Response('{"labels":[]}', 200);
        }
        return http.Response(
          jsonEncode({
            'tasks': [
              _task(
                number: 3,
                title: 'Original',
                assignee: const {'kind': 'member', 'userId': 'u-1'},
              ),
            ],
          }),
          200,
        );
      }),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    await container
        .read(taskListProvider.notifier)
        .setTitle(3, 'Renamed optimistically');
    await tester.pumpAndSettle();

    expect(patched, isTrue);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Renamed optimistically'), findsNothing);
    expect(find.textContaining('A task needs a title'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  // Rolling back by restoring a whole list snapshot would undo the edit that
  // worked along with the one that did not — two rows are two writes.
  testWidgets('a refusal on one task leaves an edit on another task standing', (
    tester,
  ) async {
    final container = _container(
      client: MockClient((req) async {
        if (req.method == 'PATCH') {
          return req.url.path.endsWith('/5')
              ? http.Response('{"error":"INVALID_TITLE"}', 400)
              : http.Response(
                  jsonEncode({'task': _task(number: 4, title: 'Four renamed')}),
                  200,
                );
        }
        if (req.url.path == '/labels') {
          return http.Response('{"labels":[]}', 200);
        }
        return http.Response(
          jsonEncode({
            'tasks': [
              _task(number: 4, title: 'Four'),
              _task(number: 5, title: 'Five'),
            ],
          }),
          200,
        );
      }),
    );
    await _pump(tester, container);
    await tester.pumpAndSettle();

    final notifier = container.read(taskListProvider.notifier);
    await Future.wait([
      notifier.setTitle(4, 'Four renamed'),
      notifier.setTitle(5, 'Five renamed'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Four renamed'), findsOneWidget);
    expect(find.text('Five'), findsOneWidget);
    expect(find.text('Five renamed'), findsNothing);
  });
}
