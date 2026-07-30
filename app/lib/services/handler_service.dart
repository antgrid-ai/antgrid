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
  final _planResultController =
      StreamController<HandlerPlanResultMessage>.broadcast();
  HandlerState _state = const HandlerState.initial();
  bool _disposed = false;
  // agent:prompt correlation ids — the driver only needs per-send uniqueness.
  int _reqCounter = 0;

  // Keyed by terminalId. `sessions` in [HandlerState] only holds currently-armed
  // sessions, so a disarmed or wrapped-up terminal's brief would otherwise
  // vanish — this is what the briefing sheet's re-arm flow starts from instead
  // of calling plan again. Bounded and insertion-ordered (oldest evicted first):
  // terminal ids are per-session UUIDs, so an unbounded map would accumulate a
  // full brief for every slot the project ever opened, for the app's lifetime.
  static const _briefCacheCap = 50;
  final Map<String, HandlerBrief> _lastKnownBrief = {};

  // One cache policy for the per-terminal maps: re-insert so a refreshed
  // entry counts as most-recent, evict oldest at cap.
  void _rememberBounded<V>(Map<String, V> cache, String terminalId, V value) {
    cache.remove(terminalId);
    cache[terminalId] = value;
    while (cache.length > _briefCacheCap) {
      cache.remove(cache.keys.first);
    }
  }

  void _rememberBrief(String terminalId, HandlerBrief brief) =>
      _rememberBounded(_lastKnownBrief, terminalId, brief);

  // Judge picks, keyed by terminalId, same bound/eviction as _lastKnownBrief:
  // `sessions` only holds currently-armed sessions, so a disarmed terminal's
  // judge pick would otherwise vanish and the next arm would silently reset to
  // Default — the exact bug moving this off project level was meant to fix.
  final Map<String, ({String? tool, String? model})> _lastKnownJudge = {};

  // Records a clear (both null) too — a status snapshot showing an armed
  // session is authoritative for that session's judge, including "cleared
  // back to default". Skipping nulls here was the bug: a re-arm that cleared
  // the judge left the previous non-null pick cached, so the next time the
  // sheet opened it silently re-seeded (and re-armed) the stale tool.
  void _rememberJudge(String terminalId, String? tool, String? model) =>
      _rememberBounded(_lastKnownJudge, terminalId, (tool: tool, model: model));

  Stream<HandlerState> get stateStream => _stateController.stream;
  Stream<HandlerEscalation> get escalationStream =>
      _escalationController.stream;
  Stream<HandlerPlanResultMessage> get planResultStream =>
      _planResultController.stream;
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
    final sessions = <String, HandlerSessionState>{};
    for (final raw in msg.sessions) {
      final s = HandlerSessionState.fromWire(raw);
      if (s == null) continue;
      sessions[s.terminalId] = s;
      _rememberBrief(s.terminalId, s.brief);
      _rememberJudge(s.terminalId, s.judgeTool, s.judgeModel);
    }
    // Replace wholesale (welcome-replay safe) rather than merge — the
    // snapshot is the bridge's full current set of armed sessions, and it
    // replays every unanswered escalation, so the flat list is rebuilt from
    // it too. This is what lets the "needs you" rows survive an app restart
    // or reconnect instead of leaving a badge that points at nothing.
    final escalations = [for (final s in sessions.values) ...s.escalations]
      ..sort((a, b) => a.at.compareTo(b.at));
    final next = _state.copyWith(
      sessions: sessions,
      defaultNotifyOnly: msg.defaultNotifyOnly,
      escalations: escalations,
      defaultTool: msg.defaultTool,
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
        );
        _emit(
          _state.copyWith(escalations: [..._state.escalations, escalation]),
        );
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
        _emit(
          _state.copyWith(
            activity: next.length > _activityCap
                ? next.sublist(0, _activityCap)
                : next,
          ),
        );
        break;
      case 'handler:planResult':
        final msg = parseAbMessage(json);
        if (msg is! HandlerPlanResultMessage) return;
        final previousBrief = HandlerBrief.fromWire(msg.previousBrief);
        if (previousBrief != null) {
          _rememberBrief(msg.terminalId, previousBrief);
        }
        _rememberJudge(msg.terminalId, msg.judgeTool, msg.judgeModel);
        if (!_disposed) _planResultController.add(msg);
        break;
    }
  }

  /// Ask the bridge to draft a brief for [terminalId] (`handler:planRequest`).
  /// The result arrives asynchronously on [planResultStream]. A non-null
  /// [judgeTool]/[judgeModel] is a one-shot override for this plan call
  /// (`''` = the session's default tool); null omits the key = stored choice.
  void requestPlan(String terminalId, {String? judgeTool, String? judgeModel}) {
    if (_disposed) return;
    session.send(
      createAbMessage('handler:planRequest', {
        'projectId': session.projectId,
        'terminalId': terminalId,
        'judgeTool': ?judgeTool,
        'judgeModel': ?judgeModel,
      }),
    );
  }

  /// Arm [terminalId] with [brief]. Caches the brief into [lastKnownBrief]
  /// immediately — no need to wait for the next status snapshot to round-trip.
  ///
  /// [judgeTool]/[judgeModel] are this session's judge choice as shown in the
  /// briefing sheet; `''` clears back to default and a name sets it. The sheet
  /// always sends explicit values. Pass null (the default) to leave the
  /// session's stored judge record untouched, for any caller that doesn't
  /// surface a picker — the keys are omitted from the wire message, which the
  /// bridge reads as "no change" (so arming without touching the judge picker
  /// never rewrites its per-session record).
  void arm({
    required String terminalId,
    required HandlerBrief brief,
    required bool notifyOnly,
    String? judgeTool,
    String? judgeModel,
  }) {
    if (_disposed) return;
    _rememberBrief(terminalId, brief);
    if (judgeTool != null || judgeModel != null) {
      // Optimistically mirror the bridge's applyJudgeChoice ('' clears, a
      // name sets, an omitted field keeps its old value) so lastKnownJudge is
      // right immediately: reopening the sheet before the status snapshot
      // round-trips would otherwise seed the picker with the pre-arm judge —
      // and committing that stale value silently reverts this arm's choice.
      final prev = lastKnownJudge(terminalId);
      _rememberJudge(
        terminalId,
        judgeTool != null ? (judgeTool.isEmpty ? null : judgeTool) : prev?.tool,
        judgeModel != null
            ? (judgeModel.trim().isEmpty ? null : judgeModel.trim())
            : prev?.model,
      );
    }
    session.send(
      createAbMessage('handler:configure', {
        'projectId': session.projectId,
        'terminalId': terminalId,
        'armed': true,
        'brief': brief.toWire(),
        'notifyOnly': notifyOnly,
        'judgeTool': ?judgeTool,
        'judgeModel': ?judgeModel,
      }),
    );
  }

  /// Disarm [terminalId]. No brief is sent — `armed:false` alone tells the
  /// bridge to drop the session (the wire schema requires `armed && brief`
  /// only for arming).
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

  /// Last brief seen for [terminalId], retained after disarm/wrap-up.
  HandlerBrief? lastKnownBrief(String terminalId) =>
      _lastKnownBrief[terminalId];

  /// The judge pick to seed the briefing sheet from (status snapshots,
  /// planResult echoes, and optimistic [arm] writes feed the cache). Null =
  /// never picked.
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
  /// app-side resolution — the briefing sheet's "Default (…)" label and the
  /// handler tab's judge chip both go through here so they can't drift.
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
  /// guard. Optimistically drops the escalation AND decrements the answering
  /// session's pending count locally so the header pill and tab badge don't
  /// show a stale "needs you" over an empty list for the round-trip; the next
  /// handler:status snapshot reconciles authoritatively.
  void reply(HandlerEscalation escalation, String text) {
    if (_disposed) return;
    // Never submit an empty answer: '$text\r' with blank text is a bare Enter,
    // which accepts the default at whatever prompt the agent is showing (e.g. a
    // [Y/n] confirmation). The reply sheet also disables its send button when
    // empty; this is the enforcement floor.
    if (text.trim().isEmpty) return;
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
    final sessions = Map<String, HandlerSessionState>.from(_state.sessions);
    final answered = sessions[escalation.terminalId];
    if (answered != null) {
      sessions[escalation.terminalId] = answered.copyWith(
        pendingEscalations: 0,
        escalations: const [],
        runState: answered.runState == HandlerRunState.needsYou
            ? HandlerRunState.watching
            : answered.runState,
      );
    }
    _emit(
      _state.copyWith(
        sessions: sessions,
        escalations: _state.escalations
            .where((e) => e.terminalId != escalation.terminalId)
            .toList(),
      ),
    );
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
    await _planResultController.close();
  }
}
