enum HandlerRunState { watching, handling, needsYou, parked }

HandlerRunState? handlerRunStateFromWire(String s) {
  switch (s) {
    case 'watching':
      return HandlerRunState.watching;
    case 'handling':
      return HandlerRunState.handling;
    case 'needsYou':
    case 'needs_you':
      return HandlerRunState.needsYou;
    case 'parked':
      return HandlerRunState.parked;
    default:
      return null;
  }
}

String handlerRunStateToWire(HandlerRunState s) {
  switch (s) {
    case HandlerRunState.watching:
      return 'watching';
    case HandlerRunState.handling:
      return 'handling';
    case HandlerRunState.needsYou:
      return 'needs_you';
    case HandlerRunState.parked:
      return 'parked';
  }
}

/// How much of the Handler an armed session can actually get. Mirrors the
/// bridge's `HandlerObservability` (`bridge/src/handler/engine.ts`), carried on
/// each session snapshot.
///
/// The three are separate user-facing facts and must never be folded together:
/// [unsupported] means nothing this session does ever reaches the handler, so
/// arming it stays silent, while [escalateOnly] means the handler is watching
/// and simply has no judge to answer with.
enum HandlerObservability {
  /// The handler sees the session and its judge can run headless.
  full,

  /// The handler sees the session, but its judge cannot run headless — every
  /// pause reaches the user instead of being handled.
  escalateOnly,

  /// The session's agent reports nothing the handler can act on.
  unsupported,
}

/// Null for an unknown value — including the absence an older bridge sends.
/// Callers must render null as "not reported", never as [unsupported]: claiming
/// a session is unwatchable because the bridge is old is the same class of lie
/// this field exists to remove.
HandlerObservability? handlerObservabilityFromWire(dynamic s) {
  switch (s) {
    case 'full':
      return HandlerObservability.full;
    case 'escalate_only':
      return HandlerObservability.escalateOnly;
    case 'unsupported':
      return HandlerObservability.unsupported;
    default:
      return null;
  }
}

/// One entry of the live instruction stack. Mirrors the bridge's
/// `InstructionItemWire` (`bridge/src/protocol.ts`) field for field.
class HandlerInstructionItem {
  /// Stable across the session — the bridge's evaluator answers with ids and
  /// never with prose, so this is what a transition addresses.
  final String id;
  final String text;

  /// Ids this item waits on, extracted from the user's own ordering words. The
  /// bridge derives `blocked` from them; the app never authors one (spec §3.3).
  final List<String>? dependsOn;
  final String? condition;

  // 'queued' | 'active' | 'done' | 'blocked' | 'skipped' | 'failed'
  final String status;
  final String? outcome;

  /// Verbatim transcript substring justifying the current [status].
  final String? evidence;
  final int createdAt;

  const HandlerInstructionItem({
    required this.id,
    required this.text,
    this.dependsOn,
    this.condition,
    required this.status,
    this.outcome,
    this.evidence,
    required this.createdAt,
  });

  static HandlerInstructionItem? fromWire(dynamic json) {
    if (json is! Map) return null;
    final id = json['id'];
    final text = json['text'];
    final status = json['status'];
    final createdAt = json['createdAt'];
    if (id is! String ||
        text is! String ||
        status is! String ||
        createdAt is! num) {
      return null;
    }
    final dependsOnJson = json['dependsOn'];
    if (dependsOnJson != null &&
        (dependsOnJson is! List || dependsOnJson.any((e) => e is! String))) {
      return null;
    }
    final condition = json['condition'];
    final outcome = json['outcome'];
    final evidence = json['evidence'];
    if ((condition != null && condition is! String) ||
        (outcome != null && outcome is! String) ||
        (evidence != null && evidence is! String)) {
      return null;
    }
    return HandlerInstructionItem(
      id: id,
      text: text,
      dependsOn: dependsOnJson?.cast<String>(),
      condition: condition as String?,
      status: status,
      outcome: outcome as String?,
      evidence: evidence as String?,
      createdAt: createdAt.toInt(),
    );
  }

  Map<String, dynamic> toWire() => {
    'id': id,
    'text': text,
    if (dependsOn != null) 'dependsOn': dependsOn,
    if (condition != null) 'condition': condition,
    'status': status,
    if (outcome != null) 'outcome': outcome,
    if (evidence != null) 'evidence': evidence,
    'createdAt': createdAt,
  };
}

/// One armed handler session (per terminal). Mirrors the bridge's
/// `HandlerSessionSnapshot` (`bridge/src/protocol.ts`).
class HandlerSessionState {
  final String terminalId;
  final bool notifyOnly;
  final HandlerRunState runState;
  final int pendingEscalations;
  final int armedAt;

  /// The session objective, and the live instruction stack working towards it.
  /// An item's own status is the whole record of progress — nothing
  /// accumulates alongside the backlog.
  final String goal;
  final List<HandlerInstructionItem> backlog;

  /// Unanswered escalations replayed with every status snapshot, so the
  /// "needs you" list survives app restarts and reconnects (the one-shot
  /// `handler:escalation` push alone would be lost with the process).
  final List<HandlerEscalation> escalations;

  /// Per-session judge overrides (null = the session's own tool / the judge
  /// CLI's default model). Mirrors the wire snapshot.
  final String? judgeTool;
  final String? judgeModel;

  /// Why the handler is waiting ('limit' | 'outage') and the epoch-ms wake
  /// deadline. Both are present only while [runState] is
  /// [HandlerRunState.parked]; a park with no known deadline leaves
  /// [parkedUntil] null.
  final String? parkKind;
  final int? parkedUntil;

  /// What the handler can actually do with THIS armed session, as the bridge
  /// reports it. Null = not reported (a bridge predating the field) — the UI
  /// then claims nothing either way.
  ///
  /// This is the post-arm fact. The pre-arm one — "could an agent of this kind
  /// be watched at all" — is the agent catalog's `handlerTerminal`/
  /// `handlerChat`, and the two are not interchangeable: the catalog describes
  /// an agent, this describes a session (its live mode and its judge pick).
  final HandlerObservability? observability;

  const HandlerSessionState({
    required this.terminalId,
    required this.notifyOnly,
    required this.runState,
    required this.pendingEscalations,
    required this.armedAt,
    required this.goal,
    required this.backlog,
    required this.escalations,
    this.judgeTool,
    this.judgeModel,
    this.parkKind,
    this.parkedUntil,
    this.observability,
  });

  int get backlogTotal => backlog.length;

  /// Only `done` counts, never the other terminal states: `skipped` and
  /// `failed` close an item without achieving it, and reporting them as
  /// progress is the summary-inflation failure mode spec §4.3 guards against.
  int get backlogDone => backlog.where((i) => i.status == 'done').length;

  HandlerSessionState copyWith({
    HandlerRunState? runState,
    int? pendingEscalations,
    List<HandlerEscalation>? escalations,
  }) => HandlerSessionState(
    terminalId: terminalId,
    notifyOnly: notifyOnly,
    runState: runState ?? this.runState,
    pendingEscalations: pendingEscalations ?? this.pendingEscalations,
    armedAt: armedAt,
    goal: goal,
    backlog: backlog,
    escalations: escalations ?? this.escalations,
    judgeTool: judgeTool,
    judgeModel: judgeModel,
    parkKind: parkKind,
    parkedUntil: parkedUntil,
    observability: observability,
  );

  static HandlerSessionState? fromWire(dynamic json) {
    if (json is! Map) return null;
    final terminalId = json['terminalId'];
    final notifyOnly = json['notifyOnly'];
    final state = json['state'];
    final pendingEscalations = json['pendingEscalations'];
    final armedAt = json['armedAt'];
    final goal = json['goal'];
    final backlogJson = json['backlog'];
    if (terminalId is! String ||
        notifyOnly is! bool ||
        state is! String ||
        pendingEscalations is! num ||
        armedAt is! num ||
        goal is! String ||
        backlogJson is! List) {
      return null;
    }
    final runState = handlerRunStateFromWire(state);
    if (runState == null) return null;
    // Lenient like escalations below: a malformed item is recoverable detail —
    // rejecting the whole session over it would silently drop the armed card
    // (and its pending escalations) from the snapshot.
    final backlog = <HandlerInstructionItem>[];
    for (final e in backlogJson) {
      final item = HandlerInstructionItem.fromWire(e);
      if (item != null) backlog.add(item);
    }
    // Lenient (missing/malformed → empty) rather than rejecting the whole
    // session: an escalation row is recoverable detail, the armed session
    // itself is not.
    final escalations = <HandlerEscalation>[];
    final escalationsJson = json['escalations'];
    if (escalationsJson is List) {
      for (final e in escalationsJson) {
        final esc = HandlerEscalation.fromWire(terminalId, e);
        if (esc != null) escalations.add(esc);
      }
    }
    final judgeTool = json['judgeTool'];
    final judgeModel = json['judgeModel'];
    // Lenient like the rest: park detail is decoration on a session that must
    // render either way.
    final parkKind = json['parkKind'];
    final parkedUntil = json['parkedUntil'];
    return HandlerSessionState(
      terminalId: terminalId,
      notifyOnly: notifyOnly,
      runState: runState,
      pendingEscalations: pendingEscalations.toInt(),
      armedAt: armedAt.toInt(),
      goal: goal,
      backlog: backlog,
      escalations: escalations,
      judgeTool: judgeTool is String ? judgeTool : null,
      judgeModel: judgeModel is String ? judgeModel : null,
      parkKind: parkKind is String ? parkKind : null,
      parkedUntil: parkedUntil is num ? parkedUntil.toInt() : null,
      observability: handlerObservabilityFromWire(json['observability']),
    );
  }
}

/// One 1-tap answer offered on a decision card (spec §4.6). Mirrors the
/// bridge's `EscalationChoiceWire` (`bridge/src/protocol.ts`) and
/// `EscalationChoiceSchema` (`bridge/src/handler/session-store.ts`) — three
/// hand-written copies of one shape, so the bounds below move with them.
class HandlerEscalationChoice {
  /// Stable semantic name (`approve` / `reject`) that survives a round-trip
  /// through an OS notification action. Identity, never authority: a tap sends
  /// [text], which the bridge authored, never anything the caller supplies.
  final String choiceId;

  /// Chip label.
  final String label;

  /// What the tap sends into the session. Surfaces MUST render this alongside
  /// [label] rather than behind it — `[Approve]` carries the judge's draft
  /// reply verbatim, and a one-tap the user cannot read is one they cannot
  /// refuse.
  final String text;

  const HandlerEscalationChoice({
    required this.choiceId,
    required this.label,
    required this.text,
  });

  static const _maxChoiceId = 40;
  static const _maxLabel = 40;
  static const _maxText = 400;

  /// The wire's own rule. A control character would render as an unreadable
  /// chip and, on the PTY path, submit an extra line past the answer.
  static final _printable = RegExp(r'^[^\x00-\x1f\x7f]+$');

  static HandlerEscalationChoice? fromWire(dynamic json) {
    if (json is! Map) return null;
    final choiceId = json['choiceId'];
    final label = json['label'];
    final text = json['text'];
    if (choiceId is! String ||
        label is! String ||
        text is! String ||
        choiceId.isEmpty ||
        choiceId.length > _maxChoiceId ||
        label.isEmpty ||
        label.length > _maxLabel ||
        text.length > _maxText ||
        // Whitespace alone is dropped by every consumer of [text] — the send
        // path refuses to submit a bare newline into a session — so it would
        // render as a chip that silently does nothing.
        text.trim().isEmpty ||
        !_printable.hasMatch(text)) {
      return null;
    }
    return HandlerEscalationChoice(
      choiceId: choiceId,
      label: label,
      text: text,
    );
  }

  /// Parses the optional `choices` array carried by both the one-shot
  /// escalation push and the status replay. Returns null — never an empty list
  /// — whenever the row must fall back to the free-text reply sheet, so a
  /// surface renders a card exactly when this is non-null:
  ///
  ///  - the key is absent: an older bridge, or a draft this one declined to
  ///    make one-tappable. Tolerating absence is the whole compatibility
  ///    contract, the same one `kind` already established.
  ///  - [kind] is `resolve_in_session`. That escalation is an option-based
  ///    agent prompt, resolvable only by the chat RPC that needs a
  ///    permissionId the escalation never carries; a chip on one would inject
  ///    text that answers nothing while the bridge clears the row anyway. The
  ///    bridge refuses to mint these — this is the app's own floor, because a
  ///    dead button is invisible to whoever taps it.
  ///  - the count is outside the wire's 2..3, or any entry is malformed. A card
  ///    is never one chip, so a partial list is dropped whole rather than
  ///    rendered short — and dropping only the choices keeps the escalation
  ///    itself answerable by text.
  ///  - two entries share a [choiceId]. A tap is resolved by first match, so a
  ///    repeated id sends the text of a chip the user did not read — which is
  ///    exactly what passing the id rather than the choice is supposed to make
  ///    impossible.
  static List<HandlerEscalationChoice>? listFromWire(
    dynamic json, {
    String? kind,
  }) {
    if (kind == 'resolve_in_session') return null;
    if (json is! List || json.length < 2 || json.length > 3) return null;
    final choices = <HandlerEscalationChoice>[];
    for (final e in json) {
      final choice = fromWire(e);
      if (choice == null) return null;
      choices.add(choice);
    }
    if (choices.map((c) => c.choiceId).toSet().length != choices.length) {
      return null;
    }
    return choices;
  }
}

class HandlerEscalation {
  final String escalationId;
  final String terminalId;
  final String question;
  final String reasoning;
  final String draftReply;
  final String urgency; // 'normal' | 'high'
  final String? floorRule;
  final int at;
  // null/'reply' → free-text reply sheet; 'resolve_in_session' → option-based
  // prompt (permission/question) answered in the chat transcript UI.
  final String? kind;

  /// The quick choices to render as a decision card, or null for a plain
  /// free-text row. Never empty — see [HandlerEscalationChoice.listFromWire]
  /// for every reason this is null. [draftReply] is populated either way, so
  /// the free-text sheet is unaffected by its presence.
  final List<HandlerEscalationChoice>? choices;

  const HandlerEscalation({
    required this.escalationId,
    required this.terminalId,
    required this.question,
    required this.reasoning,
    required this.draftReply,
    required this.urgency,
    this.floorRule,
    required this.at,
    this.kind,
    this.choices,
  });

  /// The same escalation with its card withdrawn, still answerable in the
  /// user's own words. This is the fallback for every situation where a one-tap
  /// would be unsafe but the question is still open — degrading to the
  /// free-text row the app has always had, never to an unanswerable row.
  HandlerEscalation withoutChoices() => HandlerEscalation(
    escalationId: escalationId,
    terminalId: terminalId,
    question: question,
    reasoning: reasoning,
    draftReply: draftReply,
    urgency: urgency,
    floorRule: floorRule,
    at: at,
    kind: kind,
  );

  HandlerEscalationChoice? choiceById(String choiceId) {
    for (final c in choices ?? const <HandlerEscalationChoice>[]) {
      if (c.choiceId == choiceId) return c;
    }
    return null;
  }

  /// Parses one entry of a status snapshot's per-session `escalations` array.
  /// The wire entry has no terminalId (it is nested under its session), so the
  /// owning session's id is passed in.
  static HandlerEscalation? fromWire(String terminalId, dynamic json) {
    if (json is! Map) return null;
    final escalationId = json['escalationId'];
    final question = json['question'];
    final reasoning = json['reasoning'];
    final draftReply = json['draftReply'];
    final urgency = json['urgency'];
    final at = json['at'];
    if (escalationId is! String ||
        question is! String ||
        reasoning is! String ||
        draftReply is! String ||
        urgency is! String ||
        at is! num) {
      return null;
    }
    final floorRule = json['floorRule'];
    if (floorRule != null && floorRule is! String) return null;
    final kind = json['kind'];
    if (kind != null && kind is! String) return null;
    return HandlerEscalation(
      escalationId: escalationId,
      terminalId: terminalId,
      question: question,
      reasoning: reasoning,
      draftReply: draftReply,
      urgency: urgency,
      floorRule: floorRule as String?,
      at: at.toInt(),
      kind: kind as String?,
      choices: HandlerEscalationChoice.listFromWire(json['choices'], kind: kind),
    );
  }
}

/// One snapshot the bridge took before injecting a flagged reply, and the undo
/// it offers (spec §5.2). Mirrors `HandlerSnapshotWire` (`bridge/src/protocol.ts`).
///
/// Project-scoped rather than nested under a session: the offer outlives the
/// session that took it, and a wrapped-up session is when it matters most.
class HandlerSnapshot {
  final String snapshotId;

  /// The supervised slot the flagged reply was injected into.
  final String terminalId;
  final int at;

  // 'reset_hard' | 'force_push' | 'rm_rf' | 'git_clean'
  final String action;

  /// The command segment that tripped the floor.
  final String trigger;

  /// One line naming what was actually saved.
  final String summary;

  // 'available' | 'undone' | 'failed'
  final String state;

  /// Why the last undo attempt failed. Present only while [state] is 'failed'.
  final String? detail;

  const HandlerSnapshot({
    required this.snapshotId,
    required this.terminalId,
    required this.at,
    required this.action,
    required this.trigger,
    required this.summary,
    required this.state,
    this.detail,
  });

  /// 'failed' is undoable on purpose — the bridge treats a failed attempt as
  /// retryable, and an undo that could not run is not an undo that must not.
  /// A state a newer bridge invented is NOT offered: a tap that quietly does
  /// nothing is worse than no tap at all.
  bool get undoable => state == 'available' || state == 'failed';

  bool get undone => state == 'undone';

  /// Parses one entry of the status replay, or the flat advert envelope — the
  /// two carry the same fields, so this is the single parse site for both.
  static HandlerSnapshot? fromWire(dynamic json) {
    if (json is! Map) return null;
    final snapshotId = json['snapshotId'];
    final terminalId = json['terminalId'];
    final at = json['at'];
    final action = json['action'];
    final trigger = json['trigger'];
    final summary = json['summary'];
    final state = json['state'];
    if (snapshotId is! String ||
        terminalId is! String ||
        at is! num ||
        action is! String ||
        trigger is! String ||
        summary is! String ||
        state is! String) {
      return null;
    }
    final detail = json['detail'];
    return HandlerSnapshot(
      snapshotId: snapshotId,
      terminalId: terminalId,
      at: at.toInt(),
      action: action,
      trigger: trigger,
      summary: summary,
      state: state,
      detail: detail is String ? detail : null,
    );
  }
}

class HandlerActivityRecord {
  final String recordId;
  final int at;
  final String terminalId;
  // Keep in lockstep with the bridge's ActivityRecord.decision
  // (`bridge/src/handler/config.ts`) and HandlerActivityMessage
  // (`bridge/src/protocol.ts`) — an unlisted value fails at runtime as an
  // unrenderable feed row, never at compile time.
  // 'continue' | 'handle' | 'escalate' | 'armed' | 'goal_edited' |
  // 'item_done' | 'item_blocked' | 'item_skipped' | 'item_failed' |
  // 'instruction_dropped' | 'floor_warning' | 'wrapped_up' | 'parked' |
  // 'resumed'
  final String decision;
  final String reason;
  final String? detail;

  const HandlerActivityRecord({
    required this.recordId,
    required this.at,
    required this.terminalId,
    required this.decision,
    required this.reason,
    this.detail,
  });
}

/// Immutable app-side view of the bridge's Handler subsystem for one project.
/// The bridge is the source of truth; this is rebuilt from `handler:*`
/// messages and never persisted locally.
class HandlerState {
  /// What an absent per-session judge tool resolves to for PTY slots — the
  /// project's agent tool. Chat slots resolve from their own session entry.
  final String? defaultTool;
  final bool defaultNotifyOnly;
  final Map<String, HandlerSessionState> sessions; // keyed by terminalId
  final List<HandlerEscalation> escalations;
  final List<HandlerActivityRecord> activity;

  /// Undo offers for this project, oldest first. Not keyed by session — they
  /// survive the disarm of the session that took them.
  final List<HandlerSnapshot> snapshots;

  /// Snapshot ids whose `handler:undo` is out and whose result has not come
  /// back yet. The bridge re-states the entry either way, so this only keeps a
  /// second tap from looking live during the round trip.
  final Set<String> pendingUndo;

  const HandlerState({
    this.defaultTool,
    this.defaultNotifyOnly = false,
    required this.sessions,
    required this.escalations,
    required this.activity,
    this.snapshots = const [],
    this.pendingUndo = const {},
  });

  const HandlerState.initial()
    : defaultTool = null,
      defaultNotifyOnly = false,
      sessions = const {},
      escalations = const [],
      activity = const [],
      snapshots = const [],
      pendingUndo = const {};

  // Absence of any session is the wire's implicit 'off' — there is no
  // standalone off/on flag now that arming is per-terminal.
  bool get anyArmed => sessions.isNotEmpty;

  int get pendingEscalations =>
      sessions.values.fold(0, (n, s) => n + s.pendingEscalations);

  String? get latestEscalationId =>
      escalations.isEmpty ? null : escalations.last.escalationId;

  HandlerState copyWith({
    String? defaultTool,
    bool? defaultNotifyOnly,
    Map<String, HandlerSessionState>? sessions,
    List<HandlerEscalation>? escalations,
    List<HandlerActivityRecord>? activity,
    List<HandlerSnapshot>? snapshots,
    Set<String>? pendingUndo,
  }) {
    return HandlerState(
      defaultTool: defaultTool ?? this.defaultTool,
      defaultNotifyOnly: defaultNotifyOnly ?? this.defaultNotifyOnly,
      sessions: sessions ?? this.sessions,
      escalations: escalations ?? this.escalations,
      activity: activity ?? this.activity,
      snapshots: snapshots ?? this.snapshots,
      pendingUndo: pendingUndo ?? this.pendingUndo,
    );
  }
}
