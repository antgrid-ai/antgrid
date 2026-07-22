/// Dart mirrors of the normalized agent:* event model (see bridge/src/protocol.ts
/// and docs/superpowers/specs/2026-06-16-normalized-agent-event-model-design.md).
library;

class AgentError {
  final String category;
  final String message;
  final bool retryable;
  final int? retryAfterMs;
  final int? httpStatus;
  final String? provider;

  const AgentError({
    required this.category,
    required this.message,
    required this.retryable,
    this.retryAfterMs,
    this.httpStatus,
    this.provider,
  });

  static AgentError? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    return AgentError(
      category: json['category'] as String? ?? 'unknown',
      message: json['message'] as String? ?? '',
      retryable: json['retryable'] as bool? ?? false,
      retryAfterMs: json['retryAfterMs'] as int?,
      httpStatus: json['httpStatus'] as int?,
      provider: json['provider'] as String?,
    );
  }
}

/// One codex token-usage breakdown (mirrors the bridge AgentUsage schema).
class AgentTokenUsage {
  final int? totalTokens;
  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? reasoningTokens;

  const AgentTokenUsage({
    this.totalTokens,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.reasoningTokens,
  });

  static AgentTokenUsage fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const AgentTokenUsage();
    int? n(String k) => (json[k] as num?)?.toInt();
    return AgentTokenUsage(
      totalTokens: n('totalTokens'),
      inputTokens: n('inputTokens'),
      outputTokens: n('outputTokens'),
      cacheReadTokens: n('cacheReadTokens'),
      reasoningTokens: n('reasoningTokens'),
    );
  }
}

/// Session-cumulative token usage. `total` is the running total; `last` is the
/// most recent turn; `contextWindow` is the model's window when known.
class AgentUsage {
  final AgentTokenUsage total;
  final AgentTokenUsage? last;
  final int? contextWindow;

  const AgentUsage({required this.total, this.last, this.contextWindow});
}

class ToolContent {
  final String type; // text | diff | terminal
  final String? text;
  final String? path;
  final String? oldText;
  final String? newText;
  final String? data;

  const ToolContent({
    required this.type,
    this.text,
    this.path,
    this.oldText,
    this.newText,
    this.data,
  });

  static ToolContent fromJson(Map<String, dynamic> j) => ToolContent(
    type: j['type'] as String? ?? 'text',
    text: j['text'] as String?,
    path: j['path'] as String?,
    oldText: j['oldText'] as String?,
    newText: j['newText'] as String?,
    data: j['data'] as String?,
  );
}

class PlanEntry {
  final String text;
  final String status;
  const PlanEntry({required this.text, required this.status});
}

class AgentItem {
  final String itemId;
  final String? parentItemId;
  final String
  kind; // message | reasoning | tool_call | plan | subtask | compaction
  final String? role;
  final String? text;
  final String? status;
  final String? toolKind;
  final String? title;
  final List<ToolContent>? content;
  final AgentError? error;
  final List<PlanEntry>? entries;
  final String? agent;
  final String? summary;
  final String? revertMessageId;
  final String? revertPartId;
  // Bridge-synthesized tool I/O (codex: command/cwd, MCP args/result). Opaque
  // JSON — the wire schema declares these as unknown.
  final Object? rawInput;
  final Object? rawOutput;
  // When this item's content was created, from the item-added envelope. Set by
  // the reducer (not the item wire schema): live = arrival time; replayed
  // history = the real source time the bridge stamped (see codex/opencode
  // resume-replay). Null when the source had no time. Drives the message
  // timestamp footer.
  final DateTime? timestamp;

  const AgentItem({
    required this.itemId,
    required this.kind,
    this.parentItemId,
    this.role,
    this.text,
    this.status,
    this.toolKind,
    this.title,
    this.content,
    this.error,
    this.entries,
    this.agent,
    this.summary,
    this.revertMessageId,
    this.revertPartId,
    this.rawInput,
    this.rawOutput,
    this.timestamp,
  });

  AgentItem copyWith({
    String? itemId,
    String? parentItemId,
    String? kind,
    String? role,
    String? text,
    String? status,
    String? toolKind,
    String? title,
    List<ToolContent>? content,
    AgentError? error,
    List<PlanEntry>? entries,
    String? agent,
    String? summary,
    String? revertMessageId,
    String? revertPartId,
    Object? rawInput,
    Object? rawOutput,
    DateTime? timestamp,
  }) => AgentItem(
    itemId: itemId ?? this.itemId,
    kind: kind ?? this.kind,
    parentItemId: parentItemId ?? this.parentItemId,
    role: role ?? this.role,
    text: text ?? this.text,
    status: status ?? this.status,
    toolKind: toolKind ?? this.toolKind,
    title: title ?? this.title,
    content: content ?? this.content,
    error: error ?? this.error,
    entries: entries ?? this.entries,
    agent: agent ?? this.agent,
    summary: summary ?? this.summary,
    revertMessageId: revertMessageId ?? this.revertMessageId,
    revertPartId: revertPartId ?? this.revertPartId,
    rawInput: rawInput ?? this.rawInput,
    rawOutput: rawOutput ?? this.rawOutput,
    // Preserved through delta/update copyWith so a streaming live message keeps
    // its first-seen time instead of losing the footer mid-stream.
    timestamp: timestamp ?? this.timestamp,
  );

  static AgentItem fromJson(Map<String, dynamic> j) {
    final contentJson = j['content'];
    final entriesJson = j['entries'];
    final revertTarget = j['revertTarget'];
    return AgentItem(
      itemId: j['itemId'] as String? ?? '',
      parentItemId: j['parentItemId'] as String?,
      kind: j['kind'] as String? ?? 'message',
      role: j['role'] as String?,
      text: j['text'] as String?,
      status: j['status'] as String?,
      toolKind: j['toolKind'] as String?,
      title: j['title'] as String?,
      content: contentJson is List
          ? contentJson
                .whereType<Map<String, dynamic>>()
                .map(ToolContent.fromJson)
                .toList()
          : null,
      error: AgentError.fromJson(j['error']),
      entries: entriesJson is List
          ? entriesJson
                .whereType<Map<String, dynamic>>()
                .map(
                  (e) => PlanEntry(
                    text: e['text'] as String? ?? '',
                    status: e['status'] as String? ?? 'pending',
                  ),
                )
                .toList()
          : null,
      agent: j['agent'] as String?,
      summary: j['summary'] as String?,
      revertMessageId: revertTarget is Map<String, dynamic>
          ? revertTarget['messageId'] as String?
          : null,
      revertPartId: revertTarget is Map<String, dynamic>
          ? revertTarget['partId'] as String?
          : null,
      rawInput: j['rawInput'],
      rawOutput: j['rawOutput'],
    );
  }
}

class PermissionOption {
  final String optionId;
  final String label;
  final String kind;
  const PermissionOption({
    required this.optionId,
    required this.label,
    required this.kind,
  });
}

// ── Message classes ──

class AgentTurnStart {
  final String sessionId;
  final String turnId;
  const AgentTurnStart({required this.sessionId, required this.turnId});
}

class AgentSessionReset {
  final String sessionId;
  const AgentSessionReset({required this.sessionId});
}

class AgentTurnEnd {
  final String sessionId;
  final String turnId;
  final String stopReason;
  final AgentError? error;
  const AgentTurnEnd({
    required this.sessionId,
    required this.turnId,
    required this.stopReason,
    this.error,
  });
}

class AgentItemAdded {
  final String sessionId;
  final String turnId;
  final AgentItem item;
  const AgentItemAdded({
    required this.sessionId,
    required this.turnId,
    required this.item,
  });
}

/// A resumed transcript delivered whole, as one frame. [frames] are raw
/// AbMessage maps to be re-dispatched individually — the bridge batches them
/// because the relay drops (and never resends) frames past its rate limit,
/// which would otherwise truncate a replayed transcript mid-turn.
class AgentTranscriptReplay {
  final String sessionId;
  final List<Map<String, dynamic>> frames;
  const AgentTranscriptReplay({required this.sessionId, required this.frames});
}

class AgentItemDelta {
  final String sessionId;
  final String turnId;
  final String itemId;
  final String textChunk;
  const AgentItemDelta({
    required this.sessionId,
    required this.turnId,
    required this.itemId,
    required this.textChunk,
  });
}

class AgentItemUpdated {
  final String sessionId;
  final String turnId;
  final AgentItem item;
  const AgentItemUpdated({
    required this.sessionId,
    required this.turnId,
    required this.item,
  });
}

class AgentSnapshot {
  final String sessionId;
  final String turnId;
  final List<AgentItem> items;
  const AgentSnapshot({
    required this.sessionId,
    required this.turnId,
    required this.items,
  });
}

class AgentPermissionRequest {
  final String sessionId;
  final String permissionId;
  final String? itemId;
  final String title;
  final String? reason;
  final List<PermissionOption> options;
  const AgentPermissionRequest({
    required this.sessionId,
    required this.permissionId,
    required this.title,
    required this.options,
    this.itemId,
    this.reason,
  });
}

class AgentQuestionOption {
  final String id;
  final String label;
  final String? description;
  const AgentQuestionOption({
    required this.id,
    required this.label,
    this.description,
  });
}

class AgentQuestion {
  final String sessionId;
  final String questionId;
  final String? itemId;
  final String kind; // text | single_select | multi_select
  final String prompt;
  final List<AgentQuestionOption> options;
  final bool isSecret;
  const AgentQuestion({
    required this.sessionId,
    required this.questionId,
    required this.kind,
    required this.prompt,
    this.itemId,
    this.options = const [],
    this.isSecret = false,
  });
}

/// The bridge withdrew a pending permission/question (agent retracted it,
/// turn ended, or the driver was disposed). Exactly one id is set.
class AgentRequestRetracted {
  final String sessionId;
  final String? permissionId;
  final String? questionId;
  const AgentRequestRetracted({
    required this.sessionId,
    this.permissionId,
    this.questionId,
  });
}

class AgentErrorMessage {
  final String sessionId;
  final String? turnId;
  final AgentError error;
  const AgentErrorMessage({
    required this.sessionId,
    required this.error,
    this.turnId,
  });
}

class AgentUsageEvent {
  final String sessionId;
  final String? turnId;

  /// Anchor item for historical backfill frames. Live frames omit it so they
  /// continue to feed the session-level context meter.
  final String? itemId;
  final AgentUsage usage;
  const AgentUsageEvent({
    required this.sessionId,
    required this.usage,
    this.turnId,
    this.itemId,
  });
}

class AgentCapabilityCommand {
  final String id;
  final String name;
  final String? description;
  final String? argHint;
  const AgentCapabilityCommand({
    required this.id,
    required this.name,
    this.description,
    this.argHint,
  });
}

class AgentCapabilityMode {
  final String id;
  final String name;
  final String? description;
  const AgentCapabilityMode({
    required this.id,
    required this.name,
    this.description,
  });
}

class AgentCapabilityModel {
  final String id;
  final String name;
  final String? provider;
  final List<String> efforts;
  final String? defaultEffort;
  const AgentCapabilityModel({
    required this.id,
    required this.name,
    this.provider,
    this.efforts = const [],
    this.defaultEffort,
  });
}

/// What the running agent session can do (models, modes, slash commands) plus
/// the currently-applied ids. Latest frame wins; an all-empty frame means the
/// session advertises nothing (composer selectors hide).
class AgentCapabilities {
  final String sessionId;

  /// False while the driver is still discovering models/modes (an early frame
  /// carries empty lists). The composer shows a loading indicator until true.
  final bool ready;
  final List<AgentCapabilityCommand> commands;
  final List<AgentCapabilityMode> modes;
  final List<AgentCapabilityModel> models;
  final String? currentModelId;
  final String? currentModeId;
  final String? currentEffortId;
  const AgentCapabilities({
    required this.sessionId,
    this.ready = true,
    this.commands = const [],
    this.modes = const [],
    this.models = const [],
    this.currentModelId,
    this.currentModeId,
    this.currentEffortId,
  });

  AgentCapabilityModel? get currentModel {
    for (final m in models) {
      if (m.id == currentModelId) return m;
    }
    return null;
  }
}

/// A newer coding-agent CLI exists (bridge proactively detected the spawned
/// binary is behind the registry's latest). Advisory: the UI shows a
/// dismissible chip, not a modal. `tool` is the agent spec id ("codex" | ...).
class AgentUpdateAvailable {
  final String tool;
  final String installed;
  final String latest;
  final String? sessionId;
  const AgentUpdateAvailable({
    required this.tool,
    required this.installed,
    required this.latest,
    this.sessionId,
  });
}

/// Terminal outcome of an in-app `agent:update` run (bridge -> app). On success
/// [installed] is the re-probed version; on failure [output] carries a bounded
/// tail of the updater's stdout+stderr for the user to read.
class AgentUpdateResult {
  final String tool;
  final String? sessionId;
  final bool ok;
  final int? exitCode;
  final String? installed;
  final String? output;
  const AgentUpdateResult({
    required this.tool,
    this.sessionId,
    required this.ok,
    this.exitCode,
    this.installed,
    this.output,
  });
}

/// Parse a raw JSON envelope into a typed agent:* event, or null if it is not
/// one (or is malformed). Mirrors parseAbMessage's null-on-unknown contract.
Object? parseAgentEvent(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  switch (type) {
    case 'agent:turn-start':
      return AgentTurnStart(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String? ?? '',
      );
    case 'agent:session-reset':
      return AgentSessionReset(sessionId: json['sessionId'] as String? ?? '');
    case 'agent:turn-end':
      return AgentTurnEnd(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String? ?? '',
        stopReason: json['stopReason'] as String? ?? 'end_turn',
        error: AgentError.fromJson(json['error']),
      );
    case 'agent:item-added':
      final item = json['item'];
      if (item is! Map<String, dynamic>) return null;
      return AgentItemAdded(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String? ?? '',
        item: AgentItem.fromJson(item),
      );
    case 'agent:transcript-replay':
      final frames = json['frames'];
      if (frames is! List) return null;
      return AgentTranscriptReplay(
        sessionId: json['sessionId'] as String? ?? '',
        frames: frames
            .whereType<Map>()
            .map((f) => f.cast<String, dynamic>())
            .toList(growable: false),
      );
    case 'agent:item-delta':
      return AgentItemDelta(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String? ?? '',
        itemId: json['itemId'] as String? ?? '',
        textChunk: json['textChunk'] as String? ?? '',
      );
    case 'agent:item-updated':
      final item = json['item'];
      if (item is! Map<String, dynamic>) return null;
      return AgentItemUpdated(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String? ?? '',
        item: AgentItem.fromJson(item),
      );
    case 'agent:snapshot':
      final items = json['items'];
      return AgentSnapshot(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String? ?? '',
        items: items is List
            ? items
                  .whereType<Map<String, dynamic>>()
                  .map(AgentItem.fromJson)
                  .toList()
            : const [],
      );
    case 'agent:permission-request':
      final opts = json['options'];
      return AgentPermissionRequest(
        sessionId: json['sessionId'] as String? ?? '',
        permissionId: json['permissionId'] as String? ?? '',
        itemId: json['itemId'] as String?,
        title: json['title'] as String? ?? '',
        reason: json['reason'] as String?,
        options: opts is List
            ? opts
                  .whereType<Map<String, dynamic>>()
                  .map(
                    (o) => PermissionOption(
                      optionId: o['optionId'] as String? ?? '',
                      label: o['label'] as String? ?? '',
                      kind: o['kind'] as String? ?? 'allow_once',
                    ),
                  )
                  .toList()
            : const [],
      );
    case 'agent:question':
      final opts = json['options'];
      return AgentQuestion(
        sessionId: json['sessionId'] as String? ?? '',
        questionId: json['questionId'] as String? ?? '',
        itemId: json['itemId'] as String?,
        kind: json['kind'] as String? ?? 'text',
        prompt: json['prompt'] as String? ?? '',
        options: opts is List
            ? opts
                  .whereType<Map<String, dynamic>>()
                  .map(
                    (o) => AgentQuestionOption(
                      id: o['id'] as String? ?? '',
                      label: o['label'] as String? ?? '',
                      description: o['description'] as String?,
                    ),
                  )
                  .toList()
            : const [],
        isSecret: json['isSecret'] as bool? ?? false,
      );
    case 'agent:error':
      final err = AgentError.fromJson(json['error']);
      if (err == null) return null;
      return AgentErrorMessage(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String?,
        error: err,
      );
    case 'agent:usage':
      return AgentUsageEvent(
        sessionId: json['sessionId'] as String? ?? '',
        turnId: json['turnId'] as String?,
        itemId: json['itemId'] as String?,
        usage: AgentUsage(
          total: AgentTokenUsage.fromJson(json['total']),
          last: json['last'] == null
              ? null
              : AgentTokenUsage.fromJson(json['last']),
          contextWindow: (json['contextWindow'] as num?)?.toInt(),
        ),
      );
    case 'agent:request-retracted':
      return AgentRequestRetracted(
        sessionId: json['sessionId'] as String? ?? '',
        permissionId: json['permissionId'] as String?,
        questionId: json['questionId'] as String?,
      );
    case 'agent:capabilities':
      return AgentCapabilities(
        sessionId: json['sessionId'] as String? ?? '',
        // Absent = ready (legacy bridges / replayed snapshots predate the flag).
        ready: json['ready'] as bool? ?? true,
        commands: _mapList(
          json['commands'],
          (c) => AgentCapabilityCommand(
            id: c['id'] as String? ?? '',
            name: c['name'] as String? ?? '',
            description: c['description'] as String?,
            argHint: c['argHint'] as String?,
          ),
        ),
        modes: _mapList(
          json['modes'],
          (m) => AgentCapabilityMode(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? '',
            description: m['description'] as String?,
          ),
        ),
        models: _mapList(
          json['models'],
          (m) => AgentCapabilityModel(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? '',
            provider: m['provider'] as String?,
            efforts: m['efforts'] is List
                ? (m['efforts'] as List).whereType<String>().toList()
                : const [],
            defaultEffort: m['defaultEffort'] as String?,
          ),
        ),
        currentModelId: json['currentModelId'] as String?,
        currentModeId: json['currentModeId'] as String?,
        currentEffortId: json['currentEffortId'] as String?,
      );
    case 'agent:updateAvailable':
      return AgentUpdateAvailable(
        tool: json['tool'] as String? ?? '',
        installed: json['installed'] as String? ?? '',
        latest: json['latest'] as String? ?? '',
        sessionId: json['sessionId'] as String?,
      );
    case 'agent:updateResult':
      return AgentUpdateResult(
        tool: json['tool'] as String? ?? '',
        sessionId: json['sessionId'] as String?,
        ok: json['ok'] as bool? ?? false,
        exitCode: json['exitCode'] as int?,
        installed: json['installed'] as String?,
        output: json['output'] as String?,
      );
    default:
      return null;
  }
}

List<T> _mapList<T>(Object? raw, T Function(Map<String, dynamic>) f) =>
    raw is List ? raw.whereType<Map<String, dynamic>>().map(f).toList() : <T>[];
