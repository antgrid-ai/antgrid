import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  const sessionWire = {
    'terminalId': 't1',
    'notifyOnly': false,
    'state': 'watching',
    'pendingEscalations': 2,
    'armedAt': 1,
    'doneWhenMet': false,
    'brief': {
      'taskSummary': 'summary',
      'willHandle': [],
      'wakeFor': [],
      'thenItems': [],
    },
    'ledger': [],
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

  test('handler:planResult parses fallback with optional briefs', () {
    final m = parseAbMessage({
      'type': 'handler:planResult',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'terminalId': 't1',
      'fallback': true,
      'brief': sessionWire['brief'],
    });
    expect(m, isA<HandlerPlanResultMessage>());
    final r = m as HandlerPlanResultMessage;
    expect(r.terminalId, 't1');
    expect(r.fallback, true);
    expect(r.brief, isNotNull);
    expect(r.previousBrief, isNull);
  });

  test('handler:planResult with a missing fallback returns null', () {
    expect(
      parseAbMessage({
        'type': 'handler:planResult',
        'id': 'x',
        'timestamp': 1,
        'projectId': 'p',
        'terminalId': 't1',
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

  test('handler:activity accepts the new brief-lifecycle decision kinds', () {
    final m = parseAbMessage({
      'type': 'handler:activity',
      'id': 'x',
      'timestamp': 1,
      'projectId': 'p',
      'recordId': 'r1',
      'at': 1700,
      'terminalId': 't1',
      'decision': 'brief_armed',
      'reason': 'armed',
    });
    expect((m as HandlerActivityMessage).decision, 'brief_armed');
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
