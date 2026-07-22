import 'dart:async';

import '../models/ab_message.dart';
import '../models/agent_event.dart';
import '../project/project_session.dart';

/// One turn's assembled state.
class AgentTurn {
  final String turnId;
  final List<AgentItem> items;
  final String? stopReason;
  final AgentError? error;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const AgentTurn({
    required this.turnId,
    required this.items,
    this.stopReason,
    this.error,
    this.startedAt,
    this.endedAt,
  });

  AgentTurn copyWith({
    List<AgentItem>? items,
    String? stopReason,
    AgentError? error,
    DateTime? endedAt,
  }) => AgentTurn(
    turnId: turnId,
    items: items ?? this.items,
    stopReason: stopReason ?? this.stopReason,
    error: error ?? this.error,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
  );
}

class AgentSessionState {
  final List<AgentTurn> turns;
  final List<AgentPermissionRequest> pendingPermissions;
  final List<AgentQuestion> pendingQuestions;
  final AgentUsage? usage;

  /// Historical per-message usage keyed by the assistant item it describes.
  final Map<String, AgentTokenUsage> usageByItem;

  /// Latest live usage frame for each turn.
  final Map<String, AgentTokenUsage> usageByTurn;
  final AgentCapabilities? capabilities;

  /// Proactive "a newer CLI exists" notice for this session's tool, or null.
  /// Advisory — rendered as a dismissible chip.
  final AgentUpdateAvailable? updateAvailable;

  /// True while an in-app `agent:update` is running (quiesce → update → restart).
  final bool updating;

  /// Terminal outcome of the last update run, or null. Surfaced then dismissed.
  final AgentUpdateResult? updateResult;
  final bool loading;
  final bool hydrationFailed;

  /// The turn still awaiting its `agent:turn-end`, or null. This is the single
  /// definition of "a turn is running": the UI renders liveness from it and
  /// `cancel` names it so the bridge closes the turn this client actually
  /// shows. Two derivations that drift would put a stop button on one turn and
  /// cancel another.
  AgentTurn? get openTurn =>
      turns.isNotEmpty && turns.last.stopReason == null ? turns.last : null;

  bool get isRunning => openTurn != null;

  const AgentSessionState({
    this.turns = const [],
    this.pendingPermissions = const [],
    this.pendingQuestions = const [],
    this.usage,
    this.usageByItem = const {},
    this.usageByTurn = const {},
    this.capabilities,
    this.updateAvailable,
    this.updating = false,
    this.updateResult,
    this.loading = false,
    this.hydrationFailed = false,
  });

  AgentSessionState copyWith({
    List<AgentTurn>? turns,
    List<AgentPermissionRequest>? pendingPermissions,
    List<AgentQuestion>? pendingQuestions,
    AgentUsage? usage,
    Map<String, AgentTokenUsage>? usageByItem,
    Map<String, AgentTokenUsage>? usageByTurn,
    AgentCapabilities? capabilities,
    AgentUpdateAvailable? updateAvailable,
    bool clearUpdateAvailable = false,
    bool? updating,
    AgentUpdateResult? updateResult,
    bool clearUpdateResult = false,
    bool? loading,
    bool? hydrationFailed,
  }) => AgentSessionState(
    turns: turns ?? this.turns,
    pendingPermissions: pendingPermissions ?? this.pendingPermissions,
    pendingQuestions: pendingQuestions ?? this.pendingQuestions,
    usage: usage ?? this.usage,
    usageByItem: usageByItem ?? this.usageByItem,
    usageByTurn: usageByTurn ?? this.usageByTurn,
    capabilities: capabilities ?? this.capabilities,
    updateAvailable: clearUpdateAvailable
        ? null
        : (updateAvailable ?? this.updateAvailable),
    updating: updating ?? this.updating,
    updateResult: clearUpdateResult
        ? null
        : (updateResult ?? this.updateResult),
    loading: loading ?? this.loading,
    hydrationFailed: hydrationFailed ?? this.hydrationFailed,
  );
}

/// Per-project structured-agent transcript service. Mirrors TerminalService:
/// subscribes at construction (welcome-replay safe), keys state by the chat
/// session id so one project can hold several concurrent chat sessions.
class AgentSessionService {
  final ProjectSession session;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _disposed = false;

  final Map<String, AgentSessionState> _states = {};
  final Map<String, StreamController<AgentSessionState>> _controllers = {};

  // Accumulated delta text, keyed by a composite '$sessionId/$itemId' (item ids
  // are only unique within a session). _deltaBuffers feed message/reasoning
  // .text; _terminalBuffers feed a tool_call's streamed shell output (its
  // terminal content block).
  final Map<String, StringBuffer> _deltaBuffers = {};
  final Map<String, StringBuffer> _terminalBuffers = {};

  // Item ids touched by deltas since the last flush, per session. Delta-driven
  // state emission is coalesced to one rebuild per microtask — codex streams a
  // frame per token, and emitting a whole-transcript copy per token is
  // quadratic.
  Map<String, Set<String>> _dirtyItems = {};
  bool _flushScheduled = false;

  // sessionIds whose last hydrateIfNeeded() call came back with no turns (a
  // mid-turn attach: the in-flight turn was excluded from the snapshot).
  // Consumed exactly once by the next agent:turn-end for that session.
  final Set<String> _pendingHydrationRetry = {};

  // sessionIds with a transcriptSnapshot fetch in flight. This is what `loading`
  // is derived from (see _setState): an attach fires unrelated frames —
  // capabilities, status — while the snapshot is still on the wire, and each one
  // would otherwise settle `loading` to false and render the empty state under a
  // transcript that IS about to arrive.
  final Set<String> _hydrating = {};

  String get projectId => session.projectId;

  AgentSessionService.fromSession(this.session) {
    _heavySub = session.heavyStream.listen(_onJson);
    _statusSub = session.statusStream.listen(_onJson);
  }

  AgentSessionState stateFor(String sessionId) =>
      _states[sessionId] ?? const AgentSessionState(loading: true);

  Stream<AgentSessionState> stateStreamFor(String sessionId) => _controllers
      .putIfAbsent(
        sessionId,
        () => StreamController<AgentSessionState>.broadcast(),
      )
      .stream;

  void _setState(String sessionId, AgentSessionState s) {
    if (_disposed) return;
    s = s.copyWith(loading: _hydrating.contains(sessionId));
    _states[sessionId] = s;
    _controllers[sessionId]?.add(s);
  }

  String _bufKey(String sessionId, String itemId) => '$sessionId/$itemId';

  // Envelope timestamp (epoch ms). Live = send time ≈ now; on resume the bridge
  // overrides it with the real historical time (see codex/opencode
  // resume-replay), so reading it here is what dates replayed turns correctly
  // instead of the replay moment.
  DateTime? _envTime(Map<String, dynamic> json) {
    final ts = json['timestamp'];
    return ts is num ? DateTime.fromMillisecondsSinceEpoch(ts.toInt()) : null;
  }

  /// Re-dispatch a batch of raw AbMessage frames individually. Shared by the
  /// two paths that carry a transcript as a `frames` list — the pushed
  /// `agent:transcript-replay` and the `session.transcriptSnapshot` pull — so
  /// each inner frame is read with its OWN envelope timestamp and replayed
  /// turns keep their original times rather than the batch's send time.
  void _dispatchFrames(Iterable<Object?> frames) {
    for (final f in frames) {
      if (f is Map) _onJson(f.cast<String, dynamic>());
    }
  }

  void _onJson(Map<String, dynamic> json) {
    if (_disposed) return;
    final parsed = parseAbMessage(json);
    if (parsed is AgentTranscriptReplay) {
      _dispatchFrames(parsed.frames);
      return;
    }
    final at = _envTime(json);
    if (parsed is AgentTurnStart) {
      final s = stateFor(parsed.sessionId);
      final exists = s.turns.any((t) => t.turnId == parsed.turnId);
      if (!exists) {
        _setState(
          parsed.sessionId,
          s.copyWith(
            turns: [
              ...s.turns,
              AgentTurn(
                turnId: parsed.turnId,
                items: const [],
                startedAt: at ?? DateTime.now(),
              ),
            ],
          ),
        );
      }
    } else if (parsed is AgentSessionReset) {
      _clearSession(parsed.sessionId);
    } else if (parsed is AgentItemAdded) {
      _upsertItem(parsed.sessionId, parsed.turnId, parsed.item, at);
    } else if (parsed is AgentItemDelta) {
      _applyDelta(parsed);
    } else if (parsed is AgentItemUpdated) {
      // Snapshot supersedes any pending delta accumulation.
      _clearBuffers(parsed.sessionId, parsed.item.itemId);
      _upsertItem(parsed.sessionId, parsed.turnId, parsed.item, at);
    } else if (parsed is AgentTurnEnd) {
      _endTurn(parsed, at);
    } else if (parsed is AgentPermissionRequest) {
      final s = stateFor(parsed.sessionId);
      _setState(
        parsed.sessionId,
        s.copyWith(pendingPermissions: [...s.pendingPermissions, parsed]),
      );
    } else if (parsed is AgentQuestion) {
      final s = stateFor(parsed.sessionId);
      _setState(
        parsed.sessionId,
        s.copyWith(pendingQuestions: [...s.pendingQuestions, parsed]),
      );
    } else if (parsed is AgentRequestRetracted) {
      final s = stateFor(parsed.sessionId);
      _setState(
        parsed.sessionId,
        s.copyWith(
          pendingPermissions: parsed.permissionId == null
              ? s.pendingPermissions
              : s.pendingPermissions
                    .where((p) => p.permissionId != parsed.permissionId)
                    .toList(),
          pendingQuestions: parsed.questionId == null
              ? s.pendingQuestions
              : s.pendingQuestions
                    .where((q) => q.questionId != parsed.questionId)
                    .toList(),
        ),
      );
    } else if (parsed is AgentSnapshot) {
      _applySnapshot(parsed, at);
    } else if (parsed is AgentUsageEvent) {
      final s = stateFor(parsed.sessionId);
      final perMessage = parsed.usage.last ?? parsed.usage.total;
      final itemId = parsed.itemId;
      if (itemId != null) {
        // Replayed usage predates live state, so it belongs only to its
        // historical message and must not rewind the session meter.
        _setState(
          parsed.sessionId,
          s.copyWith(usageByItem: {...s.usageByItem, itemId: perMessage}),
        );
      } else {
        // Capacity and occupancy may arrive independently; retain the last
        // known window when a later live frame carries token counts only.
        final merged = AgentUsage(
          total: parsed.usage.total,
          last: parsed.usage.last,
          contextWindow: parsed.usage.contextWindow ?? s.usage?.contextWindow,
        );
        final turnId = parsed.turnId;
        _setState(
          parsed.sessionId,
          s.copyWith(
            usage: merged,
            usageByTurn: turnId != null && perMessage.totalTokens != null
                ? {...s.usageByTurn, turnId: perMessage}
                : null,
          ),
        );
      }
    } else if (parsed is AgentCapabilities) {
      _setState(
        parsed.sessionId,
        stateFor(parsed.sessionId).copyWith(capabilities: parsed),
      );
    } else if (parsed is AgentUpdateAvailable) {
      final sid = parsed.sessionId;
      if (sid != null) {
        _setState(sid, stateFor(sid).copyWith(updateAvailable: parsed));
      }
    } else if (parsed is AgentUpdateResult) {
      final sid = parsed.sessionId;
      if (sid != null) {
        _setState(
          sid,
          stateFor(sid).copyWith(
            updating: false,
            updateResult: parsed,
            // Success clears the "update available" notice; a failure leaves it
            // so the chip stays and the user can retry.
            clearUpdateAvailable: parsed.ok,
          ),
        );
      }
    }
  }

  AgentTurn? _turnById(String sessionId, String turnId) {
    for (final t in stateFor(sessionId).turns) {
      if (t.turnId == turnId) return t;
    }
    return null;
  }

  List<AgentTurn> _replaceTurn(String sessionId, AgentTurn updated) => stateFor(
    sessionId,
  ).turns.map((t) => t.turnId == updated.turnId ? updated : t).toList();

  void _upsertItem(
    String sessionId,
    String turnId,
    AgentItem item, [
    DateTime? at,
  ]) {
    var turn = _turnById(sessionId, turnId);
    if (turn == null) {
      // An item arrived before turn/started (or a reconnect delivered items
      // first). Stamp startedAt now so WorkingRow's elapsed clock stays stable
      // across widget remounts instead of reseeding to 0 each time.
      turn = AgentTurn(
        turnId: turnId,
        items: const [],
        startedAt: at ?? DateTime.now(),
      );
      final s = stateFor(sessionId);
      _setState(sessionId, s.copyWith(turns: [...s.turns, turn]));
    }
    final items = List<AgentItem>.from(turn.items);
    final idx = items.indexWhere((i) => i.itemId == item.itemId);
    if (idx >= 0) {
      // Keep the first-seen time; a snapshot/update re-parse carries no time.
      items[idx] = item.copyWith(timestamp: items[idx].timestamp ?? at);
    } else {
      items.add(item.copyWith(timestamp: at));
    }
    _setState(
      sessionId,
      stateFor(
        sessionId,
      ).copyWith(turns: _replaceTurn(sessionId, turn.copyWith(items: items))),
    );
  }

  void _applyDelta(AgentItemDelta delta) {
    final turn = _turnById(delta.sessionId, delta.turnId);
    if (turn == null) return;
    final idx = turn.items.indexWhere((i) => i.itemId == delta.itemId);
    if (idx < 0) return; // orphan delta — the next item snapshot recovers it
    final item = turn.items[idx];
    final key = _bufKey(delta.sessionId, delta.itemId);
    switch (item.kind) {
      case 'message':
      case 'reasoning':
        _deltaBuffers
            .putIfAbsent(key, () => StringBuffer(item.text ?? ''))
            .write(delta.textChunk);
      case 'tool_call':
        _terminalBuffers
            .putIfAbsent(key, () => StringBuffer(_terminalDataOf(item)))
            .write(delta.textChunk);
      default:
        return; // plan/subtask/compaction don't stream text into the transcript
    }
    _dirtyItems.putIfAbsent(delta.sessionId, () => {}).add(delta.itemId);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled || _disposed) return;
    _flushScheduled = true;
    scheduleMicrotask(_flushDeltas);
  }

  void _flushDeltas() {
    _flushScheduled = false;
    if (_disposed || _dirtyItems.isEmpty) return;
    final dirtyBySession = _dirtyItems;
    _dirtyItems = {};
    for (final entry in dirtyBySession.entries) {
      final sessionId = entry.key;
      final dirty = entry.value;
      if (dirty.isEmpty) continue;
      final turns = stateFor(sessionId).turns.map((turn) {
        var changed = false;
        final items = List<AgentItem>.from(turn.items);
        for (var i = 0; i < items.length; i++) {
          if (!dirty.contains(items[i].itemId)) continue;
          final key = _bufKey(sessionId, items[i].itemId);
          final buf = _deltaBuffers[key];
          if (buf != null) {
            items[i] = items[i].copyWith(text: buf.toString());
            changed = true;
            continue;
          }
          final term = _terminalBuffers[key];
          if (term != null) {
            items[i] = items[i].copyWith(
              content: _withTerminalData(items[i], term.toString()),
            );
            changed = true;
          }
        }
        return changed ? turn.copyWith(items: items) : turn;
      }).toList();
      _setState(sessionId, stateFor(sessionId).copyWith(turns: turns));
    }
  }

  void _clearBuffers(String sessionId, String itemId) {
    final key = _bufKey(sessionId, itemId);
    _deltaBuffers.remove(key);
    _terminalBuffers.remove(key);
    _dirtyItems[sessionId]?.remove(itemId);
  }

  void _clearSession(String sessionId) {
    final prefix = '$sessionId/';
    _deltaBuffers.removeWhere((key, _) => key.startsWith(prefix));
    _terminalBuffers.removeWhere((key, _) => key.startsWith(prefix));
    _dirtyItems.remove(sessionId);
    final prev = stateFor(sessionId);
    _setState(
      sessionId,
      AgentSessionState(
        capabilities: prev.capabilities,
        // Tool-level, not turn-level — survives a session reset. An update's own
        // restart can trip a reset mid-flight, so its progress/result carry over
        // too (else the spinner would vanish before the result lands).
        updateAvailable: prev.updateAvailable,
        updating: prev.updating,
        updateResult: prev.updateResult,
      ),
    );
  }

  String _terminalDataOf(AgentItem item) {
    for (final block in item.content ?? const <ToolContent>[]) {
      if (block.type == 'terminal') return block.data ?? '';
    }
    return '';
  }

  List<ToolContent> _withTerminalData(AgentItem item, String data) {
    final others = (item.content ?? const <ToolContent>[])
        .where((b) => b.type != 'terminal')
        .toList();
    return [...others, ToolContent(type: 'terminal', data: data)];
  }

  void _applySnapshot(AgentSnapshot snap, [DateTime? at]) {
    for (final i in snap.items) {
      _clearBuffers(snap.sessionId, i.itemId);
    }
    final turn = _turnById(snap.sessionId, snap.turnId);
    // A snapshot re-parse carries no per-item time; preserve each item's
    // first-seen timestamp by id, falling back to this envelope's time.
    final priorTs = {
      for (final i in turn?.items ?? const <AgentItem>[]) i.itemId: i.timestamp,
    };
    final items = snap.items
        .map((i) => i.copyWith(timestamp: priorTs[i.itemId] ?? at))
        .toList();
    final updated =
        (turn ??
                AgentTurn(
                  turnId: snap.turnId,
                  items: const [],
                  startedAt: at ?? DateTime.now(),
                ))
            .copyWith(items: items);
    final s = stateFor(snap.sessionId);
    if (turn == null) {
      _setState(snap.sessionId, s.copyWith(turns: [...s.turns, updated]));
    } else {
      _setState(
        snap.sessionId,
        s.copyWith(turns: _replaceTurn(snap.sessionId, updated)),
      );
    }
  }

  void _endTurn(AgentTurnEnd end, [DateTime? at]) {
    // Closes the "attached mid-turn" gap: the snapshot that skipped the
    // in-flight turn (excluded because it wasn't completed yet) is retried
    // once that turn closes, so its content backfills without a manual
    // reopen. armRetryOnEmpty: false — this fires at most once per external
    // hydrateIfNeeded call, even if the retry itself comes back empty too.
    if (_pendingHydrationRetry.remove(end.sessionId)) {
      unawaited(_hydrate(end.sessionId, armRetryOnEmpty: false));
    }
    final turn = _turnById(end.sessionId, end.turnId);
    if (turn == null) return;
    _setState(
      end.sessionId,
      stateFor(end.sessionId).copyWith(
        turns: _replaceTurn(
          end.sessionId,
          turn.copyWith(
            stopReason: end.stopReason,
            error: end.error,
            endedAt: at ?? DateTime.now(),
          ),
        ),
      ),
    );
  }

  // ── outbound ──

  void prompt(String sessionId, String text, {String? commandId}) {
    session.send(
      createAbMessage('agent:prompt', {
        'sessionId': sessionId,
        'requestId': _requestId(),
        'text': text,
        'commandId': ?commandId,
      }),
    );
  }

  /// Ask the bridge to stop the turn this client currently renders as running.
  ///
  /// Sends the turnId so the bridge can answer even when it has no live turn:
  /// it replies with that turn's `agent:turn-end`, which is what lets the UI
  /// recover from a lost turn-end instead of showing a turn that never closes.
  void cancel(String sessionId) {
    session.send(createAbMessage('agent:cancel', {
      'sessionId': sessionId,
      'turnId': ?stateFor(sessionId).openTurn?.turnId,
    }));
  }

  /// Ask the bridge to run the agent CLI's in-app self-update. Optimistically
  /// flips [AgentSessionState.updating] so the UI shows progress immediately;
  /// the terminal state arrives as an agent:updateResult. Clears any prior
  /// result so a retry doesn't render the last failure.
  void requestUpdate(String sessionId, String tool) {
    session.send(
      createAbMessage('agent:update', {'tool': tool, 'sessionId': sessionId}),
    );
    _setState(
      sessionId,
      stateFor(sessionId).copyWith(updating: true, clearUpdateResult: true),
    );
  }

  /// Dismiss the last update result (the outcome row the user has read).
  void dismissUpdateResult(String sessionId) {
    _setState(sessionId, stateFor(sessionId).copyWith(clearUpdateResult: true));
  }

  /// Store a session-scoped selection on the bridge driver ('model' | 'effort'
  /// | 'mode'). The refreshed agent:capabilities echo is the confirmation —
  /// there is no optimistic local update.
  void setConfig(String sessionId, String key, String value) {
    session.send(
      createAbMessage('agent:set-config', {
        'sessionId': sessionId,
        'key': key,
        'value': value,
      }),
    );
  }

  void revert(
    String sessionId, {
    required String turnId,
    String? itemId,
    String? messageId,
    String? partId,
  }) {
    session.send(
      createAbMessage('agent:session-action', {
        'sessionId': sessionId,
        'action': 'revert',
        'turnId': turnId,
        'itemId': ?itemId,
        'messageId': ?messageId,
        'partId': ?partId,
      }),
    );
  }

  void resolvePermission(
    String sessionId,
    String permissionId,
    String optionId,
  ) {
    session.send(
      createAbMessage('agent:permission-resolve', {
        'sessionId': sessionId,
        'permissionId': permissionId,
        'optionId': optionId,
      }),
    );
    final s = stateFor(sessionId);
    _setState(
      sessionId,
      s.copyWith(
        pendingPermissions: s.pendingPermissions
            .where((p) => p.permissionId != permissionId)
            .toList(),
      ),
    );
  }

  /// Answer a pending question. [answer] is the chosen option id (single_select),
  /// the list of chosen option ids (multi_select), or free text (text kind) —
  /// the bridge driver translates ids back to the agent's native answer form.
  void resolveQuestion(String sessionId, String questionId, Object answer) {
    session.send(
      createAbMessage('agent:question-resolve', {
        'sessionId': sessionId,
        'questionId': questionId,
        'answer': answer,
      }),
    );
    final s = stateFor(sessionId);
    _setState(
      sessionId,
      s.copyWith(
        pendingQuestions: s.pendingQuestions
            .where((q) => q.questionId != questionId)
            .toList(),
      ),
    );
  }

  /// Fetch this session's completed-turn transcript from the bridge and apply
  /// it through the normal inbound pipe (`_onJson`), for a chat session that's
  /// already running on the bridge but has no locally cached turns — e.g. a
  /// mobile client attaching to a session desktop started earlier. Idempotent:
  /// safe to call repeatedly (a call while turns are already populated is a
  /// harmless no-op refresh).
  Future<void> hydrateIfNeeded(String sessionId) =>
      _hydrate(sessionId, armRetryOnEmpty: true);

  // Shared by the public entry point and the one-shot turn-end retry below.
  // armRetryOnEmpty is false for the retry call itself so a backend that keeps
  // coming back empty can't re-arm _pendingHydrationRetry indefinitely — each
  // EXTERNAL hydrateIfNeeded call gets at most one retry, full stop.
  Future<void> _hydrate(
    String sessionId, {
    required bool armRetryOnEmpty,
  }) async {
    if (_disposed) return;
    // Coalesce onto a fetch already in flight (a double-tapped row; the shell's
    // auto-bootstrap racing a manual activate) — one snapshot serves both
    // callers. Load-bearing beyond saving an RPC: `loading` is derived from set
    // membership, which cannot count, so without this the first call to resolve
    // would clear the flag out from under a second still on the wire and put the
    // empty state back under an active fetch.
    if (!_hydrating.add(sessionId)) return;
    // Publish the in-flight fetch before awaiting, so the view spins instead of
    // flashing "Send a message to start" over a session whose history is on the
    // wire. Cleared before the frames are dispatched below: those go through
    // _setState, which must settle `loading` false.
    _setState(sessionId, stateFor(sessionId));
    try {
      final res = await session.transport.request(
        'session.transcriptSnapshot',
        params: {'sessionId': sessionId},
      );
      _hydrating.remove(sessionId);
      _dispatchFrames((res['frames'] as List?) ?? const []);
      if (armRetryOnEmpty && stateFor(sessionId).turns.isEmpty) {
        _pendingHydrationRetry.add(sessionId);
      } else {
        _pendingHydrationRetry.remove(sessionId);
      }
      // A successful hydrate must settle `loading` even when the snapshot came
      // back empty (an idle running session with no completed turns) — otherwise
      // the transcript body stays on its loading seed until the next agent:*
      // event. Unconditional: this emit is what re-publishes state now that
      // sessionId is out of _hydrating, and it clears any stale hydrationFailed
      // in the same pass.
      final s = stateFor(sessionId);
      _setState(
        sessionId,
        s.hydrationFailed ? s.copyWith(hydrationFailed: false) : s,
      );
    } catch (_) {
      _hydrating.remove(sessionId);
      _setState(sessionId, stateFor(sessionId).copyWith(hydrationFailed: true));
    }
  }

  int _reqCounter = 0;
  String _requestId() => 'req-${_reqCounter++}';

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _heavySub?.cancel();
    await _statusSub?.cancel();
    _deltaBuffers.clear();
    _terminalBuffers.clear();
    _dirtyItems.clear();
    _hydrating.clear();
    for (final c in _controllers.values) {
      await c.close();
    }
  }
}
