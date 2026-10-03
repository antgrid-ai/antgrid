import '../../models/agent_event.dart';
import '../../services/agent_session_service.dart';

/// One renderable transcript row. [rowKey] is stable across rebuilds so list
/// children keep identity while the transcript streams.
sealed class TranscriptRow {
  const TranscriptRow();
  String get rowKey;
}

class MessageRowData extends TranscriptRow {
  final AgentItem item;
  final String turnId;
  final bool isUser;
  // Per-item time (AgentItem.timestamp): live = arrival, replayed history = the
  // real source time the bridge stamped. Null when unknown.
  final DateTime? timestamp;
  final AgentTokenUsage? usage;
  const MessageRowData(
    this.item, {
    this.turnId = '',
    required this.isUser,
    this.timestamp,
    this.usage,
  });
  @override
  String get rowKey => 'msg:${item.itemId}';
}

class ReasoningRowData extends TranscriptRow {
  final AgentItem item;
  final bool isStreaming;
  const ReasoningRowData(this.item, {required this.isStreaming});
  @override
  String get rowKey => 'reason:${item.itemId}';
}

class ToolCallRowData extends TranscriptRow {
  final AgentItem item;
  const ToolCallRowData(this.item);
  @override
  String get rowKey => 'tool:${item.itemId}';
}

class PlanRowData extends TranscriptRow {
  final AgentItem item;
  const PlanRowData(this.item);
  @override
  String get rowKey => 'plan:${item.itemId}';
}

class SubtaskRowData extends TranscriptRow {
  final AgentItem item;
  const SubtaskRowData(this.item);
  @override
  String get rowKey => 'subtask:${item.itemId}';
}

class CompactionRowData extends TranscriptRow {
  final AgentItem item;
  const CompactionRowData(this.item);
  @override
  String get rowKey => 'compact:${item.itemId}';
}

class UnknownRowData extends TranscriptRow {
  final AgentItem item;
  const UnknownRowData(this.item);
  @override
  String get rowKey => 'raw:${item.itemId}';
}

class TurnFoldRowData extends TranscriptRow {
  final String turnId;
  final int hiddenCount;
  final bool hasError;
  final bool cancelled;
  final Duration? duration;
  const TurnFoldRowData({
    required this.turnId,
    required this.hiddenCount,
    required this.hasError,
    required this.cancelled,
    this.duration,
  });
  @override
  String get rowKey => 'fold:$turnId';
}

class WorkingRowData extends TranscriptRow {
  final String turnId;
  final DateTime? startedAt;
  final bool waitingOnUser;
  const WorkingRowData({
    required this.turnId,
    this.startedAt,
    required this.waitingOnUser,
  });
  @override
  String get rowKey => 'working:$turnId';
}

class ErrorRowData extends TranscriptRow {
  final String turnId;
  final AgentError error;
  const ErrorRowData({required this.turnId, required this.error});
  @override
  String get rowKey => 'error:$turnId';
}

class PromptMarkerRowData extends TranscriptRow {
  final String id; // permissionId or questionId
  final bool isPermission;
  const PromptMarkerRowData({required this.id, required this.isPermission});
  @override
  String get rowKey => 'promptmark:$id';
}

class UsageRowData extends TranscriptRow {
  /// Fallback for settled turns without a visible assistant message.
  final String anchorKey;
  final AgentTokenUsage usage;
  const UsageRowData({required this.anchorKey, required this.usage});
  @override
  String get rowKey => 'usage:$anchorKey';
}

bool _isExpanded(AgentTurn turn, Set<String> expandedTurnIds) =>
    turn.stopReason == null || expandedTurnIds.contains(turn.turnId);

/// One turn's rows plus exactly what they were derived from, so a later derive
/// can tell whether they are still current.
class _TurnRows {
  final AgentTurn turn;
  final bool expanded;

  /// The turn's rows, including its trailing [ErrorRowData].
  final List<TranscriptRow> rows;
  final AgentTokenUsage? turnUsage;

  /// The map the anchors were read from; settled turns only, null otherwise.
  final Map<String, AgentTokenUsage>? usageByItem;
  final List<String> anchorIds;
  final List<AgentTokenUsage?> anchorUsages;

  const _TurnRows({
    required this.turn,
    required this.expanded,
    required this.rows,
    required this.turnUsage,
    required this.usageByItem,
    required this.anchorIds,
    required this.anchorUsages,
  });

  // Usage is compared per value, not by map identity: every live agent:usage
  // installs new maps, and a settled turn must not re-derive when only another
  // turn's entry changed.
  bool holdsFor(AgentTurn t, bool exp, AgentSessionState state) {
    if (!identical(turn, t) || expanded != exp) return false;
    if (t.stopReason == null) return true;
    if (!identical(state.usageByTurn[t.turnId], turnUsage)) return false;
    if (identical(state.usageByItem, usageByItem)) return true;
    for (var i = 0; i < anchorIds.length; i++) {
      if (!identical(state.usageByItem[anchorIds[i]], anchorUsages[i])) {
        return false;
      }
    }
    return true;
  }
}

/// State → rows. Pure: all folding/marker/working policy lives here so it is
/// testable without widgets. Ephemeral expansion state is passed in, never
/// stored in the service.
List<TranscriptRow> deriveRows(
  AgentSessionState state, {
  required Set<String> expandedTurnIds,
}) {
  final rows = <TranscriptRow>[];
  for (final turn in state.turns) {
    rows.addAll(
      _deriveTurn(
        turn,
        state,
        expanded: _isExpanded(turn, expandedTurnIds),
      ).rows,
    );
  }
  _addPromptAndWorkingRows(rows, state);
  return rows;
}

/// [deriveRows] with per-turn reuse. A view re-derives on every state change;
/// a turn whose object, fold state and attached usage are unchanged keeps the
/// rows it was last given, so a streamed delta costs its own turn's rows plus
/// one reference pass over the rest.
///
/// Sound only because AgentSessionService never mutates a turn, item list or
/// usage map it has already published.
class TranscriptRowCache {
  Map<String, _TurnRows> _byTurnId = {};

  List<TranscriptRow> derive(
    AgentSessionState state, {
    required Set<String> expandedTurnIds,
  }) {
    final rows = <TranscriptRow>[];
    final next = <String, _TurnRows>{};
    for (final turn in state.turns) {
      final expanded = _isExpanded(turn, expandedTurnIds);
      final prior = _byTurnId[turn.turnId];
      final entry = prior != null && prior.holdsFor(turn, expanded, state)
          ? prior
          : _deriveTurn(turn, state, expanded: expanded);
      next[turn.turnId] = entry;
      rows.addAll(entry.rows);
    }
    _byTurnId = next;
    _addPromptAndWorkingRows(rows, state);
    return rows;
  }
}

_TurnRows _deriveTurn(
  AgentTurn turn,
  AgentSessionState state, {
  required bool expanded,
}) {
  final settled = turn.stopReason != null;
  final turnRows = <TranscriptRow>[];

  if (expanded) {
    for (final item in turn.items) {
      if (!settled && item.kind == 'compaction') continue;
      final streamingTail =
          !settled && turn.items.isNotEmpty && identical(item, turn.items.last);
      turnRows.add(_rowFor(item, turnId: turn.turnId, streaming: streamingTail));
    }
  } else {
    // Fold: keep the conversation (user prompt, trailing assistant answer)
    // and compaction dividers; hide the work behind one fold header placed
    // where the hidden run starts.
    final kept = <String>{};
    for (final item in turn.items) {
      if (item.kind == 'compaction' ||
          (item.kind == 'message' && item.role == 'user')) {
        kept.add(item.itemId);
      }
    }
    for (var i = turn.items.length - 1; i >= 0; i--) {
      final item = turn.items[i];
      if (item.kind == 'message' && item.role != 'user') {
        kept.add(item.itemId);
      } else {
        break;
      }
    }
    final hiddenCount = turn.items.where((i) => !kept.contains(i.itemId)).length;
    var foldEmitted = false;
    for (final item in turn.items) {
      if (kept.contains(item.itemId)) {
        turnRows.add(_rowFor(item, turnId: turn.turnId, streaming: false));
      } else if (!foldEmitted) {
        turnRows.add(
          TurnFoldRowData(
            turnId: turn.turnId,
            hiddenCount: hiddenCount,
            hasError: turn.items.any((i) => i.error != null),
            cancelled: turn.stopReason == 'cancelled',
            duration: _turnDuration(turn),
          ),
        );
        foldEmitted = true;
      }
    }
  }

  // One timestamp per assistant run, not one per message: blank every
  // assistant message footer except the last, which anchors the turn's time
  // in the feed. User prompts keep their own send time — it marks when the
  // user asked, a different moment from when the turn answered.
  final lastMessageIndex = turnRows.lastIndexWhere((r) => r is MessageRowData);
  for (var i = 0; i < turnRows.length; i++) {
    final row = turnRows[i];
    if (row is MessageRowData && !row.isUser && i != lastMessageIndex) {
      turnRows[i] = MessageRowData(
        row.item,
        turnId: row.turnId,
        isUser: row.isUser,
      );
    }
  }

  // A streaming turn's usage is provisional. Once settled, historical usage
  // attaches to each visible assistant anchor. Live usage falls back to the
  // last visible assistant when history did not provide finer detail. Keeping
  // it on MessageRowData lets the timestamp and usage share one metadata row.
  final anchorIds = <String>[];
  final anchorUsages = <AgentTokenUsage?>[];
  AgentTokenUsage? turnUsage;
  if (settled) {
    var hasItemUsage = false;
    for (var i = 0; i < turnRows.length; i++) {
      final row = turnRows[i];
      if (row is MessageRowData && !row.isUser) {
        final itemUsage = state.usageByItem[row.item.itemId];
        anchorIds.add(row.item.itemId);
        anchorUsages.add(itemUsage);
        if (itemUsage != null) {
          hasItemUsage = true;
          turnRows[i] = MessageRowData(
            row.item,
            turnId: row.turnId,
            isUser: false,
            timestamp: row.timestamp,
            usage: itemUsage,
          );
        }
      }
    }
    turnUsage = state.usageByTurn[turn.turnId];
    if (turnUsage != null && !hasItemUsage) {
      final lastAssistantIndex = turnRows.lastIndexWhere(
        (row) => row is MessageRowData && !row.isUser,
      );
      if (lastAssistantIndex >= 0) {
        final row = turnRows[lastAssistantIndex] as MessageRowData;
        turnRows[lastAssistantIndex] = MessageRowData(
          row.item,
          turnId: row.turnId,
          isUser: false,
          timestamp: row.timestamp,
          usage: turnUsage,
        );
      } else {
        turnRows.add(UsageRowData(anchorKey: turn.turnId, usage: turnUsage));
      }
    }
  }

  if (turn.error != null) {
    turnRows.add(ErrorRowData(turnId: turn.turnId, error: turn.error!));
  }

  return _TurnRows(
    turn: turn,
    expanded: expanded,
    rows: turnRows,
    turnUsage: turnUsage,
    usageByItem: settled ? state.usageByItem : null,
    anchorIds: anchorIds,
    anchorUsages: anchorUsages,
  );
}

void _addPromptAndWorkingRows(
  List<TranscriptRow> rows,
  AgentSessionState state,
) {
  // Pending prompts render fully in the pinned panel; the transcript keeps
  // only a chronological marker stub.
  final waiting =
      state.pendingPermissions.isNotEmpty || state.pendingQuestions.isNotEmpty;
  for (final p in state.pendingPermissions) {
    rows.add(PromptMarkerRowData(id: p.permissionId, isPermission: true));
  }
  for (final q in state.pendingQuestions) {
    rows.add(PromptMarkerRowData(id: q.questionId, isPermission: false));
  }

  final open = state.openTurn;
  if (open != null) {
    rows.add(
      WorkingRowData(
        turnId: open.turnId,
        startedAt: open.startedAt,
        waitingOnUser: waiting,
      ),
    );
  }
}

TranscriptRow _rowFor(
  AgentItem item, {
  required String turnId,
  required bool streaming,
}) {
  switch (item.kind) {
    case 'message':
      return MessageRowData(
        item,
        turnId: turnId,
        isUser: item.role == 'user',
        timestamp: item.timestamp,
      );
    case 'reasoning':
      return ReasoningRowData(item, isStreaming: streaming);
    case 'tool_call':
      return ToolCallRowData(item);
    case 'plan':
      return PlanRowData(item);
    case 'subtask':
      return SubtaskRowData(item);
    case 'compaction':
      return CompactionRowData(item);
    default:
      return UnknownRowData(item);
  }
}

Duration? _turnDuration(AgentTurn turn) {
  final s = turn.startedAt;
  final e = turn.endedAt;
  if (s == null || e == null) return null;
  return e.difference(s);
}
