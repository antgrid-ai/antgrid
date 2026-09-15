import 'package:antgrid/models/ab_message.dart';
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
  test('runtime availability preserves support and older bridge absence', () {
    final wire = <String, dynamic>{
      'terminalId': 't1',
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'goal',
      'backlog': [],
      'observability': 'full',
    };
    expect(HandlerSessionState.fromWire(wire)!.availability, isNull);
    wire['availability'] = {
      'state': 'unavailable',
      'reason': 'Waiting for restart',
    };
    final session = HandlerSessionState.fromWire(wire)!;
    expect(session.observability, HandlerObservability.full);
    expect(session.availability!.state, HandlerAvailabilityState.unavailable);
    expect(
      session.availability!.note,
      'Waiting for restart. Start or restart the agent to try again.',
    );
    expect(
      session.copyWith(pendingEscalations: 1).availability,
      same(session.availability),
    );
    wire['availability'] = {'state': 'future-value'};
    expect(HandlerSessionState.fromWire(wire)!.availability, isNull);
  });
  group('compareEscalations', () {
    test('urgent first, and oldest first inside each band', () {
      final ordered = [
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
      final ordered = [
        _esc('ancient', urgency: 'normal', at: 1),
        _esc('fresh', urgency: 'high', at: 9999),
      ]..sort(compareEscalations);
      expect(ordered.first.escalationId, 'fresh');
    });

    test('an urgency a newer bridge invents ranks as normal', () {
      // The unknown band is the safe one. Reading an unrecognised word as
      // urgent would let a bridge outrank the one value the app knows means
      // the agent is stopped.
      final ordered = [
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
      'parkCause': 'agent_limit',
    });
    expect(s, isNotNull);
    expect(s!.runState, HandlerRunState.parked);
    expect(s.parkKind, 'limit');
    expect(s.parkedUntil, 1770000000000);
    expect(s.parkCause, 'agent_limit');
    expect(s.copyWith(pendingEscalations: 1).parkKind, 'limit');
    expect(s.copyWith(pendingEscalations: 1).parkedUntil, 1770000000000);
    expect(s.copyWith(pendingEscalations: 1).parkCause, 'agent_limit');
  });

  test('a cause this build cannot name still rides through', () {
    // Kept raw like `role`: the words a surface renders fall back to the park
    // kind's own copy, but dropping the value would leave a newer bridge's
    // attribution unreadable to anything downstream.
    final s = HandlerSessionState.fromWire({
      'terminalId': 't1',
      'state': 'parked',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'g',
      'backlog': [],
      'parkKind': 'outage',
      'parkCause': 'solar_flare',
    })!;
    expect(s.parkCause, 'solar_flare');
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
      'parkCause': 42,
    })!;
    expect(s.parkKind, isNull);
    expect(s.parkedUntil, isNull);
    expect(s.parkCause, isNull);
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

  group('quick choices', () {
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
        // A whitespace-only or control-character label draws a blank or
        // garbled button — the judge now authors this label, so the wire's
        // own tightening must be mirrored here, not only on `text`.
        [
          approve,
          {'choiceId': 'reject', 'label': '   ', 'text': 'no'},
        ],
        [
          approve,
          {'choiceId': 'reject', 'label': 'Reject\x01', 'text': 'no'},
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

    test('reads a choice cost, and drops a malformed one without losing the card', () {
      final withCost = {...approve, 'cost': 'Runs the merge now.'};
      final e = HandlerEscalation.fromWire(
        't1',
        escalationWire(choices: [withCost, reject]),
      )!;
      expect(e.choices, hasLength(2));
      expect(e.choices![0].cost, 'Runs the merge now.');
      // reject carries no cost at all — absence, not a dropped field.
      expect(e.choices![1].cost, isNull);

      for (final badCost in <Object>['x' * 161, '   ', 7]) {
        final withBadCost = {...approve, 'cost': badCost};
        final degraded = HandlerEscalation.fromWire(
          't1',
          escalationWire(choices: [withBadCost, reject]),
        )!;
        // A malformed cost is a missing sub-line, not a reason to drop the
        // whole chip — unlike label/text, which keep reject-the-row polarity.
        expect(degraded.choices, hasLength(2), reason: '$badCost');
        expect(degraded.choices![0].cost, isNull, reason: '$badCost');
        expect(degraded.choices![0].label, 'Approve', reason: '$badCost');
      }
    });
  });

  group('the ask fields', () {
    const keep = {
      'choiceId': 'keep',
      'label': 'Keep the current schema and note the gap',
      'cost': 'Leaves the migration for later',
    };
    const migrate = {
      'choiceId': 'migrate',
      'label': 'Write the migration now',
      'cost': 'Another twenty minutes before the tests run',
      'recommended': true,
    };
    Map<String, dynamic> askWire({
      Object? nonBlocking,
      Object? unblocked,
      Object? askOptions,
    }) => {
      'escalationId': 'e1',
      'question': 'which shape?',
      'reasoning': 'r',
      'draftReply': '',
      'urgency': 'normal',
      'at': 1,
      'nonBlocking': ?nonBlocking,
      'unblocked': ?unblocked,
      'askOptions': ?askOptions,
    };

    test('an ordinary row carries the conservative default for each', () {
      // Absent is what every row before these fields meant, and what an older
      // bridge — or one that stripped them on a downgrade — still says.
      final e = HandlerEscalation.fromWire('t1', askWire())!;
      expect(e.nonBlocking, isFalse);
      expect(e.unblocked, isEmpty);
      expect(e.askOptions, isNull);
    });

    test('a well-formed ask carries all three', () {
      final e = HandlerEscalation.fromWire(
        't1',
        askWire(
          nonBlocking: true,
          unblocked: ['i1', 'i2'],
          askOptions: [keep, migrate],
        ),
      )!;
      expect(e.nonBlocking, isTrue);
      expect(e.unblocked, ['i1', 'i2']);
      expect(e.askOptions, hasLength(2));
      expect(e.askOptions![0].choiceId, 'keep');
      expect(e.askOptions![0].label, contains('Keep the current schema'));
      expect(e.askOptions![0].cost, isNotEmpty);
      expect(e.askOptions![0].recommended, isFalse);
      expect(e.askOptions![1].recommended, isTrue);
      // Parsed as its own shape and never into `choices`, which is the whole
      // reason a tap on one cannot reach the session.
      expect(e.choices, isNull);
      expect(e.choiceById('keep'), isNull);
    });

    test('a non-bool nonBlocking reads as blocking and keeps the row', () {
      // The wrong-typed value costs the ask treatment, never the question:
      // dropping the row would leave the user with nothing to answer.
      final e = HandlerEscalation.fromWire('t1', askWire(nonBlocking: 'yes'));
      expect(e, isNotNull);
      expect(e!.nonBlocking, isFalse);
      expect(e.question, 'which shape?');
    });

    test('a malformed unblocked degrades to naming nothing', () {
      // The claim is re-derived against the live backlog anyway, so a lost id
      // costs a smaller count and never a wrong one.
      expect(
        HandlerEscalation.fromWire('t1', askWire(unblocked: 'i1'))!.unblocked,
        isEmpty,
      );
      expect(
        HandlerEscalation.fromWire(
          't1',
          askWire(unblocked: ['i1', 7]),
        )!.unblocked,
        ['i1'],
      );
    });

    test('a bad options list drops the options, not the question', () {
      for (final bad in <Object>[
        [keep],
        [keep, migrate, keep, migrate, keep],
        [keep, 'nope'],
        [
          keep,
          {'choiceId': '', 'label': 'Write it', 'cost': 'time'},
        ],
        [
          keep,
          {'choiceId': 'migrate', 'label': '', 'cost': 'time'},
        ],
        [
          keep,
          {'choiceId': 'migrate', 'label': 'x' * 81, 'cost': 'time'},
        ],
        [
          keep,
          {'choiceId': 'migrate', 'label': 'Write it', 'cost': ''},
        ],
        [
          keep,
          {'choiceId': 'migrate', 'label': 'Write it', 'cost': 'x' * 161},
        ],
        [
          keep,
          {'choiceId': 'z' * 41, 'label': 'Write it', 'cost': 'time'},
        ],
        // A tap is resolved by first match, so a repeated id would answer with
        // an option the user did not read.
        [
          keep,
          {'choiceId': 'keep', 'label': 'Keep it and move on', 'cost': 'time'},
        ],
        'askOptions',
      ]) {
        final e = HandlerEscalation.fromWire(
          't1',
          askWire(nonBlocking: true, askOptions: bad),
        );
        expect(e, isNotNull, reason: '$bad');
        expect(e!.askOptions, isNull, reason: '$bad');
        // The ask itself survives — it is still answerable in the user's own
        // words.
        expect(e.nonBlocking, isTrue, reason: '$bad');
      }
    });

    test('anything but the wire true reads as not recommended', () {
      // The wire spells it `true`-or-absent, so a second spelling must not
      // become a second emphasised option.
      final e = HandlerEscalation.fromWire(
        't1',
        askWire(
          askOptions: [
            {...keep, 'recommended': false},
            {...migrate, 'recommended': 'yes'},
          ],
        ),
      )!;
      expect(e.askOptions!.every((o) => !o.recommended), isTrue);
    });

    test('withoutChoices and copyWith both carry all three', () {
      final e = HandlerEscalation.fromWire(
        't1',
        askWire(
          nonBlocking: true,
          unblocked: ['i1'],
          askOptions: [keep, migrate],
        ),
      )!;
      final withdrawn = e.withoutChoices();
      expect(withdrawn.nonBlocking, isTrue);
      expect(withdrawn.unblocked, ['i1']);
      expect(withdrawn.askOptions, hasLength(2));

      final unchanged = e.copyWith();
      expect(unchanged.nonBlocking, isTrue);
      expect(unchanged.unblocked, ['i1']);
      expect(unchanged.askOptions, hasLength(2));
      expect(unchanged.question, 'which shape?');
      expect(unchanged.at, 1);
    });

    test('copyWith is the only way to strip the options', () {
      // Passing null cannot mean "clear" — it is indistinguishable from
      // omitting the argument — so the downgrade the capability gate performs
      // needs the explicit flag, and the two halves of an ask move together.
      final e = HandlerEscalation.fromWire(
        't1',
        askWire(nonBlocking: true, askOptions: [keep, migrate]),
      )!;
      expect(e.copyWith(askOptions: null).askOptions, hasLength(2));
      final downgraded = e.copyWith(nonBlocking: false, clearAskOptions: true);
      expect(downgraded.nonBlocking, isFalse);
      expect(downgraded.askOptions, isNull);
      expect(downgraded.question, 'which shape?');
    });
  });

  group('the ask capability on a session snapshot', () {
    Map<String, dynamic> sessionWire({
      Object? askAnswer,
      Object? askAnswerPending,
      List<Map<String, dynamic>> escalations = const [],
    }) => {
      'terminalId': 't1',
      'state': 'needs_you',
      'pendingEscalations': escalations.length,
      'armedAt': 1,
      'goal': 'g',
      'backlog': <Map<String, dynamic>>[],
      'escalations': escalations,
      'askAnswer': ?askAnswer,
      'askAnswerPending': ?askAnswerPending,
    };
    Map<String, dynamic> escWire(String id, {bool nonBlocking = false}) => {
      'escalationId': id,
      'question': 'q',
      'reasoning': 'r',
      'draftReply': '',
      'urgency': 'normal',
      'at': 1,
      'nonBlocking': nonBlocking,
    };

    test('a bridge that advertises neither reads as neither', () {
      final s = HandlerSessionState.fromWire(sessionWire())!;
      expect(s.askAnswer, isFalse);
      expect(s.askAnswerPending, isFalse);
    });

    test('both flags are carried, and a wrong type degrades to false', () {
      final on = HandlerSessionState.fromWire(
        sessionWire(askAnswer: true, askAnswerPending: true),
      )!;
      expect(on.askAnswer, isTrue);
      expect(on.askAnswerPending, isTrue);

      // Losing the armed card over a wrong-typed capability flag would be far
      // worse than losing the capability.
      final junk = HandlerSessionState.fromWire(
        sessionWire(askAnswer: 'yes', askAnswerPending: 1),
      );
      expect(junk, isNotNull);
      expect(junk!.askAnswer, isFalse);
      expect(junk.askAnswerPending, isFalse);
    });

    test('asksOnly is true only while every standing row is an ask', () {
      expect(
        HandlerSessionState.fromWire(
          sessionWire(
            escalations: [
              escWire('e1', nonBlocking: true),
              escWire('e2', nonBlocking: true),
            ],
          ),
        )!.asksOnly,
        isTrue,
      );
      // A guard_blocked report parses as blocking, so one of them keeps the
      // loud word for the whole session.
      expect(
        HandlerSessionState.fromWire(
          sessionWire(
            escalations: [escWire('e1', nonBlocking: true), escWire('e2')],
          ),
        )!.asksOnly,
        isFalse,
      );
      // Nothing standing is not "only asks" — it is nothing.
      expect(HandlerSessionState.fromWire(sessionWire())!.asksOnly, isFalse);
    });

    test('copyWith carries both flags', () {
      final s = HandlerSessionState.fromWire(
        sessionWire(askAnswer: true, askAnswerPending: true),
      )!;
      final narrowed = s.copyWith(pendingEscalations: 0);
      expect(narrowed.askAnswer, isTrue);
      expect(narrowed.askAnswerPending, isTrue);
    });

    // A second, independent capability flag: this one gates a `delivered` note
    // on a BLOCKING row, not `askAnswer`'s tap on a standing ask.
    test('escalationAnswer reads true only when the bridge advertised it', () {
      final on = HandlerSessionState.fromWire({
        ...sessionWire(),
        'escalationAnswer': true,
      })!;
      expect(on.escalationAnswer, isTrue);

      final off = HandlerSessionState.fromWire(sessionWire())!;
      expect(off.escalationAnswer, isFalse);

      final junk = HandlerSessionState.fromWire({
        ...sessionWire(),
        'escalationAnswer': 'yes',
      });
      expect(junk, isNotNull);
      expect(junk!.escalationAnswer, isFalse);
    });

    test('copyWith carries escalationAnswer', () {
      final s = HandlerSessionState.fromWire({
        ...sessionWire(),
        'escalationAnswer': true,
      })!;
      expect(s.copyWith(pendingEscalations: 0).escalationAnswer, isTrue);
    });
  });

  group('the instruction window on a session snapshot', () {
    Map<String, dynamic> sessionWire({
      Object? goal = 'g',
      Object? instructions,
    }) => {
      'terminalId': 't1',
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': goal,
      'backlog': <Map<String, dynamic>>[],
      'escalations': <Map<String, dynamic>>[],
      'instructions': ?instructions,
    };

    test('a full nested object parses', () {
      final s = HandlerSessionState.fromWire(
        sessionWire(
          instructions: {
            'total': 7,
            'items': ['ship the parser', 'also add a changelog'],
          },
        ),
      )!;
      expect(s.instructions, ['ship the parser', 'also add a changelog']);
      expect(s.instructionsTotal, 7);
      expect(s.askedFor, s.instructions);
      expect(s.askedForTotal, 7);
    });

    test('the object absent falls back to [goal]/1 through the getters '
        'while the raw fields stay empty', () {
      final s = HandlerSessionState.fromWire(sessionWire())!;
      expect(s.instructions, isEmpty);
      expect(s.instructionsTotal, 1);
      // The raw fields are what an older bridge means; the getters are what a
      // surface actually renders — and must read exactly as this session did
      // before this field existed.
      expect(s.askedFor, ['g']);
      expect(s.askedForTotal, 1);
    });

    test('an empty goal and no object gives const []/0', () {
      final s = HandlerSessionState.fromWire(sessionWire(goal: ''))!;
      expect(s.instructions, isEmpty);
      expect(s.instructionsTotal, 0);
      expect(s.askedFor, isEmpty);
      expect(s.askedForTotal, 0);
    });

    test('a malformed items value degrades without losing the session', () {
      final s = HandlerSessionState.fromWire(
        sessionWire(instructions: {'total': 3, 'items': 'not a list'}),
      );
      expect(s, isNotNull);
      expect(s!.instructions, isEmpty);
      // Falls back the same way absence does: the bridge sent a shape this
      // build can't read, which is not evidence there is nothing to show.
      expect(s.instructionsTotal, 1);
      expect(s.askedFor, ['g']);
    });

    test('a total smaller than items.length is clamped up', () {
      final s = HandlerSessionState.fromWire(
        sessionWire(
          instructions: {
            'total': 1,
            'items': ['first', 'second', 'third'],
          },
        ),
      )!;
      expect(s.instructions, hasLength(3));
      // A bad total would otherwise RENDER as "3 items, 1 total" — a claim the
      // frame itself disproves.
      expect(s.instructionsTotal, 3);
      expect(s.askedForTotal, 3);
    });

    test('a window smaller than total keeps the total', () {
      final s = HandlerSessionState.fromWire(
        sessionWire(
          instructions: {
            'total': 12,
            'items': ['ship the parser', 'also add a changelog'],
          },
        ),
      )!;
      expect(s.instructions, hasLength(2));
      expect(s.instructionsTotal, 12);
      expect(s.askedForTotal - s.askedFor.length, 10);
    });

    test('copyWith carries instructions and instructionsTotal', () {
      // `_applyEscalationFloors` (handler_service.dart) runs this on every
      // session on every emit — a field missing from copyWith's body resets
      // silently here, with every fromWire test above still green.
      final s = HandlerSessionState.fromWire(
        sessionWire(
          instructions: {
            'total': 4,
            'items': ['ship the parser'],
          },
        ),
      )!;
      final narrowed = s.copyWith(pendingEscalations: 0);
      expect(narrowed.instructions, ['ship the parser']);
      expect(narrowed.instructionsTotal, 4);
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

  group('forTerminal', () {
    HandlerSnapshot snap(String id, String terminalId) => HandlerSnapshot(
      snapshotId: id,
      terminalId: terminalId,
      at: 1,
      action: 'reset_hard',
      trigger: 'git reset --hard HEAD~1',
      summary: 'stashed 3 files',
      state: 'available',
    );
    HandlerActivityRecord rec(String id, String terminalId) =>
        HandlerActivityRecord(
          recordId: id,
          at: 1,
          terminalId: terminalId,
          decision: 'handle',
          reason: 'answered the lint prompt',
        );
    HandlerWrapUp wrap(String id, String terminalId) => HandlerWrapUp(
      wrapUpId: id,
      terminalId: terminalId,
      at: 1,
      goal: 'ship it',
      outcomes: const [],
      blockedTotal: 0,
      blockedReasons: const [],
    );

    final mixed = HandlerState(
      defaultTool: 'claude',
      sessions: {
        't1': _session('t1', pending: 1),
        't2': _session('t2', pending: 2),
      },
      escalations: [
        _esc('e1', urgency: 'normal', at: 1),
        HandlerEscalation(
          escalationId: 'e2',
          terminalId: 't2',
          question: 'q',
          reasoning: 'r',
          draftReply: 'd',
          urgency: 'normal',
          at: 2,
        ),
      ],
      activity: [rec('r1', 't1'), rec('r2', 't2')],
      snapshots: [snap('s1', 't1'), snap('s2', 't2')],
      wrapUps: [wrap('w1', 't1'), wrap('w2', 't2')],
      pendingUndo: const {'s1', 's2'},
      pendingInstructions: const {
        't1': ['rename the codec'],
        't2': ['bump the fixture'],
      },
    );

    test('keeps every collection to the terminal asked for', () {
      final one = mixed.forTerminal('t1');
      expect(one.sessions.keys, ['t1']);
      expect(one.escalations.map((e) => e.escalationId), ['e1']);
      expect(one.activity.map((a) => a.recordId), ['r1']);
      expect(one.snapshots.map((s) => s.snapshotId), ['s1']);
      expect(one.wrapUps.map((w) => w.wrapUpId), ['w1']);
      expect(one.pendingInstructionsFor('t1'), ['rename the codec']);
      expect(one.pendingInstructionsFor('t2'), isEmpty);
    });

    test('drops a pending undo whose offer it no longer holds', () {
      // The id would otherwise mark a row that is not on this screen, and
      // outlive the offer it belongs to.
      expect(mixed.forTerminal('t1').pendingUndo, {'s1'});
    });

    test('carries the project judge default through', () {
      // Project-wide by definition, and the session card resolves its judge
      // label against it.
      expect(mixed.forTerminal('t1').defaultTool, 'claude');
      expect(mixed.forTerminal(null).defaultTool, 'claude');
    });

    test('narrows an unfocused screen to nothing, never to everything', () {
      // An unresolved focus names no session, so answering it with the whole
      // project's state would undo the narrowing exactly when it is needed.
      final none = mixed.forTerminal(null);
      expect(none.anyArmed, isFalse);
      expect(none.escalations, isEmpty);
      expect(none.activity, isEmpty);
      expect(none.snapshots, isEmpty);
      expect(none.wrapUps, isEmpty);
    });

    test('a terminal with nothing armed still keeps its leftovers', () {
      // Disarm is not the end of the session: the undo it took and the report
      // it wrote are read afterwards, on this same tab. With every session
      // gone, every offer is an orphan — and an orphan belongs to no live
      // session, so no focus can be moved to reach it.
      final after = mixed.copyWith(sessions: const {}).forTerminal('t1');
      expect(after.anyArmed, isFalse);
      expect(after.snapshots.map((s) => s.snapshotId), ['s1', 's2']);
      expect(after.wrapUps.map((w) => w.wrapUpId), ['w1', 'w2']);
    });

    test('an offer whose session is gone is never stranded', () {
      // A wrap-up DISARMS the session it reports on, so filtering these by
      // terminalId alone would hide the account of every finished session — and
      // the undo offer behind it — behind a focus that can never name it again.
      // A live session still owns its own, so the narrowing holds where it can.
      final t2Done = mixed.copyWith(
        sessions: {'t1': _session('t1', pending: 1)},
      );
      final one = t2Done.forTerminal('t1');
      expect(one.snapshots.map((s) => s.snapshotId), ['s1', 's2']);
      expect(one.wrapUps.map((w) => w.wrapUpId), ['w1', 'w2']);
      // The per-session collections stay narrowed regardless.
      expect(one.sessions.keys, ['t1']);
      expect(one.activity.map((a) => a.recordId), ['r1']);
    });

    test('leaves the project-wide count alone for the surfaces that need it', () {
      // The agent bar's NEEDS YOU pill reads the unnarrowed state; narrowing in
      // place would take away the only thing saying another session is waiting.
      expect(mixed.pendingEscalations, 3);
      expect(mixed.forTerminal('t1').pendingEscalations, 1);
    });
  });

  group('the lens on the wire', () {
    Map<String, dynamic> wire({String? role, String? brief}) => {
      'terminalId': 't1',
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'ship it',
      'backlog': const [],
      'role': ?role,
      'brief': ?brief,
    };

    test('every lens this build knows round-trips', () {
      for (final lens in HandlerLens.values) {
        final s = HandlerSessionState.fromWire(
          wire(role: handlerLensToWire(lens)),
        )!;
        expect(s.roleId, handlerLensToWire(lens));
        expect(s.role, lens);
      }
    });

    test('no role is the unnamed default, said as absence', () {
      // Never resolved to a lens here: the default is the rules alone, and a
      // model that named it would make the absence unreadable.
      final s = HandlerSessionState.fromWire(wire())!;
      expect(s.roleId, isNull);
      expect(s.role, isNull);
    });

    test('a lens this build cannot name is kept as itself', () {
      // A newer bridge's id must reach the bar as the string it sent: shown as
      // the default it would claim the session judges under something it does
      // not, and one tap on the default would look like a no-op.
      final s = HandlerSessionState.fromWire(wire(role: 'ship-it'))!;
      expect(s.roleId, 'ship-it');
      expect(s.role, isNull);
      expect(handlerLensFromWire('ship-it'), isNull);
      expect(handlerLensFromWire(42), isNull);
    });

    test('a brief is what it says, or nothing', () {
      expect(HandlerSessionState.fromWire(wire())!.brief, isNull);
      // Empty is nothing rather than a brief that says nothing — the bridge
      // omits the key once it clears, and a surface marking one would claim a
      // brief the judge never prints.
      expect(HandlerSessionState.fromWire(wire(brief: ''))!.brief, isNull);
      expect(
        HandlerSessionState.fromWire(
          wire(brief: 'watch the migrations'),
        )!.brief,
        'watch the migrations',
      );
    });

    test('a copy carries the lens and the brief', () {
      // copyWith is how the service rewrites run state and escalations; a lens
      // dropped there would vanish from the bar on the next frame.
      final s = HandlerSessionState.fromWire(
        wire(role: 'qa', brief: 'show the failing case'),
      )!;
      final moved = s.copyWith(runState: HandlerRunState.handling);
      expect(moved.roleId, 'qa');
      expect(moved.brief, 'show the failing case');
    });

    test('no lens copy names the line it must not move', () {
      // The presets this replaced were about where handling gave way to
      // escalating. A tripwire, not a ban on the words: copy drifting back to
      // describing that line is the failure this whole change exists to end,
      // and the bridge's own lens table is pinned the same way.
      final gating = RegExp('escalat|handl', caseSensitive: false);
      expect(gating.hasMatch(handlerLensDefaultLabel), isFalse);
      expect(gating.hasMatch(handlerLensBlurb(null)), isFalse);
      // The captions that qualify a lens are pinned with the lens copy itself:
      // they sit in the same block on the same surface, and copy about a
      // control is exactly where a threshold gets described by accident.
      for (final caption in [
        handlerLensParkedBlurb,
        handlerLensUnreportedBlurb,
        handlerLensUnsetBlurb,
        handlerLensUnknownBlurb,
      ]) {
        expect(gating.hasMatch(caption), isFalse, reason: caption);
      }
      for (final lens in HandlerLens.values) {
        expect(
          gating.hasMatch(handlerLensBlurb(lens)),
          isFalse,
          reason: '${handlerLensLabel(lens)} blurb describes the handle line',
        );
        // The label is the chip's whole face, and the word most likely to be
        // rewritten toward a dial ("Handles releases").
        expect(
          gating.hasMatch(handlerLensLabel(lens)),
          isFalse,
          reason: '${handlerLensToWire(lens)} label describes the handle line',
        );
      }
    });

    test('a posture an old bridge still names is not a lens', () {
      // A rolled-back bridge can still put a preset on the wire. It resolves
      // to no lens rather than to one of the four: the presets moved a line a
      // lens does not move, so mapping one would claim the session judges
      // under something nobody chose — and the session itself must survive it.
      final s = HandlerSessionState.fromWire({
        'terminalId': 't1',
        'state': 'watching',
        'pendingEscalations': 0,
        'armedAt': 1,
        'goal': 'ship it',
        'backlog': const [],
        'personality': 'watchdog',
      })!;
      expect(s.roleId, isNull);
      expect(s.role, isNull);
      expect(s.brief, isNull);
      expect(s.goal, 'ship it');
      expect(s.runState, HandlerRunState.watching);
    });
  });

  group('the lenses a bridge advertises', () {
    Map<String, dynamic> status({Object? lenses}) => {
      'type': 'handler:status',
      'id': 'm1',
      'timestamp': 1,
      'projectId': 'p',
      'sessions': const [],
      'lenses': ?lenses,
    };

    test('a named list is carried, entry by entry', () {
      final msg =
          parseAbMessage(status(lenses: ['pm', 'qa'])) as HandlerStatusMessage;
      expect(msg.lenses, ['pm', 'qa']);
    });

    test('a bridge that never said stays null, not empty', () {
      // Presence IS the capability signal, so the two cannot be folded: empty
      // would be a bridge offering no lens, which is a different fact and
      // would leave a picker enabled with nothing in it.
      expect((parseAbMessage(status()) as HandlerStatusMessage).lenses, isNull);
      final malformed =
          parseAbMessage(status(lenses: 'pm')) as HandlerStatusMessage;
      expect(malformed.lenses, isNull);
    });

    test('the project state carries it, narrowing included', () {
      // Project-wide like defaultTool: the arm sheet reads it with no session
      // named, which is exactly what forTerminal(null) leaves.
      const state = HandlerState.initial();
      expect(state.lenses, isNull);
      final advertised = state.copyWith(lenses: const ['pm', 'release']);
      expect(advertised.lenses, ['pm', 'release']);
      expect(advertised.forTerminal(null).lenses, ['pm', 'release']);
      expect(advertised.forTerminal('t1').lenses, ['pm', 'release']);
    });
  });

  group('HandlerEntitlement.fromWire', () {
    test('a refusal round-trips with the plan it names', () {
      final e = HandlerEntitlement.fromWire({
        'reason': 'not_entitled',
        'tier': 'free',
      })!;
      expect(e.reason, HandlerEntitlementReason.notEntitled);
      expect(e.tier, 'free');
    });

    test('an unreadable claim names no tier, because it has none to name', () {
      final e = HandlerEntitlement.fromWire({'reason': 'unreadable'})!;
      expect(e.reason, HandlerEntitlementReason.unreadable);
      expect(e.tier, isNull);
    });

    test('a reason this app cannot name is still a refusal', () {
      // Dropping it would restore the silence the field exists to end, and
      // guessing which of the two known reasons it is would prescribe a fix
      // that may be the wrong one — so the refusal stands with no reason.
      final e = HandlerEntitlement.fromWire({'reason': 'seat_revoked'})!;
      expect(e.reason, isNull);
    });

    test('nothing, or a malformed payload, is not a refusal', () {
      // Presence is the whole signal, so inventing one out of noise would gate
      // arming with nothing to say about why.
      expect(HandlerEntitlement.fromWire(null), isNull);
      expect(HandlerEntitlement.fromWire('not_entitled'), isNull);
      expect(HandlerEntitlement.fromWire({'tier': 'free'}), isNull);
    });
  });

  group('entitlement on the project state', () {
    const refused = HandlerEntitlement(
      reason: HandlerEntitlementReason.notEntitled,
      tier: 'free',
    );

    test('a refusal can be cleared, not only set', () {
      // An upgrade lifts it, and a gate that could only ever latch on would
      // outlive the thing it describes with no frame able to correct it.
      final gated = const HandlerState.initial().copyWith(entitlement: refused);
      expect(gated.entitlement, refused);
      expect(gated.copyWith(clearEntitlement: true).entitlement, isNull);
      // An untouched copy carries it, like every other field here.
      expect(gated.copyWith(defaultTool: 'claude-code').entitlement, refused);
    });

    test('it survives a narrowing that names no session', () {
      // Project-scoped like defaultTool: the shield that most needs it sits
      // over a session that is not armed, which is exactly when forTerminal
      // has nothing to narrow to.
      final state = const HandlerState.initial().copyWith(entitlement: refused);
      expect(state.forTerminal(null).entitlement, refused);
      expect(state.forTerminal('t1').entitlement, refused);
    });
  });
}
