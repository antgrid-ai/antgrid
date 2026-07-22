import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  test('handler:status parses, model optional', () {
    final m = parseAbMessage({
      'type': 'handler:status', 'id': 'x', 'timestamp': 1,
      'projectId': 'p', 'enabled': true, 'template': 'closer',
      'model': 'claude-haiku-4-5', 'state': 'watching', 'pendingEscalations': 2,
    });
    expect(m, isA<HandlerStatusMessage>());
    final s = m as HandlerStatusMessage;
    expect(s.enabled, true);
    expect(s.template, 'closer');
    expect(s.model, 'claude-haiku-4-5');
    expect(s.state, 'watching');
    expect(s.pendingEscalations, 2);
  });

  test('handler:status tolerates a numeric (double) pendingEscalations', () {
    final m = parseAbMessage({
      'type': 'handler:status', 'id': 'x', 'timestamp': 1,
      'projectId': 'p', 'enabled': false, 'template': 'watchdog',
      'state': 'off', 'pendingEscalations': 0.0,
    });
    expect((m as HandlerStatusMessage).pendingEscalations, 0);
    expect(m.model, isNull);
  });

  test('handler:status with a non-numeric count returns null', () {
    expect(
      parseAbMessage({
        'type': 'handler:status', 'id': 'x', 'timestamp': 1,
        'projectId': 'p', 'enabled': true, 'template': 'closer',
        'state': 'watching', 'pendingEscalations': 'two',
      }),
      isNull,
    );
  });

  test('handler:status with a non-string model parses with model null', () {
    final m = parseAbMessage({
      'type': 'handler:status', 'id': 'x', 'timestamp': 1,
      'projectId': 'p', 'enabled': true, 'template': 'closer',
      'model': 42, 'state': 'watching', 'pendingEscalations': 1,
    });
    expect(m, isA<HandlerStatusMessage>());
    expect((m as HandlerStatusMessage).model, isNull);
  });

  test('handler:escalation parses all fields', () {
    final m = parseAbMessage({
      'type': 'handler:escalation', 'id': 'x', 'timestamp': 1,
      'projectId': 'p', 'escalationId': 'e1', 'terminalId': 't1',
      'question': 'bun or vitest?', 'reasoning': 'arch call',
      'draftReply': 'use bun', 'urgency': 'high',
    });
    expect(m, isA<HandlerEscalationMessage>());
    final e = m as HandlerEscalationMessage;
    expect(e.escalationId, 'e1');
    expect(e.terminalId, 't1');
    expect(e.draftReply, 'use bun');
    expect(e.urgency, 'high');
  });

  test('handler:activity parses, detail optional', () {
    final m = parseAbMessage({
      'type': 'handler:activity', 'id': 'x', 'timestamp': 1,
      'projectId': 'p', 'recordId': 'r1', 'at': 1700,
      'terminalId': 't1', 'decision': 'handle', 'reason': 'clear',
    });
    expect(m, isA<HandlerActivityMessage>());
    final a = m as HandlerActivityMessage;
    expect(a.recordId, 'r1');
    expect(a.at, 1700);
    expect(a.decision, 'handle');
    expect(a.detail, isNull);
  });

  test('handler:activity with a non-string detail parses with detail null', () {
    final m = parseAbMessage({
      'type': 'handler:activity', 'id': 'x', 'timestamp': 1,
      'projectId': 'p', 'recordId': 'r1', 'at': 1700,
      'terminalId': 't1', 'decision': 'handle', 'reason': 'clear',
      'detail': 99,
    });
    expect(m, isA<HandlerActivityMessage>());
    expect((m as HandlerActivityMessage).detail, isNull);
  });
}
