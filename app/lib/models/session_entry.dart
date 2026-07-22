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
    agentSessionId,
  );
}
