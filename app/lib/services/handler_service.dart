import 'dart:async';

import '../models/ab_message.dart';
import '../models/handler_state.dart';
import '../project/project_session.dart';

/// What became of a call to [HandlerService.instruct]. A bool could not tell
/// the two refusals apart, and they are owed different answers: a blank field
/// is the user having typed nothing, which needs no reply, while a sentence
/// already outstanding is a send that looked identical and did not happen.
enum HandlerInstructResult { sent, empty, duplicate }

/// Per-project mirror of the bridge Handler subsystem. Reduces `handler:*`
/// inbound messages into a [HandlerState]; never persists (the bridge owns
/// `handler-config.json` / `handler-activity.jsonl`).
class HandlerService {
  final ProjectSession session;

  static const _activityCap = 200;

  StreamSubscription<Map<String, dynamic>>? _statusSub;
  StreamSubscription<Map<String, dynamic>>? _heavySub;
  final _stateController = StreamController<HandlerState>.broadcast();
  // Fires once per genuinely-new escalation (post-dedup). Separate from
  // [stateStream] — the state replays on refocus and carries the full list,
  // which would re-fire a notification; this emits each escalation exactly once
  // as it arrives, so the OS-notification fan-out can't double-notify.
  final _escalationController = StreamController<HandlerEscalation>.broadcast();
  HandlerState _state = const HandlerState.initial();
  bool _disposed = false;
  // agent:prompt correlation ids — the driver only needs per-send uniqueness.
  int _reqCounter = 0;

  // What each terminal's session looked like when its outstanding instructions
  // went out, which is what [_retirePending] compares against. Service-local
  // bookkeeping, not state: no surface renders it, and every sentence still
  // outstanding for a terminal shares one entry (a baseline only ever moves on
  // a status frame, and every survivor is re-baselined against the same one).
  final Map<String, ({int backlog, int armedAt})> _instructBaselines = {};

  // Terminals whose next status frame is already spent. Every bridge outcome
  // that records an instruction row emits a snapshot straight after it, and for
  // the two that also moved the backlog — an amendment, and a cap hit that still
  // had room for part of the batch — that snapshot carries a change the retired
  // sentence itself made. Read as a survivor's evidence it would retire a second
  // sentence whose extraction has not started. Marked when the row retires off
  // its activity record, and spent by [_retirePending] re-baselining that
  // terminal instead of retiring off it.
  final Set<String> _creditedStatus = {};

  // Terminals whose arm seeded a goal the bridge will extract behind the
  // handoff (§3.2). That pass runs on the SAME per-terminal chain instructions
  // queue on, and ahead of them — so its append moves backlogTotal exactly the
  // way a sentence's does, with nothing on the wire saying which of the two
  // moved it. Held so [_retirePending] can spend that one frame on the goal.
  final Set<String> _armGoalExtractions = {};

  // Judge picks, keyed by terminalId. `sessions` in [HandlerState] only holds
  // currently-armed sessions, so a disarmed terminal's judge pick would
  // otherwise vanish and the next arm would silently reset to Default — the
  // exact bug moving this off project level was meant to fix. Bounded and
  // insertion-ordered: terminal ids are per-session UUIDs, so an unbounded map
  // would accumulate an entry for every slot the project ever opened, for the
  // app's lifetime.
  static const _judgeCacheCap = 50;
  final Map<String, ({String? tool, String? model})> _lastKnownJudge = {};

  // Records a clear (both null) too — a status snapshot showing an armed
  // session is authoritative for that session's judge, including "cleared
  // back to default". Skipping nulls here was the bug: a re-arm that cleared
  // the judge left the previous non-null pick cached, so the next time a
  // picker opened it silently re-seeded (and re-armed) the stale tool.
  //
  // Re-inserts so a refreshed entry counts as most-recent, evicts oldest at cap.
  void _rememberJudge(String terminalId, String? tool, String? model) {
    _lastKnownJudge.remove(terminalId);
    _lastKnownJudge[terminalId] = (tool: tool, model: model);
    while (_lastKnownJudge.length > _judgeCacheCap) {
      _lastKnownJudge.remove(_lastKnownJudge.keys.first);
    }
  }

  Stream<HandlerState> get stateStream => _stateController.stream;
  Stream<HandlerEscalation> get escalationStream =>
      _escalationController.stream;
  HandlerState get currentState => _state;
  String get projectId => session.projectId;

  HandlerService.fromSession(this.session) {
    _statusSub = session.statusStream.listen(_onStatusJson);
    _heavySub = session.heavyStream.listen(_onHeavyJson);
  }

  // Escalations this app has already put an answer on the wire for. A status
  // frame the bridge computed BEFORE that answer arrived still lists them, and
  // `_onStatusJson` rebuilds the list wholesale — so without this the row comes
  // back one-tappable and a second tap puts the same line into the session
  // twice. Same hazard and same shape as [HandlerState.pendingUndo], minus its
  // consolation: the bridge serializes undo per id, and nothing absorbs a
  // duplicate reply. Pruned to the ids a snapshot still carries, so it holds
  // only what the bridge has yet to retire.
  final Set<String> _answeredEscalations = {};

  /// Withdraws the one-tap from any escalation where a tap would be unsafe,
  /// leaving the free-text row — the question stays answerable either way, so
  /// this can only ever cost the user one extra step.
  ///
  /// The single choke point on purpose: escalations reach [_state] from the
  /// one-shot push and from the status replay, and a floor that lived on only
  /// one of those would be a card the other path still renders.
  List<HandlerEscalation> _withChoiceFloors(List<HandlerEscalation> all) {
    // An agent blocked on an option-based prompt reads nothing until that prompt
    // is resolved, so a one-tap raised beside one sends text into a stalled
    // session and leaves the pill where it was — an action that looks like it
    // cleared the situation and did not. The free-text sheet costs the same send
    // but makes the user open and read first; the one-tap is what is withdrawn.
    // The bridge declines to mint choices in the same situation — this covers
    // the order it cannot see, a prompt arriving after the card was minted.
    final blocked = {
      for (final e in all)
        if (e.kind == 'resolve_in_session') e.terminalId,
    };
    return [
      for (final e in all)
        if (e.choices != null &&
            (_answeredEscalations.contains(e.escalationId) ||
                blocked.contains(e.terminalId)))
          e.withoutChoices()
        else
          e,
    ];
  }

  void _emit(HandlerState next) {
    final floored = _withChoiceFloors(next.escalations);
    _state = next.copyWith(escalations: floored);
    if (!_disposed) _stateController.add(_state);
  }

  /// Which of [terminalId]'s sessions this instruction was sent against, so a
  /// later snapshot can say whether the bridge has rewritten it since.
  ({int backlog, int armedAt}) _baselineFor(String terminalId) {
    final s = _state.sessions[terminalId];
    return (backlog: s?.backlogTotal ?? 0, armedAt: s?.armedAt ?? 0);
  }

  /// Retires outstanding instructions terminal by terminal, on that terminal's
  /// own evidence.
  ///
  /// A status frame says nothing about the terminal it was raised for: the
  /// engine serialises EVERY armed session on every handler event, twice, so a
  /// second armed terminal's ordinary supervision produces one within
  /// milliseconds of a send. Retiring on the frame alone cleared terminal A's
  /// sentence while A's extraction was still running — which took the "sending"
  /// row away with the backlog unchanged, lifted the debounce so a re-tap
  /// stacked the same work twice, and lifted the drawer's edit lock inside
  /// exactly the window it exists to cover.
  ///
  /// The evidence is the session the sentence was sent against. Extraction
  /// appends, so a backlog that is no longer the length it was has been
  /// rewritten since; a different `armedAt` is a re-arm, which replaces the
  /// session the queued extraction would have appended to and is the one path
  /// that appends nothing and says nothing; and a terminal absent from the
  /// snapshot has been disarmed or has exited. Survivors are re-baselined
  /// against what was just observed, so the next sentence in the queue waits
  /// for a change of its own rather than inheriting this one's.
  ///
  /// A backlog already AT the cap appends nothing and emits no status at all,
  /// so it is not reachable from here — [_onHeavyJson] retires that one off its
  /// own activity record. The two outcomes that record a row AND emit a frame —
  /// an amendment, and a cap hit that still had room for part of the batch —
  /// are why [_creditedStatus] exists: that frame re-baselines the survivors
  /// instead of answering for them too.
  ///
  /// [_armGoalExtractions] covers the one append that is nobody's sentence: a
  /// goal seeded at arm time is extracted on this same chain and lands FIRST,
  /// so a preset tapped while it was still running was retired by the goal's
  /// own items — with the preset's extraction not yet started.
  Map<String, List<String>> _retirePending(
    Map<String, HandlerSessionState> sessions,
  ) {
    final next = <String, List<String>>{};
    for (final entry in _state.pendingInstructions.entries) {
      final terminalId = entry.key;
      final session = sessions[terminalId];
      final baseline = _instructBaselines[terminalId];
      final credited = _creditedStatus.remove(terminalId);
      final moved =
          session == null ||
          baseline == null ||
          session.backlogTotal != baseline.backlog ||
          session.armedAt != baseline.armedAt;
      // Spent only on a frame that actually moved: an unchanged one retires
      // nothing, so letting it consume the goal pass would hand the goal's real
      // append to the sentence behind it after all.
      final goalPass =
          moved && session != null && _armGoalExtractions.remove(terminalId);
      final answered = session == null || (!credited && !goalPass && moved);
      final kept = session == null
          ? const <String>[]
          : (answered ? entry.value.sublist(1) : entry.value);
      if (kept.isEmpty) {
        _instructBaselines.remove(terminalId);
        continue;
      }
      next[terminalId] = kept;
      _instructBaselines[terminalId] = (
        backlog: session!.backlogTotal,
        armedAt: session.armedAt,
      );
    }
    return next;
  }

  /// Drops [terminalId]'s oldest outstanding sentence, for the signals that
  /// arrive outside a status snapshot. The baseline is left where it is: the
  /// session it was taken against has not moved.
  ///
  /// A survivor is always credited the next status frame. The blanket rule rests
  /// on a bridge invariant: every path that records an instruction row emits a
  /// snapshot immediately after it, so the record and its frame arrive as a
  /// pair. Two of those records ride with a snapshot whose backlog this same
  /// sentence already moved — an amendment, and a cap hit that still had room
  /// for some of the batch — and [_retirePending] would read either as the NEXT
  /// sentence having landed, taking its "sending" row away while its extraction
  /// is still running and lifting the edit lock inside the window it exists to
  /// cover. The rest emit an unchanged snapshot, which spends the credit for
  /// nothing. Break that invariant on the bridge (a `record` with no
  /// `emitStatus` behind it, see `extractAndAppend` and `appendItems` in
  /// bridge/src/handler/engine.ts) and the credit lands on the survivor's own
  /// append instead, stranding its row for good.
  Map<String, List<String>> _withOldestPendingRetired(String terminalId) {
    final outstanding = _state.pendingInstructionsFor(terminalId);
    if (outstanding.isEmpty) return _state.pendingInstructions;
    final next = Map<String, List<String>>.from(_state.pendingInstructions);
    if (outstanding.length == 1) {
      next.remove(terminalId);
      _instructBaselines.remove(terminalId);
      _creditedStatus.remove(terminalId);
    } else {
      next[terminalId] = outstanding.sublist(1);
      _creditedStatus.add(terminalId);
    }
    return next;
  }

  void _onStatusJson(Map<String, dynamic> json) {
    if (_disposed) return;
    if (json['type'] != 'handler:status') return;
    final msg = parseAbMessage(json);
    if (msg is! HandlerStatusMessage) return;
    final sessions = <String, HandlerSessionState>{};
    for (final raw in msg.sessions) {
      final s = HandlerSessionState.fromWire(raw);
      if (s == null) continue;
      sessions[s.terminalId] = s;
      _rememberJudge(s.terminalId, s.judgeTool, s.judgeModel);
    }
    // Replace wholesale (welcome-replay safe) rather than merge — the
    // snapshot is the bridge's full current set of armed sessions, and it
    // replays every unanswered escalation, so the flat list is rebuilt from
    // it too. This is what lets the "needs you" rows survive an app restart
    // or reconnect instead of leaving a badge that points at nothing.
    final escalations = [for (final s in sessions.values) ...s.escalations]
      ..sort((a, b) => a.at.compareTo(b.at));
    // An id the bridge no longer replays has been retired there, so nothing is
    // left to suppress and the set cannot grow with the session's history.
    _answeredEscalations.retainWhere(
      (id) => escalations.any((e) => e.escalationId == id),
    );
    // Same wholesale replace, for the same reason: the replay is the bridge's
    // full current set of undo offers, which is what lets one survive the app
    // restart between the advert and the tap.
    final snapshots = <HandlerSnapshot>[];
    for (final raw in msg.snapshots) {
      final s = HandlerSnapshot.fromWire(raw);
      if (s != null) snapshots.add(s);
    }
    snapshots.sort((a, b) => a.at.compareTo(b.at));
    // A status frame is authoritative about which entries EXIST and what the
    // bridge last decided about them, but it says nothing about an undo still
    // running: an in-flight one is still 'available' until its own
    // handler:snapshot frame lands. Status is emitted twice per handler event on
    // any session, so clearing wholesale drops the spinner mid-push and invites a
    // re-tap the bridge silently absorbs (undo is serialized per id).
    final replayed = {for (final s in snapshots) s.snapshotId: s};
    final pendingUndo = {
      for (final id in _state.pendingUndo)
        if (replayed[id]?.undoable ?? false) id,
    };
    // Read before the state moves: [_retirePending] compares the snapshot
    // against the session each sentence was sent against.
    final pendingInstructions = _retirePending(sessions);
    // After it, never before: the frame carrying the goal's own items is the one
    // [_retirePending] needs the mark for. The bridge extracts a goal only into
    // an EMPTY backlog, so a session that now has items has either run that pass
    // or skipped it for good — and a terminal that is gone runs nothing. Left
    // standing, the mark would wait for the user's first sentence and swallow
    // the frame that sentence's own append raised.
    _armGoalExtractions.removeWhere((t) {
      final s = sessions[t];
      return s == null || s.backlogTotal > 0;
    });
    final next = _state.copyWith(
      sessions: sessions,
      defaultNotifyOnly: msg.defaultNotifyOnly,
      escalations: escalations,
      defaultTool: msg.defaultTool,
      snapshots: snapshots,
      pendingUndo: pendingUndo,
      pendingInstructions: pendingInstructions,
    );
    _emit(next);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    if (_disposed) return;
    switch (json['type']) {
      case 'handler:escalation':
        final msg = parseAbMessage(json);
        if (msg is! HandlerEscalationMessage) return;
        if (_state.escalations.any((e) => e.escalationId == msg.escalationId)) {
          return; // dedup
        }
        final escalation = HandlerEscalation(
          escalationId: msg.escalationId,
          terminalId: msg.terminalId,
          question: msg.question,
          reasoning: msg.reasoning,
          draftReply: msg.draftReply,
          urgency: msg.urgency,
          floorRule: msg.floorRule,
          at: msg.timestamp,
          kind: msg.kind,
          choices: msg.choices,
        );
        _emit(
          _state.copyWith(escalations: [..._state.escalations, escalation]),
        );
        // Read back out of the state rather than forwarded: the floors in
        // [_withChoiceFloors] may have withdrawn the card on the way in, and a
        // notification offering choices the screen no longer shows would be a
        // second surface disagreeing about what a tap does.
        _escalationController.add(
          _escalationById(escalation.escalationId) ?? escalation,
        );
        break;
      case 'handler:snapshot':
        final msg = parseAbMessage(json);
        if (msg is! HandlerSnapshotMessage) return;
        final snapshot = HandlerSnapshot.fromWire(msg.snapshot);
        if (snapshot == null) return;
        // Upsert, never append: the advert is re-sent on every state change of
        // the same entry, so a second copy would offer an undo that is already
        // spent alongside the row that says so.
        final snapshots = [
          for (final s in _state.snapshots)
            if (s.snapshotId != snapshot.snapshotId) s,
          snapshot,
        ]..sort((a, b) => a.at.compareTo(b.at));
        _emit(
          _state.copyWith(
            snapshots: snapshots,
            pendingUndo: {..._state.pendingUndo}..remove(snapshot.snapshotId),
          ),
        );
        break;
      case 'handler:activity':
        final msg = parseAbMessage(json);
        if (msg is! HandlerActivityMessage) return;
        // The outcomes an instruction can reach that [_retirePending] cannot read
        // off the item count: a backlog at the bridge's cap appends nothing at
        // all (and emits nothing) or appends only part of the batch, and an
        // amendment moves the count for a reason that is this sentence's own
        // answer rather than the next one's. Left unretired, the "sending" row
        // stands forever and the edit lock it raises holds Delete — which under a
        // full backlog is the only thing that frees room — until an unrelated
        // handler event, a re-arm or a reconnect.
        final pendingInstructions =
            msg.decision == 'instruction_amended' ||
                msg.decision == 'instruction_dropped'
            ? _withOldestPendingRetired(msg.terminalId)
            : _state.pendingInstructions;
        final next = <HandlerActivityRecord>[
          HandlerActivityRecord(
            recordId: msg.recordId,
            at: msg.at,
            terminalId: msg.terminalId,
            decision: msg.decision,
            reason: msg.reason,
            detail: msg.detail,
          ),
          ..._state.activity,
        ];
        _emit(
          _state.copyWith(
            activity: next.length > _activityCap
                ? next.sublist(0, _activityCap)
                : next,
            pendingInstructions: pendingInstructions,
          ),
        );
        break;
    }
  }

  /// Arm [terminalId]. Spec §4.1: arming takes one tap and requires no payload,
  /// so [goal] and [backlog] are both optional and an omitted one leaves the
  /// bridge's stored value untouched — absent is not empty. Pass `backlog: []`
  /// to clear it explicitly. The bridge's backlog is authoritative once
  /// extraction appends to it, so never round-trip a stale copy back.
  ///
  /// [judgeTool]/[judgeModel] are this session's judge choice; `''` clears back
  /// to default and a name sets it. Pass null (the default) to leave the
  /// session's stored judge record untouched, for any caller that doesn't
  /// surface a picker — the keys are omitted from the wire message, which the
  /// bridge reads as "no change" (so arming without touching the judge picker
  /// never rewrites its per-session record).
  void arm({
    required String terminalId,
    String? goal,
    List<HandlerInstructionItem>? backlog,
    required bool notifyOnly,
    String? judgeTool,
    String? judgeModel,
  }) {
    if (_disposed) return;
    if (judgeTool != null || judgeModel != null) {
      // Optimistically mirror the bridge's applyJudgeChoice ('' clears, a
      // name sets, an omitted field keeps its old value) so lastKnownJudge is
      // right immediately: reopening a picker before the status snapshot
      // round-trips would otherwise seed it with the pre-arm judge — and
      // committing that stale value silently reverts this arm's choice.
      final prev = lastKnownJudge(terminalId);
      _rememberJudge(
        terminalId,
        judgeTool != null ? (judgeTool.isEmpty ? null : judgeTool) : prev?.tool,
        judgeModel != null
            ? (judgeModel.trim().isEmpty ? null : judgeModel.trim())
            : prev?.model,
      );
    }
    // Mirrors the condition the bridge queues an arm-time extraction on: a goal
    // with words in it, no backlog carried alongside it (an app-supplied list is
    // already the user's own, and extracting the goal beside it would double
    // every item), and — for a session that is ALREADY armed — a goal that
    // actually moved. Restating the same goal is a no-op there (`goalChanged` in
    // bridge/src/handler/engine.ts), and a mark nothing will satisfy waits for
    // the user's first sentence and swallows the frame that sentence's own
    // append raised. `updateBacklog` sends a backlog and no goal, so an edit
    // never sets this.
    //
    // A prediction, not a fact: the bridge also extracts a goal REHYDRATED off
    // its own disk record, which arrives on a one-tap arm carrying no goal at
    // all and cannot be mirrored from here. That append still answers for a
    // sentence that did not cause it.
    final armedGoal = _state.sessions[terminalId]?.goal.trim();
    if (goal != null &&
        goal.trim().isNotEmpty &&
        backlog == null &&
        armedGoal != goal.trim()) {
      _armGoalExtractions.add(terminalId);
    }
    session.send(
      createAbMessage('handler:configure', {
        'projectId': session.projectId,
        'terminalId': terminalId,
        'armed': true,
        'goal': ?goal,
        'backlog': ?backlog?.map((i) => i.toWire()).toList(),
        'notifyOnly': notifyOnly,
        'judgeTool': ?judgeTool,
        'judgeModel': ?judgeModel,
      }),
    );
  }

  /// Disarm [terminalId]. `armed:false` alone tells the bridge to drop the
  /// session; goal and backlog are omitted so nothing stored is overwritten on
  /// the way out.
  void disarm(String terminalId) {
    if (_disposed) return;
    session.send(
      createAbMessage('handler:configure', {
        'projectId': session.projectId,
        'terminalId': terminalId,
        'armed': false,
        'notifyOnly': false,
      }),
    );
  }

  /// Replace [terminalId]'s backlog with [backlog] — reorder, drop an item,
  /// drop a `dependsOn`, or revive a skipped one. There is no backlog message:
  /// `handler:configure` is the only edit path and the bridge assigns the list
  /// wholesale, with no merge and no transition validation, so three rules bind
  /// every caller.
  ///
  /// Derive [backlog] from the freshest state readable at the moment of the
  /// edit and never carry an edited copy across an async gap: extraction
  /// appends to the bridge's list behind the handoff, and a full replace built
  /// from a pre-extraction snapshot deletes whatever landed in between.
  ///
  /// [notifyOnly] must be the session's CURRENT value — the field is required
  /// on the wire, so a guessed one silently flips the session between notifying
  /// and acting.
  ///
  /// The goal is deliberately not a parameter: a changed goal arriving without
  /// a backlog re-extracts into the session, so the two edits stay separate
  /// calls.
  ///
  /// An edit is refused outright while an instruction is outstanding for
  /// [terminalId]: extraction appends behind this handoff, so NO list readable
  /// at the moment of the edit is fresh, and the replace built from one deletes
  /// the items the user just asked for with nothing said. The floor is here
  /// rather than on the surface that noticed it because this is the only way an
  /// edit reaches the wire — a second editing surface inherits it instead of
  /// having to remember it. A surface that offers the edit anyway owes the user
  /// the reason; the refusal alone is silent.
  ///
  /// Reports whether the replace went out, so a surface holding something the
  /// user cannot get back — text they just typed — can keep it rather than
  /// close over a send that did not happen. Reading the hold off the state
  /// instead would be a second copy of this rule, and one that can go stale
  /// between the frame a button was drawn in and the tap that fires it.
  bool updateBacklog({
    required String terminalId,
    required List<HandlerInstructionItem> backlog,
    required bool notifyOnly,
  }) {
    if (_disposed) return false;
    if (_state.pendingInstructionsFor(terminalId).isNotEmpty) return false;
    arm(terminalId: terminalId, backlog: backlog, notifyOnly: notifyOnly);
    return true;
  }

  /// Stack another instruction onto [terminalId]'s backlog. The bridge extracts
  /// items from [text]; the app sends the sentence and nothing else, so preset
  /// chips and typed text share this one path (a chip-specific message type
  /// would need its own copy of every rule that later applies to instructions).
  ///
  /// No optimistic local append: the bridge mints the item ids and echoes the
  /// whole backlog back on `handler:status`, so an appended local item would
  /// race that snapshot and show twice until it landed. The sentence itself is
  /// recorded in [HandlerState.pendingInstructions] instead — extraction runs
  /// behind a per-terminal serial chain and spawns a headless CLI, so the
  /// seconds before the next snapshot are otherwise indistinguishable from a
  /// tap that missed.
  ///
  /// That record is also the debounce. A sentence already in flight for this
  /// terminal is refused, because the bridge APPENDS and nothing there absorbs
  /// a duplicate: a second tap would put the same work in the backlog twice.
  /// It holds for exactly as long as the ambiguity does rather than for a fixed
  /// interval, and the cost is that the same words genuinely wanted twice wait
  /// for the first to land.
  ///
  /// Reports which of the three happened, so a caller can keep the text it
  /// would otherwise have cleared away AND tell a held send apart from an empty
  /// one — a duplicate looks identical to a tap that missed, and it is the
  /// primary action of the surface that sends it.
  HandlerInstructResult instruct(String terminalId, String text) {
    // Nothing to report on a torn-down service: the caller is going away too.
    if (_disposed) return HandlerInstructResult.empty;
    final sentence = text.trim();
    if (sentence.isEmpty) return HandlerInstructResult.empty;
    final outstanding = _state.pendingInstructionsFor(terminalId);
    if (outstanding.contains(sentence)) return HandlerInstructResult.duplicate;
    _instructBaselines[terminalId] = _baselineFor(terminalId);
    session.send(
      createAbMessage('handler:instruct', {
        'projectId': session.projectId,
        'terminalId': terminalId,
        'text': text,
      }),
    );
    _emit(
      _state.copyWith(
        pendingInstructions: {
          ..._state.pendingInstructions,
          terminalId: [...outstanding, sentence],
        },
      ),
    );
    return HandlerInstructResult.sent;
  }

  /// Undo [snapshot] — the one tap spec §5.2 trades prevention for. The bridge
  /// owns the result: it re-states the entry as `undone` or as `failed` with a
  /// reason, so nothing is assumed here beyond marking the id in flight.
  ///
  /// A spent or unrecognised entry sends nothing rather than firing a message
  /// the bridge would discard — the row that renders it offers no tap either,
  /// and the two must agree or the quiet no-op reads as a broken undo.
  void undo(HandlerSnapshot snapshot) {
    if (_disposed) return;
    if (!snapshot.undoable) return;
    if (_state.pendingUndo.contains(snapshot.snapshotId)) return;
    session.send(
      createAbMessage('handler:undo', {
        'projectId': session.projectId,
        'snapshotId': snapshot.snapshotId,
      }),
    );
    _emit(
      _state.copyWith(
        pendingUndo: {..._state.pendingUndo, snapshot.snapshotId},
      ),
    );
  }

  /// Acknowledge a `guard_blocked` report — the only thing that retires one, on
  /// either side of the wire. Nothing the agent or the user does next answers a
  /// report about an action Handler never took.
  ///
  /// Refuses every other kind: the app-side mirror of the bridge's own refusal,
  /// because a Dismiss on a live question would drop it more silently than any
  /// path that exists today.
  void dismiss(HandlerEscalation escalation) {
    if (_disposed) return;
    if (escalation.kind != 'guard_blocked') return;
    _sendDismiss(escalation);
    _dropRows(
      escalation.terminalId,
      (e) => e.escalationId != escalation.escalationId,
    );
  }

  void _sendDismiss(HandlerEscalation escalation) {
    session.send(
      createAbMessage('handler:dismiss', {
        'projectId': session.projectId,
        'terminalId': escalation.terminalId,
        'escalationId': escalation.escalationId,
      }),
    );
  }

  /// The judge pick a picker would seed from (status snapshots and optimistic
  /// [arm] writes feed the cache). Null = never picked.
  ///
  /// Nothing in the app writes a judge override yet, so no surface reads this
  /// back either — it is fed only by status snapshots. Kept rather than
  /// deleted because this cache is the whole reason a re-arm does not silently
  /// revert to Default; the clear-vs-stale rules on [_rememberJudge] are the
  /// fix, and they are easy to get wrong a second time.
  ///
  /// Cache first, armed-session state second: every status snapshot writes
  /// BOTH, and [arm] optimistically writes only the cache — so the cache is
  /// never staler than the armed entry and is fresher during the arm→snapshot
  /// round-trip. The armed fallback only matters if enough other terminals
  /// evicted this one's cache entry while it stayed armed.
  ({String? tool, String? model})? lastKnownJudge(String terminalId) {
    final cached = _lastKnownJudge[terminalId];
    if (cached != null) return cached;
    final armed = _state.sessions[terminalId];
    if (armed != null &&
        (armed.judgeTool != null || armed.judgeModel != null)) {
      return (tool: armed.judgeTool, model: armed.judgeModel);
    }
    return null;
  }

  /// The terminal's own CLI (chat slots report one; PTY slots may not) — the
  /// app-side half of the bridge's deps.tool(terminalId) resolution, used to
  /// label `"Default (<tool>)"` correctly per session.
  String? sessionTool(String terminalId) {
    for (final s in session.sessionsService.currentState.sessions) {
      if (s.id == terminalId) return s.tool;
    }
    return null;
  }

  /// The CLI that judges [terminalId] when no per-session override is set:
  /// the session's own tool, else the project agent default. The single
  /// app-side resolution, so every surface naming the judge goes through here
  /// and they can't drift.
  String? resolvedDefaultTool(String terminalId) =>
      sessionTool(terminalId) ?? _state.defaultTool;

  /// Whether [terminalId] is a chat slot (structured driver) rather than a PTY.
  /// Read from the sibling SessionsService at send time rather than accepted as
  /// a parameter: a caller that got it wrong would aim `terminal:input` at a
  /// slot with no PTY, which the bridge drops — while `onUserReply` still fires
  /// and clears the escalation, so the answer vanishes and the badge goes quiet
  /// as though it landed. Nothing about the failure is visible to the user.
  bool _isChat(String terminalId) => session
      .sessionsService
      .currentState
      .sessions
      .any((s) => s.id == terminalId && s.mode == 'chat');

  /// Send the user's answer for [escalation] into the live session. PTY slots
  /// reuse `terminal:input` (trailing `\r` submits the line, matching the
  /// bridge act path); chat slots send `agent:prompt` — the same inbound verb
  /// an app-composed message uses, which also resets the bridge's runaway
  /// guard. Optimistically drops exactly the rows the bridge's own rule retires
  /// (see [_survivesReply]) through [_dropRows].
  ///
  /// A `guard_blocked` row IS replyable — the sheet opens prefilled with the text
  /// the guard refused — and sending is itself the explicit act on it, so its
  /// dismiss goes out with the answer.
  ///
  /// Returns whether the answer reached the wire. Every refusal below leaves an
  /// unanswered escalation behind, so a surface that showed the send as
  /// in-flight has to be able to take that back — a control stuck reporting an
  /// answer nobody sent is worse than one that never latched.
  bool reply(HandlerEscalation escalation, String text) {
    if (_disposed) return false;
    // An option-based agent prompt is resolvable only by the chat transcript's
    // permission/question UI, which holds the permissionId/questionId the driver
    // is blocked on. Injected text answers nothing and the row rightly stays
    // pending, so the send is pure noise into a stalled session. Callers route
    // the user to the transcript; this is the floor for the ones that forget.
    if (escalation.kind == 'resolve_in_session') return false;
    // Never submit an empty answer: '$text\r' with blank text is a bare Enter,
    // which accepts the default at whatever prompt the agent is showing (e.g. a
    // [Y/n] confirmation). The reply sheet also disables its send button when
    // empty; this is the enforcement floor.
    if (text.trim().isEmpty) return false;
    if (_isChat(escalation.terminalId)) {
      session.send(
        createAbMessage('agent:prompt', {
          'sessionId': escalation.terminalId,
          'requestId': 'handler-req-${_reqCounter++}',
          'text': text,
        }),
      );
    } else {
      // Embedded newlines (pasted multi-line answers) would each act as a
      // submitted line in the PTY — the first line answers the prompt and the
      // rest fire blindly at whatever appears next. Flatten to one line.
      final line = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
      session.send(
        createAbMessage('terminal:input', {
          'terminalId': escalation.terminalId,
          'data': '$line\r',
        }),
      );
    }
    // Every row this send retires, not just the one that was tapped. One submitted
    // line clears the terminal's whole free-text set (below, and in the bridge), so a
    // sibling left out of this set comes back off the next status snapshot with its
    // one-tap chip live — and that tap puts a second line into a session the first
    // one already unblocked. A `guard_blocked` sibling is NOT one of those: the
    // bridge does not retire it on a submitted line, so suppressing it here would
    // hide a row the next snapshot still legitimately carries.
    for (final e in _state.escalations) {
      if (e.terminalId == escalation.terminalId &&
          e.kind != 'resolve_in_session' &&
          e.kind != 'guard_blocked') {
        _answeredEscalations.add(e.escalationId);
      }
    }
    _answeredEscalations.add(escalation.escalationId);
    // Sending your own words IS the explicit act on a report — the bridge cannot
    // tell that line apart from an unrelated one, which is the whole reason the
    // kind exists — so the dismiss rides along with it.
    if (escalation.kind == 'guard_blocked') _sendDismiss(escalation);
    _dropRows(
      escalation.terminalId,
      (e) => _survivesReply(e, escalation),
    );
    return true;
  }

  /// Whether [e] outlives the submitted line that answered [answered]. Exactly
  /// the bridge's rule: an option-based prompt is unanswerable by a typed line,
  /// and a report is not answered by one either — but the report the user
  /// replied FROM is dismissed alongside the send, so it goes.
  bool _survivesReply(HandlerEscalation e, HandlerEscalation answered) =>
      e.kind == 'resolve_in_session' ||
      (e.kind == 'guard_blocked' &&
          e.escalationId != answered.escalationId);

  /// Optimistically drop every row on [terminalId] that [survives] rejects, and
  /// recompute the owning session's pending count so the header pill and tab
  /// badge don't show a stale "needs you" over an empty list for the round trip.
  /// The next `handler:status` snapshot reconciles authoritatively.
  ///
  /// Clearing wholesale instead would blank the pill over a session the bridge
  /// still reports as needs_you and flip it back a round trip later — the
  /// blank-over-a-blocked-agent flash this optimism exists to spare the user.
  void _dropRows(
    String terminalId,
    bool Function(HandlerEscalation) survives,
  ) {
    final sessions = Map<String, HandlerSessionState>.from(_state.sessions);
    final owner = sessions[terminalId];
    if (owner != null) {
      final surviving = owner.escalations.where(survives).toList();
      sessions[terminalId] = owner.copyWith(
        pendingEscalations: surviving.length,
        escalations: surviving,
        runState:
            surviving.isEmpty && owner.runState == HandlerRunState.needsYou
            ? HandlerRunState.watching
            : owner.runState,
      );
    }
    _emit(
      _state.copyWith(
        sessions: sessions,
        escalations: [
          for (final e in _state.escalations)
            if (e.terminalId != terminalId || survives(e)) e,
        ],
      ),
    );
  }

  /// Answer [escalation] by tapping one of its own quick choices (spec §4.6).
  /// [choiceId] is resolved against the offered set and the choice's `text` is
  /// what goes on the wire, so a caller holding only an id — an OS notification
  /// action — can never put text of its own into the session, and an id that no
  /// longer matches sends nothing rather than something else.
  ///
  /// Routes through [reply] and deliberately NOT through [instruct]: a tap
  /// grants no §5.4 authorization lift. `handler:instruct` is the sole feed
  /// point for instruction-scoped authorization and §5.4 derives that only from
  /// the user's own instruction text — chip text is Assistant output (the judge
  /// composed the draft `[Approve]` sends), so minting a lift from it is the
  /// laundering path §5.4 exists to close. It would also stack an extraction
  /// item no terminal status can resolve, leaving the session unable to wrap
  /// up. The costs are asymmetric: under-lifting costs one advisory
  /// `floor_warning` row per repeat, since the floor records rather than
  /// blocks, while over-lifting costs a session-wide grant nobody read. The
  /// real lift stays one control away, in the user's own words, via the PA bar.
  ///
  /// Returns whether the answer reached the wire, so a card can only show a
  /// send as in-flight when one actually is.
  bool answerWithChoice(HandlerEscalation escalation, String choiceId) {
    if (_disposed) return false;
    // Resolved against the state's copy, not the caller's: an escalation held
    // across a frame (or arriving by notification id) can have had its card
    // withdrawn since — by _withChoiceFloors — and the stale object would still
    // offer the tap the floors just took away.
    final current = _escalationById(escalation.escalationId) ?? escalation;
    final choice = current.choiceById(choiceId);
    if (choice == null) return false;
    return reply(current, choice.text);
  }

  HandlerEscalation? _escalationById(String escalationId) {
    for (final e in _state.escalations) {
      if (e.escalationId == escalationId) return e;
    }
    return null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _statusSub?.cancel();
    _statusSub = null;
    await _heavySub?.cancel();
    _heavySub = null;
    await _stateController.close();
    await _escalationController.close();
  }
}
