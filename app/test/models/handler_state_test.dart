import 'package:antgrid/models/handler_state.dart';
import 'package:flutter_test/flutter_test.dart';

HandlerSessionState _session(String terminalId, {required int pending}) {
  return HandlerSessionState(
    terminalId: terminalId,
    runState: HandlerRunState.watching,
    pendingEscalations: pending,
    armedAt: 1,
    goal: 'summary',
    backlog: const [],
    escalations: const [],
  );
}

HandlerEscalation _esc(String id, {required String urgency, required int at}) =>
    HandlerEscalation(
      escalationId: id,
      terminalId: 't1',
      question: 'q',
      reasoning: 'r',
      draftReply: 'd',
      urgency: urgency,
      at: at,
    );

void main() {
  group('compareEscalations', () {
    test('urgent first, and oldest first inside each band', () {
      final ordered =
          [
            _esc('normal-old', urgency: 'normal', at: 1),
            _esc('urgent-new', urgency: 'high', at: 9),
            _esc('normal-new', urgency: 'normal', at: 7),
            _esc('urgent-old', urgency: 'high', at: 5),
          ]..sort(compareEscalations);
      expect(ordered.map((e) => e.escalationId), [
        'urgent-old',
        'urgent-new',
        'normal-old',
        'normal-new',
      ]);
    });

    test('age never crosses the band', () {
      // The oldest row on the list still sorts under a `high` that arrived a
      // moment ago: one has been waiting, the other is holding the agent up.
      final ordered =
          [
            _esc('ancient', urgency: 'normal', at: 1),
            _esc('fresh', urgency: 'high', at: 9999),
          ]..sort(compareEscalations);
      expect(ordered.first.escalationId, 'fresh');
    });

    test('an urgency a newer bridge invents ranks as normal', () {
      // The unknown band is the safe one. Reading an unrecognised word as
      // urgent would let a bridge outrank the one value the app knows means
      // the agent is stopped.
      final ordered =
          [
            _esc('invented', urgency: 'critical', at: 1),
            _esc('known', urgency: 'high', at: 9),
          ]..sort(compareEscalations);
      expect(ordered.first.escalationId, 'known');
    });
  });

  const backlogWire = [
    {'id': 'i1', 'text': 'run the tests', 'status': 'done', 'createdAt': 1},
    {
      'id': 'i2',
      'text': 'open a PR',
      'status': 'queued',
      'dependsOn': ['i1'],
      'createdAt': 2,
    },
  ];

  test('HandlerInstructionItem round-trips wire json', () {
    final i = HandlerInstructionItem.fromWire(backlogWire[1])!;
    expect(i.id, 'i2');
    expect(i.dependsOn, ['i1']);
    expect(i.toWire()['status'], 'queued');
    expect(i.toWire().containsKey('outcome'), isFalse);
    expect(HandlerInstructionItem.fromWire({'id': 1}), isNull);
  });

  test('HandlerSessionState counts only done items as progress', () {
    final s = HandlerSessionState.fromWire({
      'terminalId': 't1',
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'get the tests passing',
      'backlog': backlogWire,
    })!;
    expect(s.backlogDone, 1);
    expect(s.backlogTotal, 2);
    expect(s.runState, HandlerRunState.watching);
  });

  test('a malformed backlog item drops itself, not the session', () {
    final s = HandlerSessionState.fromWire({
      'terminalId': 't1',
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': '',
      'backlog': [
        {'id': 'i1', 'text': 'ok', 'status': 'queued', 'createdAt': 1},
        {'id': 'i2', 'status': 'queued', 'createdAt': 2},
      ],
    })!;
    expect(s.backlogTotal, 1);
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
      'state': 'parked',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'g',
      'backlog': [],
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
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'g',
      'backlog': [],
      'parkKind': 42,
      'parkedUntil': 'soon',
    })!;
    expect(s.parkKind, isNull);
    expect(s.parkedUntil, isNull);
  });

  Map<String, dynamic> wire(Object? observability) => {
    'terminalId': 't1',
    'state': 'watching',
    'pendingEscalations': 0,
    'armedAt': 1,
    'goal': 'g',
    'backlog': [],
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
    expect(
      handlerObservabilityFromWire('escalate_only'),
      HandlerObservability.escalateOnly,
    );
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

  group('quick choices (§4.6)', () {
    const approve = {
      'choiceId': 'approve',
      'label': 'Approve',
      'text': 'go ahead and merge',
    };
    const reject = {
      'choiceId': 'reject',
      'label': 'Reject',
      'text': 'Do not proceed. Wait for my instructions.',
    };
    Map<String, dynamic> escalationWire({Object? choices, String? kind}) => {
      'escalationId': 'e1',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'go ahead and merge',
      'urgency': 'normal',
      'at': 1,
      'kind': ?kind,
      'choices': ?choices,
    };

    test('a two-choice card parses, text and id both preserved', () {
      final e = HandlerEscalation.fromWire(
        't1',
        escalationWire(choices: [approve, reject]),
      )!;
      expect(e.choices, hasLength(2));
      expect(e.choices![0].choiceId, 'approve');
      expect(e.choices![0].label, 'Approve');
      // The label is not the answer: [Approve] sends the judge's draft verbatim.
      expect(e.choices![0].text, 'go ahead and merge');
      expect(e.choiceById('reject')!.text, contains('Do not proceed'));
      expect(e.choiceById('nope'), isNull);
    });

    test('an older bridge sending no choices still parses', () {
      // The whole compatibility contract: absent means free-text reply, exactly
      // as an absent `kind` does.
      final e = HandlerEscalation.fromWire('t1', escalationWire())!;
      expect(e.choices, isNull);
      expect(e.draftReply, 'go ahead and merge');
    });

    test('a malformed or short list drops the choices, not the row', () {
      // Dropping the escalation would lose an answerable row over decoration;
      // rendering one chip, or a chip with no text, would be a card the user
      // cannot read before tapping.
      for (final bad in <Object>[
        [approve],
        [approve, reject, approve, reject],
        [approve, 'nope'],
        [
          approve,
          {'choiceId': '', 'label': 'Reject', 'text': 'no'},
        ],
        [
          approve,
          {'choiceId': 'reject', 'label': '', 'text': 'no'},
        ],
        [
          approve,
          {'choiceId': 'reject', 'label': 'x' * 41, 'text': 'no'},
        ],
        [
          approve,
          {'choiceId': 'reject', 'label': 'Reject', 'text': 'x' * 401},
        ],
        [
          approve,
          {'choiceId': 'reject', 'label': 'Reject', 'text': 'no\r'},
        ],
        // Whitespace alone is dropped by the send path, so the chip would be a
        // button that silently does nothing.
        [
          approve,
          {'choiceId': 'reject', 'label': 'Reject', 'text': '   '},
        ],
        [
          approve,
          {'choiceId': 'z' * 41, 'label': 'Reject', 'text': 'no'},
        ],
        // A tap is resolved by first match, so a repeated id would send the text
        // of a chip the user did not read.
        [
          approve,
          {'choiceId': 'approve', 'label': 'Approve with tests', 'text': 'no'},
        ],
        'choices',
      ]) {
        final e = HandlerEscalation.fromWire(
          't1',
          escalationWire(choices: bad),
        );
        expect(e, isNotNull, reason: '$bad');
        expect(e!.choices, isNull, reason: '$bad');
      }
    });

    test('a resolve_in_session escalation never carries choices', () {
      // Injected text cannot answer an option-based agent prompt, so a chip on
      // one would be a button that does nothing. The bridge refuses to mint
      // these; this is the app's own floor.
      final e = HandlerEscalation.fromWire(
        'chat-1',
        escalationWire(choices: [approve, reject], kind: 'resolve_in_session'),
      )!;
      expect(e.kind, 'resolve_in_session');
      expect(e.choices, isNull);
      expect(e.choiceById('approve'), isNull);
    });

    test('a guard_blocked escalation never carries choices', () {
      // The row exists BECAUSE a guard refused this exact text, so a one-tap
      // would re-send it with the thinnest possible human in the loop. The
      // bridge refuses to mint these; this is the app's own floor.
      final e = HandlerEscalation.fromWire(
        't1',
        escalationWire(choices: [approve, reject], kind: 'guard_blocked'),
      )!;
      expect(e.kind, 'guard_blocked');
      expect(e.choices, isNull);
      expect(e.choiceById('approve'), isNull);
      // Still answerable in the user's own words — the draft is what the reply
      // sheet opens on.
      expect(e.draftReply, isNotEmpty);
    });
  });

  group('HandlerWrapUp.fromWire', () {
    Map<String, dynamic> wire({
      Object? outcomes,
      Object? blockedTotal = 1,
      Object? goal = 'ship the parser',
    }) => {
      'wrapUpId': 'w1',
      'terminalId': 't1',
      'at': 9,
      'goal': goal,
      'outcomes':
          outcomes ??
          [
            {
              'status': 'done',
              'total': 5,
              'items': ['item a', 'item b'],
            },
          ],
      'blockedTotal': blockedTotal,
      'blockedReasons': ['refused the force push'],
    };

    test('a full record round-trips and derives its +N more', () {
      final w = HandlerWrapUp.fromWire(wire())!;
      expect(w.wrapUpId, 'w1');
      expect(w.terminalId, 't1');
      expect(w.at, 9);
      expect(w.goal, 'ship the parser');
      expect(w.blockedTotal, 1);
      expect(w.blockedReasons, ['refused the force push']);
      final o = w.outcomes.single;
      expect(o.status, 'done');
      expect(o.total, 5);
      expect(o.items, ['item a', 'item b']);
      // The record stores the true total and never a second `more` field, so
      // the suffix is arithmetic here rather than something that can disagree.
      expect(o.more, 3);
    });

    test('a mistyped required field drops the whole record', () {
      expect(HandlerWrapUp.fromWire({...wire(), 'wrapUpId': 7}), isNull);
      expect(HandlerWrapUp.fromWire(wire(blockedTotal: 'two')), isNull);
      expect(HandlerWrapUp.fromWire(wire(goal: null)), isNull);
      expect(HandlerWrapUp.fromWire(wire(outcomes: 'done: a, b')), isNull);
      expect(HandlerWrapUp.fromWire('wrapped up'), isNull);
    });

    test('an outcome this build has no status for costs one group, not the '
        'report', () {
      // A bridge ahead of the app. Losing the whole card would hide the
      // blocked-report line too, which is the part nothing else can re-derive.
      final w = HandlerWrapUp.fromWire(
        wire(
          outcomes: [
            {'status': 'invented', 'total': 1, 'items': <String>[]},
            {
              'status': 'failed',
              'total': 1,
              'items': ['item c'],
            },
          ],
        ),
      )!;
      expect(w.outcomes.single.status, 'failed');
      expect(w.blockedTotal, 1);
    });
  });
}
