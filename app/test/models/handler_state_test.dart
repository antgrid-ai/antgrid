import 'package:antgrid/models/handler_state.dart';
import 'package:flutter_test/flutter_test.dart';

HandlerSessionState _session(String terminalId, {required int pending}) {
  return HandlerSessionState(
    terminalId: terminalId,
    notifyOnly: false,
    runState: HandlerRunState.watching,
    pendingEscalations: pending,
    armedAt: 1,
    doneWhenMet: false,
    brief: const HandlerBrief(
      taskSummary: 'summary',
      willHandle: [],
      wakeFor: [],
      thenItems: [],
    ),
    ledger: const [],
    escalations: const [],
  );
}

void main() {
  const briefWire = {
    'taskSummary': 'Migrating auth',
    'willHandle': ['routine prompts'],
    'wakeFor': ['schema changes'],
    'doneWhen': 'tests pass',
    'thenItems': ['/compact', 'code review'],
  };

  test('HandlerBrief round-trips wire json', () {
    final b = HandlerBrief.fromWire(briefWire)!;
    expect(b.taskSummary, 'Migrating auth');
    expect(b.thenItems, hasLength(2));
    expect(b.toWire()['wakeFor'], ['schema changes']);
    expect(HandlerBrief.fromWire({'taskSummary': 1}), isNull);
  });

  test('HandlerSessionState computes then-progress from the ledger', () {
    final s = HandlerSessionState.fromWire({
      'terminalId': 't1',
      'notifyOnly': false,
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'doneWhenMet': false,
      'brief': briefWire,
      'ledger': [
        {'item': '/compact', 'evidence': 'ran at turn 3', 'at': 5},
      ],
    })!;
    expect(s.thenSatisfied, 1);
    expect(s.thenTotal, 2);
    expect(s.runState, HandlerRunState.watching);
  });

  test('HandlerState aggregates pending across sessions', () {
    final state = HandlerState.initial().copyWith(
      sessions: {
        't1': _session('t1', pending: 2),
        't2': _session('t2', pending: 1),
      },
    );
    expect(state.pendingEscalations, 3);
    expect(state.anyArmed, isTrue);
  });
}
