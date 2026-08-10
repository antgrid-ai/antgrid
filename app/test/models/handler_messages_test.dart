import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  const sessionWire = {
    'terminalId': 't1',
    'notifyOnly': false,
    'state': 'watching',
    'pendingEscalations': 2,
    'armedAt': 1,
    'goal': 'summary',
    'backlog': [],
  };

  test('handler:status parses raw session maps and optional defaultTool', () {
    final m = parseAbMessage({
      'type': 'handler:status',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'defaultTool': 'claude',
      'sessions': [sessionWire],
    });
    expect(m, isA<HandlerStatusMessage>());
    final s = m as HandlerStatusMessage;
    expect(s.projectId, 'p');
    expect(s.defaultTool, 'claude');
    expect(s.sessions, hasLength(1));
    expect(s.sessions.first['terminalId'], 't1');
  });

  test('handler:status with no defaultTool parses with defaultTool null', () {
    final m = parseAbMessage({
      'type': 'handler:status',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'sessions': <Map<String, dynamic>>[],
    });
    expect(m, isA<HandlerStatusMessage>());
    expect((m as HandlerStatusMessage).defaultTool, isNull);
    expect(m.sessions, isEmpty);
  });

  test(
    'handler:status with a non-string defaultTool parses with defaultTool null',
    () {
      final m = parseAbMessage({
        'type': 'handler:status',
        'id': 'x',
        'timestamp': 1,
        'projectId': 'p',
        'defaultTool': 42,
        'sessions': <Map<String, dynamic>>[],
      });
      expect(m, isA<HandlerStatusMessage>());
      expect((m as HandlerStatusMessage).defaultTool, isNull);
    },
  );

  test('handler:status with a non-list sessions returns null', () {
    expect(
      parseAbMessage({
        'type': 'handler:status',
        'id': 'x',
        'timestamp': 1,
        'projectId': 'p',
        'sessions': 'nope',
      }),
      isNull,
    );
  });

  test('handler:escalation parses all fields including floorRule', () {
    final m = parseAbMessage({
      'type': 'handler:escalation',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't1',
      'question': 'bun or vitest?',
      'reasoning': 'arch call',
      'draftReply': 'use bun',
      'urgency': 'high',
      'floorRule': 'schema changes',
    });
    expect(m, isA<HandlerEscalationMessage>());
    final e = m as HandlerEscalationMessage;
    expect(e.escalationId, 'e1');
    expect(e.terminalId, 't1');
    expect(e.draftReply, 'use bun');
    expect(e.urgency, 'high');
    expect(e.floorRule, 'schema changes');
  });

  test('handler:escalation with no floorRule parses with floorRule null', () {
    final m = parseAbMessage({
      'type': 'handler:escalation',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'normal',
    });
    expect((m as HandlerEscalationMessage).floorRule, isNull);
  });

  test('handler:escalation carries quick choices through the push', () {
    final m =
        parseAbMessage({
              'type': 'handler:escalation',
              'id': 'x',
              'timestamp': 1,
              'projectId': 'p',
              'escalationId': 'e1',
              'terminalId': 't1',
              'question': 'q',
              'reasoning': 'r',
              'draftReply': 'use bun',
              'urgency': 'normal',
              'choices': [
                {'choiceId': 'approve', 'label': 'Approve', 'text': 'use bun'},
                {'choiceId': 'reject', 'label': 'Reject', 'text': 'stop'},
              ],
            })
            as HandlerEscalationMessage;
    expect(m.choices, hasLength(2));
    expect(m.choices![0].text, 'use bun');
  });

  test('handler:escalation without choices parses with choices null', () {
    // An empty card is worse than no card: the row must fall back to the
    // free-text sheet whenever the bridge offered nothing.
    final m = parseAbMessage({
      'type': 'handler:escalation',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'd',
      'urgency': 'normal',
    });
    expect((m as HandlerEscalationMessage).choices, isNull);
  });

  test('handler:activity parses, detail optional', () {
    final m = parseAbMessage({
      'type': 'handler:activity',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'recordId': 'r1',
      'at': 1700,
      'terminalId': 't1',
      'decision': 'handle',
      'reason': 'clear',
    });
    expect(m, isA<HandlerActivityMessage>());
    final a = m as HandlerActivityMessage;
    expect(a.recordId, 'r1');
    expect(a.at, 1700);
    expect(a.decision, 'handle');
    expect(a.detail, isNull);
  });

  test('handler:activity accepts the item-lifecycle decision kinds', () {
    for (final decision in [
      'armed',
      'goal_edited',
      'item_done',
      'item_blocked',
      'item_skipped',
      'item_failed',
    ]) {
      final m = parseAbMessage({
        'type': 'handler:activity',
        'id': 'x',
        'timestamp': 1,
        'projectId': 'p',
        'recordId': 'r1',
        'at': 1700,
        'terminalId': 't1',
        'decision': decision,
        'reason': 'run the tests',
      });
      expect((m as HandlerActivityMessage).decision, decision);
    }
  });

  test('handler:activity with a non-string detail parses with detail null', () {
    final m = parseAbMessage({
      'type': 'handler:activity',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'recordId': 'r1',
      'at': 1700,
      'terminalId': 't1',
      'decision': 'handle',
      'reason': 'clear',
      'detail': 99,
    });
    expect(m, isA<HandlerActivityMessage>());
    expect((m as HandlerActivityMessage).detail, isNull);
  });
}
