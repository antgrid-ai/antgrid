import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/agent_event.dart';

void main() {
  test('parses agent:turn-start and agent:turn-end with stopReason', () {
    final start = parseAgentEvent({
      'type': 'agent:turn-start',
      'sessionId': 's',
      'turnId': 't',
    });
    expect(start, isA<AgentTurnStart>());

    final end = parseAgentEvent({
      'type': 'agent:turn-end',
      'sessionId': 's',
      'turnId': 't',
      'stopReason': 'error',
      'error': {
        'category': 'server_error',
        'message': '500',
        'retryable': true,
      },
    });
    expect(end, isA<AgentTurnEnd>());
    expect((end as AgentTurnEnd).stopReason, 'error');
    expect(end.error?.category, 'server_error');
  });

  test(
    'parses agent:item-added with a tool_call item carrying diff content',
    () {
      final added = parseAgentEvent({
        'type': 'agent:item-added',
        'sessionId': 's',
        'turnId': 't',
        'itemId': 'i1',
        'item': {
          'itemId': 'i1',
          'kind': 'tool_call',
          'status': 'running',
          'toolKind': 'edit',
          'title': 'Edit',
          'content': [
            {'type': 'diff', 'path': 'a.ts', 'newText': 'x'},
          ],
        },
      });
      expect(added, isA<AgentItemAdded>());
      final item = (added as AgentItemAdded).item;
      expect(item.kind, 'tool_call');
      expect(item.content!.first.type, 'diff');
      expect(item.content!.first.path, 'a.ts');
    },
  );

  test(
    'AgentItem parses rawInput/rawOutput and copyWith preserves all fields',
    () {
      final added =
          parseAgentEvent({
                'type': 'agent:item-added',
                'sessionId': 's',
                'turnId': 't',
                'itemId': 'i1',
                'item': {
                  'itemId': 'i1',
                  'kind': 'tool_call',
                  'toolKind': 'shell',
                  'title': 'ls',
                  'rawInput': {'command': 'ls', 'cwd': '/tmp'},
                  'rawOutput': {'ok': true},
                },
              })
              as AgentItemAdded;
      final item = added.item;
      expect((item.rawInput as Map)['command'], 'ls');
      expect((item.rawOutput as Map)['ok'], true);

      // copyWith overrides only text and carries every other field through.
      final updated = item.copyWith(text: 'streamed');
      expect(updated.text, 'streamed');
      expect(updated.toolKind, 'shell');
      expect(updated.title, 'ls');
      expect((updated.rawInput as Map)['cwd'], '/tmp');
      expect((updated.rawOutput as Map)['ok'], true);
    },
  );

  test('parses agent:item-delta and agent:permission-request', () {
    final delta = parseAgentEvent({
      'type': 'agent:item-delta',
      'sessionId': 's',
      'turnId': 't',
      'itemId': 'i1',
      'textChunk': 'hi',
    });
    expect(delta, isA<AgentItemDelta>());
    expect((delta as AgentItemDelta).textChunk, 'hi');

    final perm = parseAgentEvent({
      'type': 'agent:permission-request',
      'sessionId': 's',
      'permissionId': 'p1',
      'title': 'Run?',
      'options': [
        {'optionId': 'ok', 'label': 'Allow', 'kind': 'allow_once'},
      ],
    });
    expect(perm, isA<AgentPermissionRequest>());
    expect((perm as AgentPermissionRequest).options.first.optionId, 'ok');
  });

  test('parses agent:question with options', () {
    final q = parseAgentEvent({
      'type': 'agent:question',
      'sessionId': 's',
      'questionId': 'q1',
      'kind': 'single_select',
      'prompt': 'Pick one',
      'options': [
        {'id': '0', 'label': 'A', 'description': 'first'},
        {'id': '1', 'label': 'B'},
      ],
    });
    expect(q, isA<AgentQuestion>());
    final question = q as AgentQuestion;
    expect(question.prompt, 'Pick one');
    expect(question.kind, 'single_select');
    expect(question.options, hasLength(2));
    expect(question.options.first.id, '0');
    expect(question.options.first.description, 'first');
  });

  test('parses agent:usage with itemId, breakdown, and contextWindow', () {
    final usage = parseAgentEvent({
      'type': 'agent:usage',
      'sessionId': 's',
      'turnId': 't',
      'itemId': 'msg:a1',
      'total': {
        'totalTokens': 100,
        'cacheReadTokens': 20,
        'reasoningTokens': 5,
      },
      'last': {'totalTokens': 10},
      'contextWindow': 200000,
    });
    expect(usage, isA<AgentUsageEvent>());
    final event = usage as AgentUsageEvent;
    expect(event.itemId, 'msg:a1');
    final u = event.usage;
    expect(u.total.totalTokens, 100);
    expect(u.total.cacheReadTokens, 20);
    expect(u.last?.totalTokens, 10);
    expect(u.contextWindow, 200000);
  });

  test('returns null for non-agent types', () {
    expect(parseAgentEvent({'type': 'terminal:output'}), isNull);
  });

  test('parseAbMessage delegates agent:* to parseAgentEvent', () {
    final parsed = parseAbMessage({
      'type': 'agent:turn-start',
      'sessionId': 's',
      'turnId': 't',
    });
    expect(parsed, isA<AgentTurnStart>());
  });
}
