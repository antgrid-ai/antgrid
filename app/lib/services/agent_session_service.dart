import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

  /// Live background tasks (latest-wins full list from agent:background-tasks),
  /// or null before the first frame. An empty-list frame means "none running".
  final AgentBackgroundTasks? backgroundTasks;

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
    this.backgroundTasks,
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
    AgentBackgroundTasks? backgroundTasks,
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
    backgroundTasks: backgroundTasks ?? this.backgroundTasks,
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

/// How long live text and terminal deltas accumulate before one state is
/// published: about a frame, so a token stream costs consumers one rebuild per
/// frame instead of one per token.
const Duration kAgentDeltaFlushInterval = Duration(milliseconds: 16);

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

  // Item ids touched by deltas since the last flush, per session. A streamed
  // delta reaches _onJson through async stream controllers, one event per
  // microtask, so only a timer can merge a live stream into one publish per
  // frame. It is a Timer rather than a frame callback because frames stop while
  // the window is hidden, which would leave buffered text unpublished. Every
  // other inbound frame flushes first (see _onJson), so no event reads or
  // replaces turns while text is still buffered.
  Map<String, Set<String>> _dirtyItems = {};
  Timer? _flushTimer;

  // A batch replay runs every frame through _onJson so each keeps its side
  // effects: retry consumption in _endTurn, cancel fallbacks, prompts, usage,
  // capabilities and update state. Only the state the batch ends on is worth
  // publishing, and until it ends nothing outside can see the lists it builds,
  // so they are written in place. Ownership is re-proven by identity on every
  // use, so a frame that installs a list of its own costs one fresh copy and is
  // never written through.
  final Map<String, _Fold> _folds = {};

  int _collectionCopies = 0;

  // Counted in debug builds only; the counter exists for tests.
  List<T> _copyList<T>(Iterable<T> source) {
    assert(() {
      _collectionCopies++;
      return true;
    }());
    return List<T>.of(source);
  }

  Map<String, AgentTokenUsage> _copyUsage(Map<String, AgentTokenUsage> source) {
    assert(() {
      _collectionCopies++;
      return true;
    }());
    return {...source};
  }

  /// How many fresh copies of an existing turn list, a turn's item list or a
  /// usageByItem map have been made, so tests can pin how much one frame or one
  /// batch rewrites.
  @visibleForTesting
  int get debugCollectionCopies => _collectionCopies;

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

  // sessionIds whose hydration is registered but whose pull hasn't fired yet
  // because the relay stream isn't established (firing now would seal-and-vanish
  // and burn the RPC timeout). Purely a `loading` signal so the view spins
  // rather than flashing the empty state: the actual deferral + re-drive is
  // owned by the transport's hydrator registry (see [hydrateIfNeeded]), which
  // fires the pull on establishment via refreshSnapshot — the same wave the
  // durable snapshot rides. Cleared when [_hydrate] runs.
  final Set<String> _awaitingHydrate = {};

  // sessionIds registered as transcript hydrators, so [dispose] can deregister
  // them from the transport.
  final Set<String> _hydratedSessions = {};

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
    s = s.copyWith(
      loading:
          _hydrating.contains(sessionId) ||
          _awaitingHydrate.contains(sessionId),
    );
    _states[sessionId] = s;
    final fold = _folds[sessionId];
    if (fold != null) {
      fold.dirty = true;
      return;
    }
    _controllers[sessionId]?.add(s);
  }

  void _folded(String sessionId, void Function() body) {
    if (_folds.containsKey(sessionId)) {
      body();
      return;
    }
    _flushDeltas();
    final fold = _folds[sessionId] = _Fold();
    try {
      body();
    } finally {
      // Folded into the batch's single publish, so a replay never shows one
      // frame of its final state without the text buffered inside it.
      _flushDeltas();
      _folds.remove(sessionId);
      if (fold.dirty && !_disposed) {
        _controllers[sessionId]?.add(_states[sessionId]!);
      }
    }
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

  /// Install a whole-transcript batch — the pushed `agent:transcript-replay`
  /// and the pulled `session.transcriptSnapshot` alike — as the session's
  /// history.
  ///
  /// Both carry the WHOLE settled transcript, so they replace what we hold
  /// rather than appending to it. Id dedup cannot do that job across drivers:
  /// claude's disk replay numbers its turns `resumed:N` while the same turns
  /// went out live as `turn-N`, so appending renders the entire conversation a
  /// second time — which is exactly what the post-turn retry in [_endTurn]
  /// triggers.
  ///
  /// Two things survive the replace. An EMPTY batch replaces nothing: a driver
  /// that could not read its store reports one, and it must not wipe a
  /// transcript we watched arrive live. And the open turn is re-appended,
  /// because neither batch carries it — it has not ended, which is the very
  /// reason that retry exists.
  ///
  /// Unless [liveTurnId] says it HAS ended. A client that missed the turn-end
  /// (backgrounded, reconnected) still holds that turn open with the text it
  /// last saw, while the batch carries the finished turn under a renumbered id —
  /// re-appending would pin the stale half-turn under the real one, spinning
  /// forever. The pulled snapshot names the bridge's live turn (null when
  /// idle); the pushed replay names none ([reportsLiveTurn] false), so there
  /// the open turn is kept. An empty batch still closes an ended turn: there
  /// is nothing to replace its text with, but it must stop spinning.
  ///
  /// A batch read mid-turn may carry the live turn itself, under its live id
  /// (see claude's adoptLiveTurn). Then the two are merged rather than one
  /// kept: what we held carries live-only detail (reasoning, tool output), the
  /// batch carries what streamed while we were away.
  void _applyFullTranscript(
    String sessionId,
    List<Object?> frames, {
    bool reportsLiveTurn = false,
    String? liveTurnId,
  }) {
    final held = stateFor(sessionId).openTurn;
    final ended = reportsLiveTurn && held != null && held.turnId != liveTurnId;
    if (frames.isEmpty) {
      if (held != null && ended) {
        _setState(
          sessionId,
          stateFor(sessionId).copyWith(
            turns: _replaceTurn(
              sessionId,
              held.copyWith(stopReason: 'end_turn', endedAt: DateTime.now()),
            ),
          ),
        );
      }
      return;
    }
    final open = ended ? null : held;
    _setState(sessionId, stateFor(sessionId).copyWith(turns: const []));
    _dispatchFrames(frames);
    if (open == null) return;
    final s = stateFor(sessionId);
    final carried = _turnById(sessionId, open.turnId);
    if (carried == null) {
      _setState(sessionId, s.copyWith(turns: _appendTurn(sessionId, open)));
      return;
    }
    final heldIds = {for (final i in open.items) i.itemId};
    final merged = carried.copyWith(
      items: [
        ...open.items,
        ...carried.items.where((i) => !heldIds.contains(i.itemId)),
      ],
    );
    _setState(sessionId, s.copyWith(turns: _replaceTurn(sessionId, merged)));
  }

  /// Install the snapshot's `live` frames: the session's open prompts and its
  /// latest usage. The prompt set is the bridge's whole set, so it REPLACES
  /// ours — a card missing from it was answered or withdrawn while we were
  /// away, and those withdrawals were live frames we never received.
  ///
  /// A prompt answered here can come back if the bridge read the set before
  /// the answer reached it; the retraction the answer produces follows this
  /// response on the same stream and takes it down again.
  void _applyLive(String sessionId, List<Object?> live) {
    _setState(
      sessionId,
      stateFor(
        sessionId,
      ).copyWith(pendingPermissions: const [], pendingQuestions: const []),
    );
    _dispatchFrames(live);
  }

  /// Settle an update spinner whose result landed while we were away. Acts
  /// only while we show one, so a result the user already dismissed is not
  /// raised again on every reconnect.
  void _applyUpdateState(String sessionId, Map update) {
    if (!stateFor(sessionId).updating || update['running'] == true) return;
    final result = update['result'];
    if (result is Map) {
      _onJson({...result.cast<String, dynamic>(), 'sessionId': sessionId});
    } else {
      _setState(sessionId, stateFor(sessionId).copyWith(updating: false));
    }
  }

  // agent:error is absent because no arm reads it.
  static const Set<String> _handledTypes = {
    'agent:transcript-replay',
    'agent:turn-start',
    'agent:session-reset',
    'agent:item-added',
    'agent:item-delta',
    'agent:item-updated',
    'agent:turn-end',
    'agent:permission-request',
    'agent:question',
    'agent:request-retracted',
    'agent:snapshot',
    'agent:usage',
    'agent:capabilities',
    'agent:background-tasks',
    'agent:updateAvailable',
    'agent:updateResult',
  };

  void _onJson(Map<String, dynamic> json) {
    if (_disposed) return;
    final parsed = parseAbMessageOfType(json, _handledTypes);
    if (parsed == null) return;
    // Inside a batch replay the buffered text is published with the batch's
    // final state, so flushing per frame would copy the turn list repeatedly.
    if (parsed is! AgentItemDelta && _folds.isEmpty) _flushDeltas();
    if (parsed is AgentTranscriptReplay) {
      _folded(
        parsed.sessionId,
        () => _applyFullTranscript(parsed.sessionId, parsed.frames),
      );
      return;
    }
    final at = _envTime(json);
    if (parsed is AgentTurnStart) {
      final sid = parsed.sessionId;
      if (_turnById(sid, parsed.turnId) == null) {
        _setState(
          sid,
          stateFor(sid).copyWith(
            turns: _appendTurn(
              sid,
              AgentTurn(
                turnId: parsed.turnId,
                items: const [],
                startedAt: at ?? DateTime.now(),
              ),
            ),
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
          s.copyWith(
            usageByItem: _usageByItemWith(
              parsed.sessionId,
              itemId,
              perMessage,
            ),
          ),
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
    } else if (parsed is AgentBackgroundTasks) {
      _setState(
        parsed.sessionId,
        stateFor(parsed.sessionId).copyWith(backgroundTasks: parsed),
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

  // Searches from the end because the turn a live frame names is almost always
  // the last one; turn ids are unique per session because every append checks
  // for the id first, so the direction never changes which turn is found.
  AgentTurn? _turnById(String sessionId, String turnId) {
    final turns = stateFor(sessionId).turns;
    final fold = _folds[sessionId];
    if (fold != null && identical(fold.turns, turns)) {
      final i = fold.turnAt[turnId];
      return i == null ? null : turns[i];
    }
    final i = turns.lastIndexWhere((t) => t.turnId == turnId);
    return i < 0 ? null : turns[i];
  }

  List<AgentTurn>? _ownTurns(String sessionId) {
    final fold = _folds[sessionId];
    if (fold == null) return null;
    final current = stateFor(sessionId).turns;
    if (identical(fold.turns, current)) return fold.turns;
    final owned = _copyList(current);
    fold.turnAt.clear();
    for (var i = 0; i < owned.length; i++) {
      fold.turnAt.putIfAbsent(owned[i].turnId, () => i);
    }
    fold.turns = owned;
    return owned;
  }

  List<AgentTurn> _replaceTurn(String sessionId, AgentTurn updated) {
    final owned = _ownTurns(sessionId);
    if (owned != null) {
      final i = _folds[sessionId]!.turnAt[updated.turnId];
      if (i != null) owned[i] = updated;
      return owned;
    }
    final next = _copyList(stateFor(sessionId).turns);
    final i = next.lastIndexWhere((t) => t.turnId == updated.turnId);
    if (i >= 0) next[i] = updated;
    return next;
  }

  // The result must go straight into `_setState(...copyWith(turns: result))`:
  // that install keeps the fold's list identical to the current state's, so the
  // next frame writes in place instead of copying again.
  List<AgentTurn> _appendTurn(String sessionId, AgentTurn turn) {
    final owned = _ownTurns(sessionId);
    if (owned == null) {
      return _copyList(stateFor(sessionId).turns)..add(turn);
    }
    _folds[sessionId]!.turnAt.putIfAbsent(turn.turnId, () => owned.length);
    owned.add(turn);
    return owned;
  }

  _OwnedItems? _ownItems(String sessionId, AgentTurn turn) {
    final fold = _folds[sessionId];
    if (fold == null) return null;
    final held = fold.items[turn.turnId];
    if (held != null && identical(held.list, turn.items)) return held;
    final list = _copyList(turn.items);
    final at = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      at.putIfAbsent(list[i].itemId, () => i);
    }
    return fold.items[turn.turnId] = _OwnedItems(list, at);
  }

  Map<String, AgentTokenUsage> _usageByItemWith(
    String sessionId,
    String itemId,
    AgentTokenUsage usage,
  ) {
    final current = stateFor(sessionId).usageByItem;
    final fold = _folds[sessionId];
    if (fold == null) {
      return _copyUsage(current)..[itemId] = usage;
    }
    if (!identical(fold.usageByItem, current)) {
      fold.usageByItem = _copyUsage(current);
    }
    fold.usageByItem![itemId] = usage;
    return fold.usageByItem!;
  }

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
      _setState(
        sessionId,
        stateFor(sessionId).copyWith(turns: _appendTurn(sessionId, turn)),
      );
    }
    final owned = _ownItems(sessionId, turn);
    final List<AgentItem> items;
    final int idx;
    if (owned != null) {
      items = owned.list;
      idx = owned.at[item.itemId] ?? -1;
    } else {
      items = _copyList(turn.items);
      idx = items.indexWhere((i) => i.itemId == item.itemId);
    }
    if (idx >= 0) {
      // Keep the first-seen time; a snapshot/update re-parse carries no time.
      items[idx] = item.copyWith(timestamp: items[idx].timestamp ?? at);
    } else {
      owned?.at[item.itemId] = items.length;
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

  // Not restarted by later deltas: a steady stream must still publish once per
  // interval rather than starve until it pauses.
  void _scheduleFlush() {
    if (_disposed) return;
    _flushTimer ??= Timer(kAgentDeltaFlushInterval, _flushDeltas);
  }

  void _flushDeltas() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed || _dirtyItems.isEmpty) return;
    final dirtyBySession = _dirtyItems;
    _dirtyItems = {};
    for (final entry in dirtyBySession.entries) {
      final sessionId = entry.key;
      final dirty = entry.value;
      if (dirty.isEmpty) continue;
      final turns = _copyList(
        stateFor(sessionId).turns.map(
          (turn) => _withBuffered(sessionId, turn, dirty),
        ),
      );
      _setState(sessionId, stateFor(sessionId).copyWith(turns: turns));
    }
  }

  // Visits every turn on purpose: a buffered id must land wherever it sits when
  // the flush runs, not only in the turn its delta named. That covers a turn a
  // snapshot moved it to, and every turn holding the same id.
  AgentTurn _withBuffered(String sessionId, AgentTurn turn, Set<String> dirty) {
    List<AgentItem>? items;
    for (var i = 0; i < turn.items.length; i++) {
      final item = turn.items[i];
      if (!dirty.contains(item.itemId)) continue;
      final key = _bufKey(sessionId, item.itemId);
      final buf = _deltaBuffers[key];
      final term = buf == null ? _terminalBuffers[key] : null;
      if (buf == null && term == null) continue;
      items ??= _copyList(turn.items);
      items[i] = buf != null
          ? item.copyWith(text: buf.toString())
          : item.copyWith(content: _withTerminalData(item, term!.toString()));
    }
    return items == null ? turn : turn.copyWith(items: items);
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
        // A codex rollback/session reset does not kill the actual background OS
        // processes, so the task list carries over.
        backgroundTasks: prev.backgroundTasks,
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
      _setState(
        snap.sessionId,
        s.copyWith(turns: _appendTurn(snap.sessionId, updated)),
      );
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
    _cancelFallbacks.remove(end.sessionId)?.cancel();
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

  // Bounds how long the working indicator can keep pulsing after cancel() —
  // if agent:turn-end never lands (dropped frame, dead socket, reconnect
  // race), the turn is force-closed locally instead of blinking forever.
  static const _cancelFallbackDelay = Duration(seconds: 5);
  final Map<String, Timer> _cancelFallbacks = {};

  /// Ask the bridge to stop the turn this client currently renders as running.
  ///
  /// Sends the turnId so the bridge can answer even when it has no live turn:
  /// it replies with that turn's `agent:turn-end`, which is what lets the UI
  /// recover from a lost turn-end instead of showing a turn that never closes.
  /// A local fallback timer closes the turn anyway if that reply never
  /// arrives, so the working indicator can't outlive the user's cancel.
  void cancel(String sessionId) {
    final turnId = stateFor(sessionId).openTurn?.turnId;
    session.send(
      createAbMessage('agent:cancel', {
        'sessionId': sessionId,
        'turnId': ?turnId,
      }),
    );
    if (turnId == null) return;
    _cancelFallbacks.remove(sessionId)?.cancel();
    _cancelFallbacks[sessionId] = Timer(_cancelFallbackDelay, () {
      _cancelFallbacks.remove(sessionId);
      if (_disposed) return;
      _flushDeltas();
      final turn = _turnById(sessionId, turnId);
      if (turn == null || turn.stopReason != null) return;
      _setState(
        sessionId,
        stateFor(sessionId).copyWith(
          turns: _replaceTurn(
            sessionId,
            turn.copyWith(stopReason: 'cancelled', endedAt: DateTime.now()),
          ),
        ),
      );
    });
  }

  /// Stop one background task. The bridge routes this to the driver's native
  /// kill (claude Query.stopTask / codex backgroundTerminals/terminate); the
  /// refreshed agent:background-tasks frame is the confirmation — no
  /// optimistic local removal.
  void stopTask(String sessionId, String taskId) {
    session.send(
      createAbMessage('agent:task-stop', {
        'sessionId': sessionId,
        'taskId': taskId,
      }),
    );
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
  ///
  /// Deferral is the load-bearing part: on a relay session whose project
  /// stream hasn't established yet, the transcript RPC would be silently dropped and
  /// burn its full timeout, leaving the transcript blank until an unrelated
  /// re-attach happened to fire it post-establishment (the "old messages don't
  /// come until I background+reopen" bug). The transport's tier-3 hydrator
  /// registry owns that deferral: [session.hydrate] fires the pull now if the
  /// stream is established, else registers it to fire on establishment (and
  /// re-fire on every reconnect, so the transcript rides the establishment wave
  /// the durable snapshot does). We only mark `_awaitingHydrate` so the view
  /// spins while a registered-but-unfired pull waits.
  Future<void> hydrateIfNeeded(String sessionId) async {
    _hydratedSessions.add(sessionId);
    // Spin until the pull fires: covers the pre-establish window even when a
    // state entry already exists with loading:false (e.g. capabilities landed
    // first). Skip when turns are already present — nothing to load.
    if (stateFor(sessionId).turns.isEmpty && _awaitingHydrate.add(sessionId)) {
      _setState(sessionId, stateFor(sessionId));
    }
    await session.hydrate(
      'transcript:$sessionId',
      () => _hydrate(sessionId, armRetryOnEmpty: true),
    );
  }

  /// Deregister the transcript hydrator for a session whose view is going away.
  /// Symmetric with [hydrateIfNeeded], and the reason its registration is not a
  /// leak: without this every session ever viewed would keep its hydrator for
  /// the service's whole life, so each reconnect would re-pull a
  /// transcriptSnapshot for ALL of them — not just the one(s) on screen. The
  /// config/sessions/file:selected hydrators are singletons; the transcript one
  /// is per-session, so it must be scoped to the live view.
  void stopHydrating(String sessionId) {
    if (!_hydratedSessions.remove(sessionId)) return;
    session.unhydrate('transcript:$sessionId');
    _awaitingHydrate.remove(sessionId);
    _pendingHydrationRetry.remove(sessionId);
  }

  // Shared by the public entry point and the one-shot turn-end retry below.
  // armRetryOnEmpty is false for the retry call itself so a backend that keeps
  // coming back empty can't re-arm _pendingHydrationRetry indefinitely — each
  // EXTERNAL hydrateIfNeeded call gets at most one retry, full stop.
  Future<void> _hydrate(
    String sessionId, {
    required bool armRetryOnEmpty,
  }) async {
    if (_disposed) return;
    // The pull is firing now — drop the pre-establish spinner marker; `loading`
    // is carried by _hydrating membership from here.
    _awaitingHydrate.remove(sessionId);
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
      _folded(sessionId, () {
        _hydrating.remove(sessionId);
        _applyFullTranscript(
          sessionId,
          (res['frames'] as List?) ?? const [],
          reportsLiveTurn: res.containsKey('activeTurnId'),
          liveTurnId: res['activeTurnId'] as String?,
        );
        final live = res['live'];
        if (live is List) _applyLive(sessionId, live);
        final update = res['update'];
        if (update is Map) _applyUpdateState(sessionId, update);
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
      });
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
    _flushTimer?.cancel();
    _flushTimer = null;
    for (final t in _cancelFallbacks.values) {
      t.cancel();
    }
    _cancelFallbacks.clear();
    for (final id in _hydratedSessions) {
      session.unhydrate('transcript:$id');
    }
    _hydratedSessions.clear();
    await _heavySub?.cancel();
    await _statusSub?.cancel();
    _deltaBuffers.clear();
    _terminalBuffers.clear();
    _dirtyItems.clear();
    _hydrating.clear();
    _awaitingHydrate.clear();
    for (final c in _controllers.values) {
      await c.close();
    }
  }
}

class _Fold {
  bool dirty = false;
  List<AgentTurn>? turns;
  final Map<String, int> turnAt = {};
  final Map<String, _OwnedItems> items = {};
  Map<String, AgentTokenUsage>? usageByItem;
}

class _OwnedItems {
  _OwnedItems(this.list, this.at);

  final List<AgentItem> list;

  /// Item id to its FIRST index, matching what indexWhere finds.
  final Map<String, int> at;
}
