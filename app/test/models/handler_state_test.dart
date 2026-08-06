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

  test('run-state wire mapping covers parked, unknown still yields null', () {
    expect(handlerRunStateFromWire('parked'), HandlerRunState.parked);
    expect(handlerRunStateToWire(HandlerRunState.parked), 'parked');
    expect(handlerRunStateFromWire('napping'), isNull);
  });

  test('a parked wire session parses with its park fields', () {
    // fromWire drops the WHOLE session when the run state is unmapped, so an
    // unmapped "parked" would make parked sessions vanish from the app.
    final s = HandlerSessionState.fromWire({
      'terminalId': 't1',
      'notifyOnly': false,
      'state': 'parked',
      'pendingEscalations': 0,
      'armedAt': 1,
      'doneWhenMet': false,
      'brief': briefWire,
      'ledger': [],
      'parkKind': 'limit',
      'parkedUntil': 1770000000000,
    });
    expect(s, isNotNull);
    expect(s!.runState, HandlerRunState.parked);
    expect(s.parkKind, 'limit');
    expect(s.parkedUntil, 1770000000000);
    expect(s.copyWith(pendingEscalations: 1).parkKind, 'limit');
    expect(s.copyWith(pendingEscalations: 1).parkedUntil, 1770000000000);
  });

  test('park fields are absent on an unparked session', () {
    final s = HandlerSessionState.fromWire({
      'terminalId': 't1',
      'notifyOnly': false,
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'doneWhenMet': false,
      'brief': briefWire,
      'ledger': [],
      'parkKind': 42,
      'parkedUntil': 'soon',
    })!;
    expect(s.parkKind, isNull);
    expect(s.parkedUntil, isNull);
  });

  Map<String, dynamic> wire(Object? observability) => {
    'terminalId': 't1',
    'notifyOnly': false,
    'state': 'watching',
    'pendingEscalations': 0,
    'armedAt': 1,
    'doneWhenMet': false,
    'brief': briefWire,
    'ledger': [],
    'observability': ?observability,
  };

  test('observability parses the three wire values', () {
    expect(
      HandlerSessionState.fromWire(wire('full'))!.observability,
      HandlerObservability.full,
    );
    expect(
      HandlerSessionState.fromWire(wire('escalate_only'))!.observability,
      HandlerObservability.escalateOnly,
    );
    final unsupported = HandlerSessionState.fromWire(wire('unsupported'))!;
    expect(unsupported.observability, HandlerObservability.unsupported);
    expect(
      unsupported.copyWith(pendingEscalations: 1).observability,
      HandlerObservability.unsupported,
    );
  });

  test('an unreported observability is unknown, never unsupported', () {
    // A bridge predating the field sends nothing, and a future one could send a
    // value this build has no case for. Folding either onto "unsupported" would
    // tell the user a working session cannot be watched.
    expect(HandlerSessionState.fromWire(wire(null))!.observability, isNull);
    expect(HandlerSessionState.fromWire(wire('partly'))!.observability, isNull);
    expect(HandlerSessionState.fromWire(wire(7))!.observability, isNull);
    expect(handlerObservabilityFromWire('escalate_only'),
        HandlerObservability.escalateOnly);
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
