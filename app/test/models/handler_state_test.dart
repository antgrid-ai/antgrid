import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/handler_state.dart';

void main() {
  test('initial state is disabled Watchdog, off, empty', () {
    const s = HandlerState.initial();
    expect(s.enabled, false);
    expect(s.template, HandlerTemplate.watchdog);
    expect(s.runState, HandlerRunState.off);
    expect(s.pendingEscalations, 0);
    expect(s.escalations, isEmpty);
    expect(s.activity, isEmpty);
    expect(s.latestEscalationId, isNull);
  });

  test('wire mappers round-trip templates and map needs_you', () {
    expect(handlerTemplateFromWire('autopilot'), HandlerTemplate.autopilot);
    expect(handlerTemplateFromWire('nonsense'), HandlerTemplate.watchdog);
    expect(handlerTemplateToWire(HandlerTemplate.closer), 'closer');
    expect(handlerRunStateFromWire('needs_you'), HandlerRunState.needsYou);
    expect(handlerRunStateFromWire('bogus'), HandlerRunState.off);
  });

  test('latestEscalationId tracks the last appended escalation', () {
    const e1 = HandlerEscalation(
      escalationId: 'a', terminalId: 't', question: 'q',
      reasoning: 'r', draftReply: 'd', urgency: 'normal');
    const e2 = HandlerEscalation(
      escalationId: 'b', terminalId: 't', question: 'q',
      reasoning: 'r', draftReply: 'd', urgency: 'high');
    const s = HandlerState.initial();
    final next = s.copyWith(escalations: [e1, e2]);
    expect(next.latestEscalationId, 'b');
  });
}
