import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/task.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/provider_retry.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/widgets/tasks/task_row_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _taskJson = {
  'number': 42,
  'title': 'Fix the drawer',
  'body': '',
  'status': 'open',
  'sortKey': 'm',
  'source': 'local',
  'assignee': null,
  'labels': <Object?>[],
  'createdBy': 'u-owner',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
};

void main() {
  // On a team the member list starts with whoever joined first — usually the
  // owner — so "me" must come from the signed-in identity, never list order.
  testWidgets('Assign to me assigns the signed-in user, not the first member', (
    tester,
  ) async {
    final patches = <Object?>[];
    final container = ProviderContainer(
      retry: noProviderRetry,
      overrides: [
        tasksApiProvider.overrideWithValue(
          TasksApi(
            licenseApiUrl: 'https://api.test',
            cookieProvider: () async => 'session=abc',
            httpClient: MockClient((req) async {
              if (req.url.path == '/tasks/members') {
                return http.Response(
                  jsonEncode({
                    'members': [
                      {'userId': 'u-owner', 'name': 'Owner', 'email': 'o@t'},
                      {'userId': 'u-me', 'name': 'Me', 'email': 'me@t'},
                    ],
                  }),
                  200,
                );
              }
              if (req.method == 'PATCH') {
                patches.add(jsonDecode(req.body));
                return http.Response(jsonEncode({'task': _taskJson}), 200);
              }
              if (req.method == 'GET' && req.url.path == '/tasks') {
                return http.Response(
                  jsonEncode({
                    'tasks': [_taskJson],
                  }),
                  200,
                );
              }
              return http.Response(jsonEncode({'task': _taskJson}), 200);
            }),
          ),
        ),
        currentUserProvider.overrideWith(
          (_) async => CurrentUser(userId: 'u-me', email: 'me@t'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(taskAssigneeCandidatesProvider, (_, _) {});
    final task = Task.fromJson(_taskJson)!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                ref.watch(taskListProvider);
                return TextButton(
                  onPressed: () => showTaskRowActions(
                    context,
                    ref,
                    task: task,
                    neighbours: [task],
                  ),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await container.read(taskMembersProvider.future);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign to me'));
    await tester.pumpAndSettle();

    expect(patches, [
      {
        'assignee': {'kind': 'member', 'userId': 'u-me'},
      },
    ]);
  });
}
