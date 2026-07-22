import 'dart:async';

import '../models/ab_message.dart';
import '../models/handler_state.dart';
import '../project/project_session.dart';

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

  Stream<HandlerState> get stateStream => _stateController.stream;
  Stream<HandlerEscalation> get escalationStream =>
      _escalationController.stream;
  HandlerState get currentState => _state;
  String get projectId => session.projectId;

  HandlerService.fromSession(this.session) {
    _statusSub = session.statusStream.listen(_onStatusJson);
    _heavySub = session.heavyStream.listen(_onHeavyJson);
  }

  void _emit(HandlerState next) {
    _state = next;
    if (!_disposed) _stateController.add(next);
  }

  void _onStatusJson(Map<String, dynamic> json) {
    if (_disposed) return;
    if (json['type'] != 'handler:status') return;
    final msg = parseAbMessage(json);
    if (msg is! HandlerStatusMessage) return;
    _emit(_state.copyWith(
      enabled: msg.enabled,
      template: handlerTemplateFromWire(msg.template),
      model: msg.model,
      clearModel: msg.model == null,
      runState: handlerRunStateFromWire(msg.state),
      pendingEscalations: msg.pendingEscalations,
      // The bridge reports pending as an aggregate count, never per-id (see
      // engine.ts totalPending()), and there is no escalation-resolved wire
      // message — locally an escalation only leaves the list via reply().
      // When the count reaches 0 every escalation has been resolved (answered
      // directly in the terminal, auto-handled, or its terminal closed), so
      // drop the rows that would otherwise linger as stale, still-tappable
      // "Needs you" entries that re-send an answer into a now-unrelated prompt.
      // A non-zero shrink is left alone: without ids we can't tell which row
      // resolved, and the next status (→0) or the user's own reply reconciles.
      escalations: msg.pendingEscalations == 0 ? const [] : null,
    ));
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    if (_disposed) return;
    switch (json['type']) {
      case 'handler:escalation':
        final msg = parseAbMessage(json);
        if (msg is! HandlerEscalationMessage) return;
        if (_state.escalations
            .any((e) => e.escalationId == msg.escalationId)) {
          return; // dedup
        }
        final escalation = HandlerEscalation(
          escalationId: msg.escalationId,
          terminalId: msg.terminalId,
          question: msg.question,
          reasoning: msg.reasoning,
          draftReply: msg.draftReply,
          urgency: msg.urgency,
        );
        _emit(_state.copyWith(
            escalations: [..._state.escalations, escalation]));
        _escalationController.add(escalation);
        break;
      case 'handler:activity':
        final msg = parseAbMessage(json);
        if (msg is! HandlerActivityMessage) return;
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
        _emit(_state.copyWith(
          activity:
              next.length > _activityCap ? next.sublist(0, _activityCap) : next,
        ));
        break;
    }
  }

  void configure({
    required bool enabled,
    required HandlerTemplate template,
    String? model,
  }) {
    if (_disposed) return;
    session.send(createAbMessage('handler:configure', {
      'projectId': session.projectId,
      'enabled': enabled,
      'template': handlerTemplateToWire(template),
      'model': ?model,
    }));
  }

  /// Send the user's answer for [escalation] into the live PTY. Reuses
  /// `terminal:input` (no new wire type); the trailing `\r` submits the line,
  /// matching the bridge act path. The bridge resets its runaway guard on any
  /// terminal:input via onUserReply. Optimistically drops the escalation locally
  /// AND decrements pendingEscalations (clamped at 0) so the header pill and the
  /// tab badge — which read the count, not the list — don't show a stale "needs
  /// you N" with an empty list for the round-trip until the authoritative next
  /// handler:status reconciles it.
  void reply(HandlerEscalation escalation, String text) {
    if (_disposed) return;
    // Never submit an empty answer: '$text\r' with blank text is a bare Enter,
    // which accepts the default at whatever prompt the agent is showing (e.g. a
    // [Y/n] confirmation). The reply sheet also disables its send button when
    // empty; this is the enforcement floor.
    if (text.trim().isEmpty) return;
    final wasPresent =
        _state.escalations.any((e) => e.escalationId == escalation.escalationId);
    session.send(createAbMessage('terminal:input', {
      'terminalId': escalation.terminalId,
      'data': '$text\r',
    }));
    _emit(_state.copyWith(
      escalations: _state.escalations
          .where((e) => e.escalationId != escalation.escalationId)
          .toList(),
      pendingEscalations: wasPresent
          ? (_state.pendingEscalations - 1).clamp(0, _state.pendingEscalations)
          : _state.pendingEscalations,
    ));
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
