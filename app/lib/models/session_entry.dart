import 'agent_work_status.dart';

class SessionEntry {
  final String id;
  final String name;
  final int createdAt;
  final int lastUsedAt;
  final bool archived;
  final bool running;
  final String? tool;
  final String? command;
  final String? args;
  final String mode;

  /// False when this session's agent-native conversation can no longer be
  /// resumed, so a mode switch would silently start a fresh one. Deliberately
  /// NOT "can this session switch mode" — that also depends on the tool having
  /// a chat driver, which arrives separately as `chatCapable` on `agent:tools`
  /// and must stay separable: missing history HIDES the mode control, an agent
  /// without a driver DISABLES the Chat cell.
  final bool agentSessionResumable;

  /// This session's own work status, folded per session on the bridge from the
  /// notifications this slot fired. Null when the bridge doesn't report it (an
  /// older build, or the disk-only peek, which has no runtime to reduce) —
  /// callers must treat null as "unknown", never as idle-and-safe.
  ///
  /// Advisory only. The bridge cannot tell a genuine mid-turn block from a
  /// post-turn idle nudge, so this may louden a confirmation but must never
  /// gate one.
  final AgentWorkStatus? workStatus;
  final String? agentSessionId;

  const SessionEntry({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.lastUsedAt,
    required this.archived,
    required this.running,
    this.tool,
    this.command,
    this.args,
    this.mode = 'terminal',
    this.agentSessionResumable = true,
    this.workStatus,
    this.agentSessionId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
    'lastUsedAt': lastUsedAt,
    'archived': archived,
    'running': running,
    if (tool != null) 'tool': tool,
    if (command != null) 'command': command,
    if (args != null) 'args': args,
    'mode': mode,
    'agentSessionResumable': agentSessionResumable,
    if (workStatus != null) 'workStatus': workStatus!.name,
    if (agentSessionId != null) 'agentSessionId': agentSessionId,
  };

  factory SessionEntry.fromJson(Map<String, dynamic> j) => SessionEntry(
    id: j['id'] as String,
    name: j['name'] as String,
    createdAt: (j['createdAt'] as num).toInt(),
    lastUsedAt: (j['lastUsedAt'] as num).toInt(),
    archived: j['archived'] as bool,
    // `running` is process-lifetime state, absent from disk-only sources (the
    // control-plane peek and the persisted cache both omit/strip it); default
    // false rather than throwing.
    running: j['running'] as bool? ?? false,
    tool: j['tool'] as String?,
    command: j['command'] as String?,
    args: j['args'] as String?,
    mode: j['mode'] as String? ?? 'terminal',
    // Optimistic on absence, matching the bridge schema's default: a stale
    // `true` only lets the mode control show for a conversation that turns out
    // to be gone, while a wrong `false` would hide it outright.
    agentSessionResumable: j['agentSessionResumable'] as bool? ?? true,
    // Null on absence, and on any value this build doesn't know: a status the
    // app can't name is not a status it should act on.
    workStatus: AgentWorkStatus.fromWire(j['workStatus']),
    agentSessionId: j['agentSessionId'] as String?,
  );

  /// Parse a JSON array of session maps, skipping any non-map element. Shared by
  /// the control-plane peek and the live sessions service so the two decoders
  /// never drift.
  static List<SessionEntry> listFromJson(List<dynamic>? raw) => [
    for (final s in raw ?? const [])
      if (s is Map<String, dynamic>) SessionEntry.fromJson(s),
  ];

  SessionEntry copyWith({
    String? name,
    int? lastUsedAt,
    bool? archived,
    bool? running,
  }) => SessionEntry(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    archived: archived ?? this.archived,
    running: running ?? this.running,
    tool: tool,
    command: command,
    args: args,
    mode: mode,
    agentSessionResumable: agentSessionResumable,
    workStatus: workStatus,
    agentSessionId: agentSessionId,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionEntry &&
          other.id == id &&
          other.name == name &&
          other.createdAt == createdAt &&
          other.lastUsedAt == lastUsedAt &&
          other.archived == archived &&
          other.running == running &&
          other.tool == tool &&
          other.command == command &&
          other.args == args &&
          other.mode == mode &&
          other.agentSessionResumable == agentSessionResumable &&
          other.workStatus == workStatus &&
          other.agentSessionId == agentSessionId;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    createdAt,
    lastUsedAt,
    archived,
    running,
    tool,
    command,
    args,
    mode,
    agentSessionResumable,
    workStatus,
    agentSessionId,
  );
}
