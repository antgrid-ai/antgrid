import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/project/project_message_classification.dart';

void main() {
  test('parses agent:background-tasks into AgentBackgroundTasks', () {
    final parsed = parseAgentEvent({
      'type': 'agent:background-tasks',
      'sessionId': 's1',
      'tasks': [
        {
          'taskId': 'task-1',
          'kind': 'shell',
          'title': 'bun dev',
          'status': 'running',
          'itemId': 'tool:tu1',
          'startedAt': 1735730000000,
        },
      ],
    });
    expect(parsed, isA<AgentBackgroundTasks>());
    final tasks = (parsed as AgentBackgroundTasks).tasks;
    expect(tasks, hasLength(1));
    expect(tasks.single.taskId, 'task-1');
    expect(tasks.single.title, 'bun dev');
    expect(tasks.single.itemId, 'tool:tu1');
    expect(
      tasks.single.startedAt,
      DateTime.fromMillisecondsSinceEpoch(1735730000000),
    );
    expect(tasks.single.killable, isTrue);
  });

  test('parses an empty list frame', () {
    final parsed = parseAgentEvent({
      'type': 'agent:background-tasks',
      'sessionId': 's1',
      'tasks': const [],
    });
    expect(parsed, isA<AgentBackgroundTasks>());
    expect((parsed as AgentBackgroundTasks).tasks, isEmpty);
  });

  test('agent:background-tasks is status-tier (always dispatched)', () {
    expect(
      classifyAbMessageByType('agent:background-tasks'),
      MessageTier.status,
    );
  });
}
