enum HandlerTemplate { watchdog, closer, autopilot }

enum HandlerRunState { off, watching, handling, needsYou }

HandlerTemplate handlerTemplateFromWire(String s) {
  switch (s) {
    case 'closer':
      return HandlerTemplate.closer;
    case 'autopilot':
      return HandlerTemplate.autopilot;
    default:
      return HandlerTemplate.watchdog;
  }
}

String handlerTemplateToWire(HandlerTemplate t) {
  switch (t) {
    case HandlerTemplate.watchdog:
      return 'watchdog';
    case HandlerTemplate.closer:
      return 'closer';
    case HandlerTemplate.autopilot:
      return 'autopilot';
  }
}

HandlerRunState handlerRunStateFromWire(String s) {
  switch (s) {
    case 'watching':
      return HandlerRunState.watching;
    case 'handling':
      return HandlerRunState.handling;
    case 'needs_you':
      return HandlerRunState.needsYou;
    default:
      return HandlerRunState.off;
  }
}

class HandlerEscalation {
  final String escalationId;
  final String terminalId;
  final String question;
  final String reasoning;
  final String draftReply;
  final String urgency; // 'normal' | 'high'

  const HandlerEscalation({
    required this.escalationId,
    required this.terminalId,
    required this.question,
    required this.reasoning,
    required this.draftReply,
    required this.urgency,
  });
}

class HandlerActivityRecord {
  final String recordId;
  final int at;
  final String terminalId;
  final String decision; // 'continue' | 'handle' | 'escalate'
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
/// The bridge is the source of truth; this is rebuilt from `handler:*` messages
/// and never persisted locally.
class HandlerState {
  final bool enabled;
  final HandlerTemplate template;
  final String? model;
  final HandlerRunState runState;
  final int pendingEscalations;
  final List<HandlerEscalation> escalations;
  final List<HandlerActivityRecord> activity;

  const HandlerState({
    required this.enabled,
    required this.template,
    required this.model,
    required this.runState,
    required this.pendingEscalations,
    required this.escalations,
    required this.activity,
  });

  const HandlerState.initial()
      : enabled = false,
        template = HandlerTemplate.watchdog,
        model = null,
        runState = HandlerRunState.off,
        pendingEscalations = 0,
        escalations = const [],
        activity = const [];

  String? get latestEscalationId =>
      escalations.isEmpty ? null : escalations.last.escalationId;

  HandlerState copyWith({
    bool? enabled,
    HandlerTemplate? template,
    String? model,
    bool clearModel = false,
    HandlerRunState? runState,
    int? pendingEscalations,
    List<HandlerEscalation>? escalations,
    List<HandlerActivityRecord>? activity,
  }) {
    return HandlerState(
      enabled: enabled ?? this.enabled,
      template: template ?? this.template,
      model: clearModel ? null : (model ?? this.model),
      runState: runState ?? this.runState,
      pendingEscalations: pendingEscalations ?? this.pendingEscalations,
      escalations: escalations ?? this.escalations,
      activity: activity ?? this.activity,
    );
  }
}
