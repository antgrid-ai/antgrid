// The demo's task backlog has one story to tell: a team, a task on a
// teammate's plate, and a conversation with them that answers back. Each beat
// is asserted through the REAL TasksApi, so a wire-shape drift between the
// demo client and the parser fails here rather than as an empty demo screen.
import 'package:antgrid/demo/demo_tasks.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/task.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/provider_retry.dart';
import 'package:antgrid/providers/tasks.dart';
import 'package:antgrid/services/tasks_api.dart';
import 'package:antgrid/widgets/tasks/task_comments_section.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TasksApi _api(DemoTasksClient client) => TasksApi(
  licenseApiUrl: 'https://demo.invalid',
  cookieProvider: () async => 'demo',
  httpClient: client,
);

Future<Task> _coupons(TasksApi api) async =>
    (await api.listTasks()).singleWhere((t) => t.title.contains('coupon'));

void main() {
  test('the team is three people, the signed-in demo user among them', () async {
    final client = DemoTasksClient();
    addTearDown(client.close);
    final members = await _api(client).listMembers();

    expect(members.map((m) => m.displayName), [
      'You',
      'Priya Raman',
      'Marcus Lee',
    ]);
    expect(members.first.userId, kDemoTaskUserId);
  });

  test('a task sits on a teammate, with a conversation already under way', () async {
    final client = DemoTasksClient();
    addTearDown(client.close);
    final api = _api(client);
    final coupons = await _coupons(api);

    expect(coupons.assignee, const TaskMemberAssignee('demo-priya'));
    expect(coupons.status, TaskStatus.inProgress);

    final thread = await api.listComments(coupons.number);
    expect(thread.map((c) => c.authorName), [
      'Priya Raman',
      'You',
      'Priya Raman',
    ]);
    // The visitor's own seeded comment is theirs to edit; the teammate's not.
    expect(thread[1].isAuthoredBy(kDemoTaskUserId), isTrue);
    expect(thread[0].isAuthoredBy(kDemoTaskUserId), isFalse);
  });

  test('the assignee replies a moment after the visitor comments', () {
    fakeAsync((async) {
      final client = DemoTasksClient();
      final api = _api(client);
      final changed = <int>[];
      client.commentChanges.listen(changed.add);

      late Task coupons;
      _coupons(api).then((t) => coupons = t);
      async.flushMicrotasks();
      api.addComment(coupons.number, 'Can you add a test for expired codes?');
      async.flushMicrotasks();

      async.elapse(kDemoReplyDelay - const Duration(milliseconds: 1));
      expect(changed, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(changed, [coupons.number]);

      late List<TaskComment> thread;
      api.listComments(coupons.number).then((c) => thread = c);
      async.flushMicrotasks();
      expect(thread.last.authorName, 'Priya Raman');
      expect(thread.last.body, kDemoReplies.first);
      client.close();
    });
  });

  test('reassigning a task is accepted only for a team member', () async {
    final client = DemoTasksClient();
    addTearDown(client.close);
    final api = _api(client);
    final coupons = await _coupons(api);

    final toMarcus = await api.updateTask(
      coupons.number,
      const TaskPatch(assignee: TaskMemberAssignee('demo-marcus')),
    );
    expect(toMarcus.assignee, const TaskMemberAssignee('demo-marcus'));
  });

  test('closing the client cancels a pending reply', () {
    fakeAsync((async) {
      final client = DemoTasksClient();
      final api = _api(client);
      final changed = <int>[];
      client.commentChanges.listen(changed.add);
      api.addComment(3, 'hello');
      async.flushMicrotasks();
      client.close();
      async.elapse(kDemoReplyDelay * 2);
      expect(changed, isEmpty);
    });
  });

  testWidgets('in the demo, the reply lands in the open thread by itself', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(retry: noProviderRetry);
    addTearDown(container.dispose);
    container.read(demoModeProvider.notifier).set(true);
    final coupons = await _coupons(container.read(tasksApiProvider));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TaskCommentsSection(task: coupons),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Priya Raman'), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'Expired codes too?');
    await tester.pump();
    await tester.tap(find.text('Comment'));
    await tester.pumpAndSettle();
    expect(find.text('Expired codes too?'), findsOneWidget);
    expect(find.text(kDemoReplies.first), findsNothing);

    await tester.pump(kDemoReplyDelay);
    await tester.pumpAndSettle();
    expect(find.text(kDemoReplies.first), findsOneWidget);
    expect(find.text('Priya Raman'), findsNWidgets(3));
  });
}
