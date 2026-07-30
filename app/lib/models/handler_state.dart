enum HandlerRunState { watching, handling, needsYou }

HandlerRunState? handlerRunStateFromWire(String s) {
  switch (s) {
    case 'watching':
      return HandlerRunState.watching;
    case 'handling':
      return HandlerRunState.handling;
    case 'needsYou':
    case 'needs_you':
      return HandlerRunState.needsYou;
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
  }
}

/// A handler's brief — what it will/won't do, when to wake the user, and the
/// checklist to run once `doneWhen` is met. Mirrors the bridge's
/// `HandlerBriefWire` (`bridge/src/protocol.ts`).
class HandlerBrief {
  final String taskSummary;
  final List<String> willHandle;
  final List<String> wakeFor;
  final String? doneWhen;
  final List<String> thenItems;

  const HandlerBrief({
    required this.taskSummary,
    required this.willHandle,
    required this.wakeFor,
    this.doneWhen,
    required this.thenItems,
  });

  static HandlerBrief? fromWire(dynamic json) {
    if (json is! Map) return null;
    final taskSummary = json['taskSummary'];
    final willHandleJson = json['willHandle'];
    final wakeForJson = json['wakeFor'];
    final thenItemsJson = json['thenItems'];
    if (taskSummary is! String ||
        willHandleJson is! List ||
        wakeForJson is! List ||
        thenItemsJson is! List) {
      return null;
    }
    if (willHandleJson.any((e) => e is! String) ||
        wakeForJson.any((e) => e is! String) ||
        thenItemsJson.any((e) => e is! String)) {
      return null;
    }
    final doneWhen = json['doneWhen'];
    if (doneWhen != null && doneWhen is! String) return null;
    return HandlerBrief(
      taskSummary: taskSummary,
      willHandle: willHandleJson.cast<String>(),
      wakeFor: wakeForJson.cast<String>(),
      doneWhen: doneWhen as String?,
      thenItems: thenItemsJson.cast<String>(),
    );
  }

  Map<String, dynamic> toWire() => {
    'taskSummary': taskSummary,
    'willHandle': willHandle,
    'wakeFor': wakeFor,
    if (doneWhen != null) 'doneWhen': doneWhen,
    'thenItems': thenItems,
  };
}

class HandlerLedgerEntry {
  final String item;
  final String evidence;
  final int at;

  const HandlerLedgerEntry({
    required this.item,
    required this.evidence,
    required this.at,
  });

  static HandlerLedgerEntry? fromWire(dynamic json) {
    if (json is! Map) return null;
    final item = json['item'];
    final evidence = json['evidence'];
    final at = json['at'];
    if (item is! String || evidence is! String || at is! num) return null;
    return HandlerLedgerEntry(item: item, evidence: evidence, at: at.toInt());
  }
}

/// One armed handler session (per terminal). Mirrors the bridge's
/// `HandlerSessionSnapshot` (`bridge/src/protocol.ts`).
class HandlerSessionState {
  final String terminalId;
  final bool notifyOnly;
  final HandlerRunState runState;
  final int pendingEscalations;
  final int armedAt;
  final bool doneWhenMet;
  final HandlerBrief brief;
  final List<HandlerLedgerEntry> ledger;

  /// Unanswered escalations replayed with every status snapshot, so the
  /// "needs you" list survives app restarts and reconnects (the one-shot
  /// `handler:escalation` push alone would be lost with the process).
  final List<HandlerEscalation> escalations;

  /// Per-session judge overrides (null = the session's own tool / the judge
  /// CLI's default model). Mirrors the wire snapshot.
  final String? judgeTool;
  final String? judgeModel;

  const HandlerSessionState({
    required this.terminalId,
    required this.notifyOnly,
    required this.runState,
    required this.pendingEscalations,
    required this.armedAt,
    required this.doneWhenMet,
    required this.brief,
    required this.ledger,
    required this.escalations,
    this.judgeTool,
    this.judgeModel,
  });

  /// Count of `brief.thenItems` this session's ledger already covers.
  int get thenTotal => brief.thenItems.length;
  int get thenSatisfied =>
      ledger.where((e) => brief.thenItems.contains(e.item)).length;

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
    doneWhenMet: doneWhenMet,
    brief: brief,
    ledger: ledger,
    escalations: escalations ?? this.escalations,
    judgeTool: judgeTool,
    judgeModel: judgeModel,
  );

  static HandlerSessionState? fromWire(dynamic json) {
    if (json is! Map) return null;
    final terminalId = json['terminalId'];
    final notifyOnly = json['notifyOnly'];
    final state = json['state'];
    final pendingEscalations = json['pendingEscalations'];
    final armedAt = json['armedAt'];
    final doneWhenMet = json['doneWhenMet'];
    final ledgerJson = json['ledger'];
    if (terminalId is! String ||
        notifyOnly is! bool ||
        state is! String ||
        pendingEscalations is! num ||
        armedAt is! num ||
        doneWhenMet is! bool ||
        ledgerJson is! List) {
      return null;
    }
    final runState = handlerRunStateFromWire(state);
    if (runState == null) return null;
    final brief = HandlerBrief.fromWire(json['brief']);
    if (brief == null) return null;
    // Lenient like escalations below: a malformed ledger row is recoverable
    // detail — rejecting the whole session over it would silently drop the
    // armed card (and its pending escalations) from the snapshot.
    final ledger = <HandlerLedgerEntry>[];
    for (final e in ledgerJson) {
      final entry = HandlerLedgerEntry.fromWire(e);
      if (entry != null) ledger.add(entry);
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
    return HandlerSessionState(
      terminalId: terminalId,
      notifyOnly: notifyOnly,
      runState: runState,
      pendingEscalations: pendingEscalations.toInt(),
      armedAt: armedAt.toInt(),
      doneWhenMet: doneWhenMet,
      brief: brief,
      ledger: ledger,
      escalations: escalations,
      judgeTool: judgeTool is String ? judgeTool : null,
      judgeModel: judgeModel is String ? judgeModel : null,
    );
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
  });

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
    );
  }
}

class HandlerActivityRecord {
  final String recordId;
  final int at;
  final String terminalId;
  // 'continue' | 'handle' | 'escalate' | 'brief_armed' | 'brief_edited' |
  // 'item_satisfied' | 'wrapped_up'
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

  const HandlerState({
    this.defaultTool,
    this.defaultNotifyOnly = false,
    required this.sessions,
    required this.escalations,
    required this.activity,
  });

  const HandlerState.initial()
    : defaultTool = null,
      defaultNotifyOnly = false,
      sessions = const {},
      escalations = const [],
      activity = const [];

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
  }) {
    return HandlerState(
      defaultTool: defaultTool ?? this.defaultTool,
      defaultNotifyOnly: defaultNotifyOnly ?? this.defaultNotifyOnly,
      sessions: sessions ?? this.sessions,
      escalations: escalations ?? this.escalations,
      activity: activity ?? this.activity,
    );
  }
}
