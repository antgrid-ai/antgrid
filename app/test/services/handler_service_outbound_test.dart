import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/handler_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _newSession(FakeAgentTransport t) async {
  useInMemoryPrefs();
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'p',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await t.dispose(),
  );
}

HandlerSnapshot _snapshot({String state = 'available'}) => HandlerSnapshot(
  snapshotId: 's1',
  terminalId: 't1',
  at: 5,
  action: 'force_push',
  trigger: 'git push --force origin feat/x',
  summary: 'pre-push SHA abc1234 recorded',
  state: state,
);

const _item = HandlerInstructionItem(
  id: 'i1',
  text: 'open PR',
  status: 'queued',
  createdAt: 7,
);

/// What the extractor made of an instruction — the append that answers it.
const _extracted = HandlerInstructionItem(
  id: 'i2',
  text: 'rerun the tests',
  status: 'queued',
  createdAt: 8,
);

Map<String, dynamic> _session(
  String terminalId,
  List<HandlerInstructionItem> backlog,
) => {
  'terminalId': terminalId,
  'notifyOnly': false,
  'state': 'watching',
  'pendingEscalations': 0,
  'armedAt': 1,
  // Required by HandlerSessionState.fromWire: a snapshot without it parses to
  // null, and the session is silently absent from the state under test.
  'goal': 'ship the fix',
  'backlog': [for (final i in backlog) i.toWire()],
};

/// One `handler:status`, carrying t1 plus whatever else is armed. The engine
/// serialises every armed session on every frame, so [others] is how a test
/// reaches the case that matters: a frame t1 had no part in raising.
void _status(
  FakeAgentTransport t,
  List<HandlerInstructionItem> backlog, {
  List<Map<String, dynamic>> others = const [],
}) => t.emit('handler:status', {
  'projectId': 'p',
  'sessions': [_session('t1', backlog), ...others],
});

void main() {
  test('a 1-tap arm sends armed:true and no payload keys', () async {
    // Spec §4.1: arming must not require a form, so an arm with no goal and no
    // backlog has to be a complete message. Sending either key as an empty
    // value would clear whatever the bridge already holds for the session.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.arm(terminalId: 't1', notifyOnly: true);

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['projectId'], 'p');
    expect(sent['terminalId'], 't1');
    expect(sent['armed'], true);
    expect(sent['notifyOnly'], true);
    expect(sent.containsKey('goal'), isFalse);
    expect(sent.containsKey('backlog'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('arm serializes goal and backlog when given', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.arm(
      terminalId: 't1',
      goal: 'ship the feature',
      backlog: const [_item],
      notifyOnly: false,
    );

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['goal'], 'ship the feature');
    expect(sent['backlog'], [_item.toWire()]);

    await svc.dispose();
    await session.close();
  });

  test('an explicit empty backlog is sent, unlike an absent one', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.arm(terminalId: 't1', backlog: const [], notifyOnly: false);

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['backlog'], isEmpty);

    await svc.dispose();
    await session.close();
  });

  test('disarm sends armed:false alone', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.disarm('t1');

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['projectId'], 'p');
    expect(sent['terminalId'], 't1');
    expect(sent['armed'], false);
    expect(sent.containsKey('goal'), isFalse);
    expect(sent.containsKey('backlog'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('instruct sends handler:instruct carrying text only', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.instruct('t1', 'also update the changelog');

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:instruct');
    expect(sent['projectId'], 'p');
    expect(sent['terminalId'], 't1');
    expect(sent['text'], 'also update the changelog');
    // The bridge mints ids and owns the backlog; anything id- or item-shaped
    // arriving from the app would be a second, colliding source of them.
    expect(sent.containsKey('backlog'), isFalse);
    expect(sent.containsKey('armed'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('instruct with blank text is a no-op', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.instruct('t1', '   \n ');

    expect(t.sent.any((m) => m['type'] == 'handler:instruct'), false);

    await svc.dispose();
    await session.close();
  });

  test('instruct records the sentence and appends no item', () async {
    // The bridge echoes the extracted backlog on handler:status; a local
    // append would race that snapshot. The sentence itself is held instead —
    // it is the only thing there is to show for the seconds extraction takes,
    // and it claims nothing about the items it becomes.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    expect(
      svc.instruct('t1', 'and rerun the tests'),
      HandlerInstructResult.sent,
    );

    expect(svc.currentState.pendingInstructionsFor('t1'), [
      'and rerun the tests',
    ]);
    expect(svc.currentState.sessions, isEmpty);

    // The bridge appends and absorbs no duplicate, so the same sentence is
    // refused for as long as it is outstanding — and named as a duplicate, not
    // as an empty send, because the two are owed different answers on screen.
    expect(
      svc.instruct('t1', 'and rerun the tests'),
      HandlerInstructResult.duplicate,
    );
    expect(t.sent.where((m) => m['type'] == 'handler:instruct'), hasLength(1));

    await svc.dispose();
    await session.close();
  });

  test('a grown backlog retires the instruction that grew it', () async {
    // An instruct is unacknowledged and extraction rewrites its text, so the
    // items themselves can never be matched to the sentence that asked for
    // them. The backlog's own length is what can: extraction appends, so a list
    // that is no longer the length it was has been rewritten since the send.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.instruct('t1', 'and rerun the tests');
    _status(t, [_item]);
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.pendingInstructionsFor('t1'), isEmpty);
    expect(
      svc.instruct('t1', 'and rerun the tests'),
      HandlerInstructResult.sent,
    );

    await svc.dispose();
    await session.close();
  });

  test('another terminal\'s status frame retires nothing', () async {
    // emitStatus serialises EVERY armed session on every handler event, twice,
    // so a second armed terminal's ordinary supervision raises a frame within
    // milliseconds of the send. Retiring on the frame alone took the row away
    // mid-extraction, lifted the debounce, and unlocked the drawer inside the
    // one window its edit lock exists to cover.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    _status(t, [_item]);
    await Future<void>.delayed(Duration.zero);
    svc.instruct('t1', 'and rerun the tests');

    _status(t, [_item], others: [_session('t2', const [])]);
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.pendingInstructionsFor('t1'), [
      'and rerun the tests',
    ]);
    expect(
      svc.instruct('t1', 'and rerun the tests'),
      HandlerInstructResult.duplicate,
    );

    await svc.dispose();
    await session.close();
  });

  test('a disarmed terminal retires what it can no longer append', () async {
    // Nothing is left to grow the backlog, and a sentence outliving its session
    // reads as work Handler is holding — and holds the drawer's edit lock with
    // it, indefinitely.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    _status(t, [_item]);
    await Future<void>.delayed(Duration.zero);
    svc.instruct('t1', 'and rerun the tests');

    t.emit('handler:status', {'projectId': 'p', 'sessions': <dynamic>[]});
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.pendingInstructionsFor('t1'), isEmpty);

    await svc.dispose();
    await session.close();
  });

  test('a dropped instruction retires on its activity record', () async {
    // A backlog at the bridge's cap appends nothing and emits no status at all,
    // so this record is the whole outcome. Left unretired it holds the edit
    // lock forever — and under a full backlog, deleting an item is the only
    // thing that would free room.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    _status(t, [_item]);
    await Future<void>.delayed(Duration.zero);
    svc.instruct('t1', 'and rerun the tests');

    t.emit('handler:activity', {
      'projectId': 'p',
      'recordId': 'r1',
      'at': 9,
      'terminalId': 't1',
      'decision': 'instruction_dropped',
      'reason': 'backlog is full (100 items)',
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.pendingInstructionsFor('t1'), isEmpty);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  test('updateBacklog is refused while an instruction is outstanding', () async {
    // Every edit is a wholesale replace and extraction appends behind it, so a
    // list built while one is in flight deletes the items the user just asked
    // for. The floor is here rather than on the drawer: this is the only way an
    // edit reaches the wire.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    _status(t, [_item]);
    await Future<void>.delayed(Duration.zero);
    svc.instruct('t1', 'and rerun the tests');
    t.clearSent();

    // Reported, not just silent: a surface holding text the user typed has to
    // be able to keep it rather than close over a send that never happened.
    expect(
      svc.updateBacklog(
        terminalId: 't1',
        backlog: const [],
        notifyOnly: false,
      ),
      isFalse,
    );
    expect(t.sent.any((m) => m['type'] == 'handler:configure'), isFalse);

    _status(t, [_item, _extracted]);
    await Future<void>.delayed(Duration.zero);
    expect(
      svc.updateBacklog(
        terminalId: 't1',
        backlog: const [],
        notifyOnly: false,
      ),
      isTrue,
    );

    expect(t.sent.any((m) => m['type'] == 'handler:configure'), isTrue);

    await svc.dispose();
    await session.close();
  });

  test('updateBacklog sends the whole edited list, without a goal', () async {
    // The bridge replaces its backlog with what arrives, so a drawer edit is
    // only expressible as the full post-edit list — including the untouched
    // items and the item whose dependsOn was dropped.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    const edited = [
      HandlerInstructionItem(
        id: 'i2',
        text: 'run tests',
        status: 'queued',
        createdAt: 9,
      ),
      _item,
    ];
    svc.updateBacklog(terminalId: 't1', backlog: edited, notifyOnly: false);

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:configure');
    expect(sent['projectId'], 'p');
    expect(sent['terminalId'], 't1');
    expect(sent['armed'], true);
    expect(sent['backlog'], [for (final i in edited) i.toWire()]);
    // A goal riding along would re-extract into the session; the edits are
    // separate calls by design.
    expect(sent.containsKey('goal'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('updateBacklog carries the notifyOnly it was given', () async {
    // Required on the wire: the wrong value flips the session between
    // notifying and acting without saying so.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.updateBacklog(terminalId: 't1', backlog: const [], notifyOnly: true);
    expect(t.sent.last['notifyOnly'], true);

    svc.updateBacklog(terminalId: 't1', backlog: const [], notifyOnly: false);
    expect(t.sent.last['notifyOnly'], false);

    await svc.dispose();
    await session.close();
  });

  test('updateBacklog after dispose is a no-op', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    await svc.dispose();

    svc.updateBacklog(
      terminalId: 't1',
      backlog: const [_item],
      notifyOnly: false,
    );

    expect(t.sent.any((m) => m['type'] == 'handler:configure'), false);

    await session.close();
  });

  test(
    'reply still sends terminal:input with trailing CR and drops the row',
    () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:escalation', {
        'projectId': 'p',
        'escalationId': 'e1',
        'terminalId': 't9',
        'question': 'q',
        'reasoning': 'r',
        'draftReply': 'use bun',
        'urgency': 'normal',
      });
      await Future<void>.delayed(Duration.zero);
      final esc = svc.currentState.escalations.single;

      svc.reply(esc, 'use bun');

      final sent = t.sent.firstWhere((m) => m['type'] == 'terminal:input');
      expect(sent['terminalId'], 't9');
      expect(sent['data'], 'use bun\r');
      expect(svc.currentState.escalations, isEmpty);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    },
  );

  test('reply with blank text is a no-op (never sends a bare CR)', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);
    final sub = session.heavyStream.listen((_) {});

    t.emit('handler:escalation', {
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': 't9',
      'question': 'q',
      'reasoning': 'r',
      'draftReply': '',
      'urgency': 'normal',
    });
    await Future<void>.delayed(Duration.zero);
    final esc = svc.currentState.escalations.single;

    svc.reply(esc, '   '); // whitespace-only

    expect(t.sent.any((m) => m['type'] == 'terminal:input'), false);
    // Escalation is untouched — nothing was answered.
    expect(svc.currentState.escalations, isNotEmpty);

    await sub.cancel();
    await svc.dispose();
    await session.close();
  });

  group('quick-choice answers (§4.6)', () {
    const choices = [
      {'choiceId': 'approve', 'label': 'Approve', 'text': 'ship it'},
      {'choiceId': 'reject', 'label': 'Reject', 'text': 'Do not proceed.'},
    ];

    Map<String, dynamic> escalationFrame({
      String terminalId = 't9',
      Object? withChoices = choices,
    }) => {
      'projectId': 'p',
      'escalationId': 'e1',
      'terminalId': terminalId,
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'ship it',
      'urgency': 'normal',
      'choices': ?withChoices,
    };

    test('a tap sends the choice text and drops the row', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:escalation', escalationFrame());
      await Future<void>.delayed(Duration.zero);

      svc.answerWithChoice(svc.currentState.escalations.single, 'approve');

      final sent = t.sent.firstWhere((m) => m['type'] == 'terminal:input');
      // The label never reaches the session — the draft the judge composed does.
      expect(sent['data'], 'ship it\r');
      expect(svc.currentState.escalations, isEmpty);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('a tap grants no §5.4 authorization lift', () async {
      // handler:instruct is the sole feed point for instruction-scoped
      // authorization, and §5.4 derives that only from the user's own words.
      // Chip text is Assistant output, so routing a tap there would let the
      // judge's own draft authorize itself for the rest of the session — and
      // would stack an extraction item no terminal status can ever resolve.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:escalation', escalationFrame());
      await Future<void>.delayed(Duration.zero);

      svc.answerWithChoice(svc.currentState.escalations.single, 'approve');

      expect(t.sent.any((m) => m['type'] == 'handler:instruct'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'handler:configure'), isFalse);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test(
      'a chat slot takes the same agent:prompt path a typed reply does',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = HandlerService.fromSession(session);
        final sub = session.heavyStream.listen((_) {});

        t.emit('session:list:result', {
          'projectId': 'p',
          'sessions': [
            {
              'id': 'chat-1',
              'name': 'chat-1',
              'createdAt': 0,
              'lastUsedAt': 0,
              'archived': false,
              'running': true,
              'mode': 'chat',
            },
          ],
        });
        t.emit('handler:escalation', escalationFrame(terminalId: 'chat-1'));
        await Future<void>.delayed(Duration.zero);

        svc.answerWithChoice(svc.currentState.escalations.single, 'reject');

        final sent = t.sent.firstWhere((m) => m['type'] == 'agent:prompt');
        expect(sent['sessionId'], 'chat-1');
        expect(sent['text'], 'Do not proceed.');
        expect(t.sent.any((m) => m['type'] == 'terminal:input'), isFalse);

        await sub.cancel();
        await svc.dispose();
        await session.close();
      },
    );

    test('an id the escalation does not offer sends nothing', () async {
      // A notification action carries only an id, and it can outlive the
      // escalation it was minted for. Text always comes from the offered set,
      // so a stale or invented id is a no-op rather than a message.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:escalation', escalationFrame(withChoices: null));
      await Future<void>.delayed(Duration.zero);
      final plainRow = svc.currentState.escalations.single;

      svc.answerWithChoice(plainRow, 'approve');

      expect(plainRow.choices, isNull);
      expect(t.sent.any((m) => m['type'] == 'terminal:input'), isFalse);
      expect(svc.currentState.escalations, isNotEmpty);

      // The row is still answerable in the user's own words — spec §4.6's
      // [Custom Reply] escape hatch is what keeps an unanticipated situation
      // from dead-ending at 3am.
      svc.reply(plainRow, 'actually, rebase first');
      expect(t.sent.last['data'], 'actually, rebase first\r');

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    /// A `handler:status` snapshot replaying [escalations] on one armed session
    /// — what the bridge sends on reconnect, and what it also sends twice per
    /// handler event on any session in the project.
    Map<String, dynamic> statusFrame(
      List<Map<String, dynamic>> escalations, {
      String terminalId = 't9',
    }) => {
      'projectId': 'p',
      'sessions': [
        {
          'terminalId': terminalId,
          'notifyOnly': false,
          'state': escalations.isEmpty ? 'watching' : 'needs_you',
          'pendingEscalations': escalations.length,
          'armedAt': 1,
          'goal': 'ship it',
          'backlog': <Object>[],
          'escalations': escalations,
        },
      ],
    };

    Map<String, dynamic> replayed({
      String escalationId = 'e1',
      Object? withChoices = choices,
      String? kind,
    }) => {
      'escalationId': escalationId,
      'question': 'q',
      'reasoning': 'r',
      'draftReply': 'ship it',
      'urgency': 'normal',
      'at': 1,
      'kind': ?kind,
      'choices': ?withChoices,
    };

    test('a status frame that predates the answer cannot re-arm the tap', () async {
      // The bridge computes a snapshot before the answer reaches it and the app
      // rebuilds its escalation list wholesale from one, so the answered row
      // comes back. It must come back as free text: nothing absorbs a duplicate
      // reply the way the bridge serializes undo per id.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', statusFrame([replayed()]));
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.escalations.single.choices, hasLength(2));

      svc.answerWithChoice(svc.currentState.escalations.single, 'approve');
      expect(t.sent.where((m) => m['type'] == 'terminal:input'), hasLength(1));

      t.emit('handler:status', statusFrame([replayed()]));
      await Future<void>.delayed(Duration.zero);

      final back = svc.currentState.escalations.single;
      expect(back.escalationId, 'e1');
      expect(back.choices, isNull);
      svc.answerWithChoice(back, 'approve');
      expect(t.sent.where((m) => m['type'] == 'terminal:input'), hasLength(1));

      // Still answerable in the user's own words — the card is withdrawn, the
      // question is not.
      svc.reply(back, 'on reflection, no');
      expect(t.sent.where((m) => m['type'] == 'terminal:input'), hasLength(2));

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test(
      'the suppression lifts once the bridge stops replaying the row',
      () async {
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = HandlerService.fromSession(session);
        final sub = session.heavyStream.listen((_) {});

        t.emit('handler:status', statusFrame([replayed()]));
        await Future<void>.delayed(Duration.zero);
        svc.answerWithChoice(svc.currentState.escalations.single, 'approve');

        t.emit('handler:status', statusFrame(const []));
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.escalations, isEmpty);

        // A genuinely new escalation reusing the id is a fresh question, not the
        // answered one — the suppression must not outlive the row it was for.
        t.emit('handler:status', statusFrame([replayed()]));
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.escalations.single.choices, hasLength(2));

        await sub.cancel();
        await svc.dispose();
        await session.close();
      },
    );

    test(
      'no card survives beside an option-based prompt on its terminal',
      () async {
        // Escalations stack per terminal and one submitted line clears them all,
        // bridge-side too — so a one-tap here retires the permission prompt's row
        // while answering nothing for it. The bridge withholds the card when it
        // mints in that order; this is the order it cannot see.
        final t = FakeAgentTransport();
        final session = await _newSession(t);
        final svc = HandlerService.fromSession(session);
        final sub = session.heavyStream.listen((_) {});

        t.emit('handler:escalation', escalationFrame());
        await Future<void>.delayed(Duration.zero);
        expect(svc.currentState.escalations.single.choices, hasLength(2));

        t.emit('handler:escalation', {
          ...escalationFrame(withChoices: null),
          'escalationId': 'e2',
          'kind': 'resolve_in_session',
        });
        await Future<void>.delayed(Duration.zero);

        final card = svc.currentState.escalations.firstWhere(
          (e) => e.escalationId == 'e1',
        );
        expect(card.choices, isNull);
        // Even a caller holding the pre-prompt copy cannot tap it through.
        svc.answerWithChoice(
          const HandlerEscalation(
            escalationId: 'e1',
            terminalId: 't9',
            question: 'q',
            reasoning: 'r',
            draftReply: 'ship it',
            urgency: 'normal',
            at: 1,
            choices: [
              HandlerEscalationChoice(
                choiceId: 'approve',
                label: 'Approve',
                text: 'ship it',
              ),
              HandlerEscalationChoice(
                choiceId: 'reject',
                label: 'Reject',
                text: 'Do not proceed.',
              ),
            ],
          ),
          'approve',
        );
        expect(t.sent.any((m) => m['type'] == 'terminal:input'), isFalse);

        await sub.cancel();
        await svc.dispose();
        await session.close();
      },
    );

    test('a resolve_in_session escalation answers neither way', () async {
      // Built by hand, bypassing the parse-time floor that already strips
      // choices from this kind: the option-based prompt is resolvable only by
      // the chat RPC, so text injected here would answer nothing while the
      // bridge cleared the row — a button that silently does nothing.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);

      const esc = HandlerEscalation(
        escalationId: 'e1',
        terminalId: 'chat-1',
        question: 'Agent requests permission: rm -rf build',
        reasoning: 'blocking prompt requires you',
        draftReply: '',
        urgency: 'high',
        at: 1,
        kind: 'resolve_in_session',
        choices: [
          HandlerEscalationChoice(
            choiceId: 'approve',
            label: 'Approve',
            text: 'yes',
          ),
          HandlerEscalationChoice(
            choiceId: 'reject',
            label: 'Reject',
            text: 'no',
          ),
        ],
      );

      svc.answerWithChoice(esc, 'approve');
      svc.reply(esc, 'yes');

      expect(t.sent.any((m) => m['type'] == 'terminal:input'), isFalse);
      expect(t.sent.any((m) => m['type'] == 'agent:prompt'), isFalse);

      await svc.dispose();
      await session.close();
    });
  });

  test('undo names the entry and nothing else', () async {
    // No terminalId on the wire: the id names the entry, and the entry carries
    // its own session and project path bridge-side.
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.undo(_snapshot());

    final sent = t.sent.firstWhere((m) => m['type'] == 'handler:undo');
    expect(sent['projectId'], 'p');
    expect(sent['snapshotId'], 's1');
    expect(sent.containsKey('terminalId'), isFalse);

    await svc.dispose();
    await session.close();
  });

  test('a spent entry and a second tap both send nothing', () async {
    final t = FakeAgentTransport();
    final session = await _newSession(t);
    final svc = HandlerService.fromSession(session);

    svc.undo(_snapshot(state: 'undone'));
    expect(t.sent.any((m) => m['type'] == 'handler:undo'), isFalse);

    // The first tap holds the id in flight until the bridge re-states it, so a
    // double tap can't put a second message on the wire.
    svc.undo(_snapshot());
    svc.undo(_snapshot());
    expect(t.sent.where((m) => m['type'] == 'handler:undo'), hasLength(1));

    await svc.dispose();
    await session.close();
  });

  group('guard-rejection reports (handler:dismiss)', () {
    /// A `handler:status` snapshot replaying [escalations] on one armed session,
    /// which is how a report reaches the app after a reconnect or a restart.
    Map<String, dynamic> statusFrame(List<Map<String, dynamic>> escalations) => {
      'projectId': 'p',
      'sessions': [
        {
          'terminalId': 't9',
          'notifyOnly': false,
          'state': escalations.isEmpty ? 'watching' : 'needs_you',
          'pendingEscalations': escalations.length,
          'armedAt': 1,
          'goal': 'ship it',
          'backlog': <Object>[],
          'escalations': escalations,
        },
      ],
    };

    Map<String, dynamic> row({
      String escalationId = 'b1',
      String? kind = 'guard_blocked',
      int at = 1,
    }) => {
      'escalationId': escalationId,
      'question': 'Handler did not send its reply',
      'reasoning': 'reply contains control characters',
      'draftReply': '/code-review --fix',
      'urgency': 'normal',
      'at': at,
      'kind': ?kind,
    };

    HandlerEscalation only(HandlerService svc, String id) =>
        svc.currentState.escalations.firstWhere((e) => e.escalationId == id);

    test('dismiss sends handler:dismiss and drops only that row', () async {
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', statusFrame([row(), row(escalationId: 'b2', at: 2)]));
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.escalations, hasLength(2));

      svc.dismiss(only(svc, 'b1'));

      final sent = t.sent.firstWhere((m) => m['type'] == 'handler:dismiss');
      expect(sent['projectId'], 'p');
      expect(sent['terminalId'], 't9');
      expect(sent['escalationId'], 'b1');
      // A sibling report is a separate refusal the user has not read yet.
      expect(
        svc.currentState.escalations.map((e) => e.escalationId),
        ['b2'],
      );
      expect(svc.currentState.sessions['t9']!.pendingEscalations, 1);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('dismiss on a reply or resolve_in_session row sends nothing', () async {
      // The app-side mirror of the bridge's refusal: a live question dropped by
      // a Dismiss would vanish more silently than any path that exists today.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', statusFrame([
        row(escalationId: 'r1', kind: null),
        row(escalationId: 'p1', kind: 'resolve_in_session', at: 2),
      ]));
      await Future<void>.delayed(Duration.zero);

      svc.dismiss(only(svc, 'r1'));
      svc.dismiss(only(svc, 'p1'));
      expect(t.sent.any((m) => m['type'] == 'handler:dismiss'), isFalse);
      expect(svc.currentState.escalations, hasLength(2));

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('replying to a report sends the reply AND its dismiss, and leaves a sibling standing',
        () async {
      // The bridge cannot tell the user's line apart from an unrelated one — the
      // whole reason the kind exists — so sending your own words has to carry
      // the acknowledgement with it.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', statusFrame([row(), row(escalationId: 'b2', at: 2)]));
      await Future<void>.delayed(Duration.zero);

      expect(svc.reply(only(svc, 'b1'), 'run the review yourself'), isTrue);
      expect(t.sent.where((m) => m['type'] == 'terminal:input'), hasLength(1));
      final dismissed = t.sent.where((m) => m['type'] == 'handler:dismiss');
      expect(dismissed, hasLength(1));
      expect(dismissed.single['escalationId'], 'b1');
      expect(svc.currentState.escalations.map((e) => e.escalationId), ['b2']);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });

    test('an unrelated reply on the same terminal leaves the reports standing', () async {
      // The reported bug, app-side: the optimistic drop must mirror the bridge's
      // clearing rule, or the row disappears locally and comes back on the next
      // snapshot — or worse, reads as retired.
      final t = FakeAgentTransport();
      final session = await _newSession(t);
      final svc = HandlerService.fromSession(session);
      final sub = session.heavyStream.listen((_) {});

      t.emit('handler:status', statusFrame([
        row(),
        row(escalationId: 'q1', kind: null, at: 2),
      ]));
      await Future<void>.delayed(Duration.zero);

      expect(svc.reply(only(svc, 'q1'), 'never mind, do something else'), isTrue);
      expect(t.sent.any((m) => m['type'] == 'handler:dismiss'), isFalse);
      expect(svc.currentState.escalations.map((e) => e.escalationId), ['b1']);
      expect(svc.currentState.sessions['t9']!.pendingEscalations, 1);
      expect(
        svc.currentState.sessions['t9']!.runState,
        HandlerRunState.needsYou,
      );

      // …and the row is still there after the bridge replays it, which is what
      // the answered-set suppression would have quietly undone.
      t.emit('handler:status', statusFrame([row()]));
      await Future<void>.delayed(Duration.zero);
      expect(svc.currentState.escalations.map((e) => e.escalationId), ['b1']);

      await sub.cancel();
      await svc.dispose();
      await session.close();
    });
  });
}
