import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  test('agent:question parses isSecret (default false)', () {
    final q =
        parseAgentEvent({
              'type': 'agent:question',
              'sessionId': 's1',
              'questionId': 'q1',
              'kind': 'text',
              'prompt': 'API key?',
              'isSecret': true,
            })
            as AgentQuestion;
    expect(q.isSecret, isTrue);

    final plain =
        parseAgentEvent({
              'type': 'agent:question',
              'sessionId': 's1',
              'questionId': 'q2',
              'kind': 'text',
              'prompt': 'Name?',
            })
            as AgentQuestion;
    expect(plain.isSecret, isFalse);
  });

  test('agent:updateAvailable parses tool/installed/latest', () {
    final upd =
        parseAgentEvent({
              'type': 'agent:updateAvailable',
              'tool': 'codex',
              'installed': '0.142.2',
              'latest': '0.144.3',
              'sessionId': 's1',
            })
            as AgentUpdateAvailable;
    expect(upd.tool, 'codex');
    expect(upd.installed, '0.142.2');
    expect(upd.latest, '0.144.3');
    expect(upd.sessionId, 's1');
  });

  test('agent:updateResult parses outcome fields (success)', () {
    final res =
        parseAgentEvent({
              'type': 'agent:updateResult',
              'tool': 'codex',
              'sessionId': 's1',
              'ok': true,
              'exitCode': 0,
              'installed': '0.144.3',
              'output': 'updated',
            })
            as AgentUpdateResult;
    expect(res.tool, 'codex');
    expect(res.sessionId, 's1');
    expect(res.ok, isTrue);
    expect(res.exitCode, 0);
    expect(res.installed, '0.144.3');
    expect(res.output, 'updated');

    // The service consumes it via parseAbMessage — the delegation must exist.
    final viaAb = parseAbMessage({
      'type': 'agent:updateResult',
      'tool': 'codex',
      'ok': false,
    });
    expect(viaAb, isA<AgentUpdateResult>());
    expect((viaAb as AgentUpdateResult).ok, isFalse);
  });

  test('agent:capabilities parses lists, efforts, and current ids', () {
    final caps =
        parseAgentEvent({
              'type': 'agent:capabilities',
              'sessionId': 's1',
              'commands': [
                {
                  'id': 'builtin:review',
                  'name': 'review',
                  'description': 'Review changes',
                  'argHint': '[instructions]',
                },
              ],
              'modes': [
                {'id': ':workspace', 'name': ':workspace'},
              ],
              'models': [
                {
                  'id': 'gpt-5.2',
                  'name': 'GPT-5.2',
                  'efforts': ['low', 'high'],
                  'defaultEffort': 'medium',
                },
              ],
              'currentModelId': 'gpt-5.2',
              'currentEffortId': 'high',
            })
            as AgentCapabilities;
    expect(caps.sessionId, 's1');
    expect(caps.commands.single.argHint, '[instructions]');
    expect(caps.models.single.efforts, ['low', 'high']);
    expect(caps.currentModel?.defaultEffort, 'medium');
    expect(caps.currentEffortId, 'high');
    expect(caps.currentModeId, isNull);

    // The service parses via parseAbMessage — the delegation case must exist.
    final viaAb = parseAbMessage({
      'type': 'agent:capabilities',
      'sessionId': 's1',
    });
    expect(viaAb, isA<AgentCapabilities>());
  });
}
