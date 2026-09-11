// The node hangs off every project row in the drawer, so its ABSENT cases carry
// as much weight as its present one: three different "nothing to say" states
// must all render nothing rather than an empty shelf on every row.
import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/widgets/project_tasks_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _task({
  required int number,
  String title = 'Fix the drawer',
  String status = 'open',
  String? projectId = 'p-1',
  String sortKey = 'm',
}) => {
  'number': number,
  'title': title,
  'body': '',
  'status': status,
  'sortKey': sortKey,
  'source': 'local',
  'projectId': projectId,
  'assignee': null,
  'otherAssignees': const [],
  'labels': const [],
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
};

ProviderContainer _container({
  required List<Map<String, Object?>> tasks,
  List<Map<String, Object?>> projects = const [
    {'id': 'p-1', 'repoKey': 'github.com/acme/site', 'displayName': 'Site'},
  ],
}) {
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
            if (req.url.path.endsWith('/projects')) {
              return http.Response(jsonEncode({'projects': projects}), 200);
            }
            return http.Response(jsonEncode({'tasks': tasks}), 200);
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  String? repoKey = 'github.com/acme/site',
}) async {
  await container.read(taskProjectsProvider.future);
  await container.read(taskListProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: ProjectTasksNode(repoKey: repoKey),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows every open task immediately, with no tap to expand', (
    tester,
  ) async {
    final container = _container(
      tasks: [_task(number: 1), _task(number: 2), _task(number: 3)],
    );
    await _pump(tester, container);

    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // Always open: a task outlives any session and is worth seeing without a
    // click, so there is no collapsed state to expand out of.
    expect(find.text('Fix the drawer'), findsNWidgets(3));
  });

  testWidgets('lists only the project the tasks are filed against', (
    tester,
  ) async {
    final container = _container(
      tasks: [
        _task(number: 1, title: 'Drawer bug'),
        _task(number: 2, title: 'Other project', projectId: 'p-2'),
      ],
    );
    await _pump(tester, container);

    expect(find.text('Drawer bug'), findsOneWidget);
    expect(find.text('ANT-1'), findsOneWidget);
    expect(
      find.text('Other project'),
      findsNothing,
      reason: 'a node must never show another project’s work',
    );
  });

  testWidgets('a folder with no repository identity renders nothing', (
    tester,
  ) async {
    final container = _container(tasks: [_task(number: 1)]);
    await _pump(tester, container, repoKey: null);
    expect(find.text('Tasks'), findsNothing);
  });

  testWidgets('a repository the account has no project for renders nothing', (
    tester,
  ) async {
    // Not the same as having no tasks: the binding is reported when a project
    // opens, so an unopened folder simply has nowhere to join to.
    final container = _container(tasks: [_task(number: 1)], projects: const []);
    await _pump(tester, container);
    expect(find.text('Tasks'), findsNothing);
  });

  testWidgets('a project whose open list is empty renders nothing', (
    tester,
  ) async {
    final container = _container(
      tasks: [
        _task(number: 1, status: 'done'),
        _task(number: 2, status: 'cancelled'),
      ],
    );
    await _pump(tester, container);
    expect(find.text('Tasks'), findsNothing);
  });
}
