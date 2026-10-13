import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/task.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/provider_retry.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/widgets/tasks/task_comments_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _task = Task.fromJson({
  'number': 42,
  'title': 'Fix the drawer',
  'body': '',
  'status': 'open',
  'sortKey': 'm',
  'source': 'local',
  'labels': const <Object?>[],
  'createdBy': 'u-1',
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
})!;

Map<String, Object?> _comment(
  String id,
  String body, {
  Map<String, Object?>? author = const {
    'kind': 'member',
    'userId': 'u-1',
    'name': 'Me Myself',
  },
  bool imported = false,
}) => {
  'id': id,
  'author': author,
  'body': body,
  'imported': imported,
  'createdAt': '2026-08-01T10:00:00.000Z',
  'updatedAt': '2026-08-01T10:00:00.000Z',
};

Future<void> _pump(WidgetTester tester, MockClient client) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    retry: noProviderRetry,
    overrides: [
      tasksApiProvider.overrideWithValue(
        TasksApi(
          licenseApiUrl: 'https://api.test',
          cookieProvider: () async => 'session=abc',
          httpClient: client,
        ),
      ),
      currentUserProvider.overrideWith(
        (_) async => CurrentUser(userId: 'u-1', email: 'me@antgrid.ai'),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: SingleChildScrollView(child: TaskCommentsSection(task: _task)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty thread says so and offers the composer', (
    tester,
  ) async {
    await _pump(
      tester,
      MockClient((_) async => http.Response('{"comments":[]}', 200)),
    );
    expect(find.text('No comments yet.'), findsOneWidget);
    expect(find.text('Comment'), findsOneWidget);
  });

  testWidgets('posting appends the server copy and clears the draft', (
    tester,
  ) async {
    final posted = <Object?>[];
    await _pump(
      tester,
      MockClient((req) async {
        if (req.method == 'POST') {
          final body = (jsonDecode(req.body) as Map)['body'] as String;
          posted.add(body);
          return http.Response(
            jsonEncode({'comment': _comment('c-9', body)}),
            201,
          );
        }
        return http.Response('{"comments":[]}', 200);
      }),
    );

    await tester.enterText(find.byType(TextField), 'Shipping it today.');
    await tester.pump();
    await tester.tap(find.text('Comment'));
    await tester.pumpAndSettle();

    expect(posted, ['Shipping it today.']);
    expect(find.text('Shipping it today.'), findsOneWidget);
    expect(find.text('No comments yet.'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('only my own local comment offers edit and delete', (
    tester,
  ) async {
    await _pump(
      tester,
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'comments': [
              _comment('c-1', 'Mine.'),
              _comment(
                'c-2',
                'A teammate.',
                author: const {
                  'kind': 'member',
                  'userId': 'u-2',
                  'name': 'Teammate',
                },
              ),
              _comment(
                'c-3',
                'From the issue.',
                author: const {'kind': 'external', 'login': 'octocat'},
                imported: true,
              ),
            ],
          }),
          200,
        ),
      ),
    );

    expect(find.text('Me Myself'), findsOneWidget);
    expect(find.text('Teammate'), findsOneWidget);
    expect(find.text('@octocat'), findsOneWidget);
    expect(find.text('from GitHub'), findsOneWidget);
    expect(find.byTooltip('Edit comment'), findsOneWidget);
    expect(find.byTooltip('Delete comment'), findsOneWidget);
  });

  testWidgets('delete asks first, then removes the comment', (tester) async {
    final deletes = <String>[];
    await _pump(
      tester,
      MockClient((req) async {
        if (req.method == 'DELETE') {
          deletes.add(req.url.path);
          return http.Response('{"ok":true}', 200);
        }
        return http.Response(
          jsonEncode({
            'comments': [_comment('c-1', 'Mine.')],
          }),
          200,
        );
      }),
    );

    await tester.tap(find.byTooltip('Delete comment'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this comment?'), findsOneWidget);
    expect(deletes, isEmpty);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deletes, ['/tasks/42/comments/c-1']);
    expect(find.text('Mine.'), findsNothing);
    expect(find.text('No comments yet.'), findsOneWidget);
  });
}
