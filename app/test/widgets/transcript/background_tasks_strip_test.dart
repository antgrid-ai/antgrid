import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/background_tasks_strip.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

const _task = AgentBackgroundTask(
  taskId: 'task-1',
  kind: 'shell',
  title: 'bun dev',
  status: 'running',
);

void main() {
  testWidgets('renders nothing when there are no tasks', (tester) async {
    await tester.pumpWidget(
      _wrap(BackgroundTasksStrip(tasks: const [], onStop: (_) {})),
    );
    expect(find.text('1 background task'), findsNothing);
  });

  testWidgets('shows a count summary and expands to task rows', (tester) async {
    await tester.pumpWidget(
      _wrap(BackgroundTasksStrip(tasks: const [_task], onStop: (_) {})),
    );
    expect(find.text('1 background task'), findsOneWidget);
    expect(find.text('bun dev'), findsNothing);

    await tester.tap(find.text('1 background task'));
    await tester.pump();
    expect(find.text('bun dev'), findsOneWidget);
  });

  testWidgets('stop button fires onStop with the task', (tester) async {
    final stopped = <String>[];
    await tester.pumpWidget(
      _wrap(
        BackgroundTasksStrip(
          tasks: const [_task],
          onStop: (t) => stopped.add(t.taskId),
        ),
      ),
    );
    await tester.tap(find.text('1 background task'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop task'));
    expect(stopped, ['task-1']);
  });
}
