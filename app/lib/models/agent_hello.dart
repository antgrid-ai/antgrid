import 'package:flutter/foundation.dart';

@immutable
class AgentHello {
  final String? tool;
  final String? command;
  final String version;
  final List<String> flags;

  const AgentHello({
    this.tool,
    this.command,
    required this.version,
    this.flags = const [],
  });

  factory AgentHello.fromJson(Map<String, dynamic> j) => AgentHello(
    tool: j['tool'] as String?,
    command: j['command'] as String?,
    version: j['version'] as String,
    flags: (j['flags'] as List?)?.cast<String>() ?? const [],
  );

  Map<String, dynamic> toJson() => {
    if (tool != null) 'tool': tool,
    if (command != null) 'command': command,
    'version': version,
    'flags': flags,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentHello &&
          tool == other.tool &&
          command == other.command &&
          version == other.version &&
          listEquals(flags, other.flags);

  @override
  int get hashCode =>
      Object.hash(tool, command, version, Object.hashAll(flags));
}
