import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

@immutable
class AbAgentBlock {
  final String? tool;
  final String? command;
  final List<String>? flags;
  final String? workingDir;

  const AbAgentBlock({this.tool, this.command, this.flags, this.workingDir});

  factory AbAgentBlock.fromJson(Map<String, dynamic> json) => AbAgentBlock(
    tool: json['tool'] as String?,
    command: json['command'] as String?,
    flags: (json['flags'] as List?)?.map((e) => e as String).toList(),
    workingDir: json['workingDir'] as String?,
  );

  Map<String, dynamic> toJson() => {
    if (tool != null) 'tool': tool,
    if (command != null) 'command': command,
    if (flags != null && flags!.isNotEmpty) 'flags': flags,
    if (workingDir != null) 'workingDir': workingDir,
  };

  AbAgentBlock copyWith({
    String? tool,
    String? command,
    List<String>? flags,
    String? workingDir,
  }) => AbAgentBlock(
    tool: tool ?? this.tool,
    command: command ?? this.command,
    flags: flags ?? this.flags,
    workingDir: workingDir ?? this.workingDir,
  );
}

@immutable
class AbService {
  final String name;
  final String command;
  final List<String>? args;
  final String? workingDir;
  final Map<String, String>? env;
  final bool? autoStart;

  const AbService({
    required this.name,
    required this.command,
    this.args,
    this.workingDir,
    this.env,
    this.autoStart,
  });

  factory AbService.fromJson(Map<String, dynamic> json) => AbService(
    name: json['name'] as String,
    command: json['command'] as String,
    args: (json['args'] as List?)?.map((e) => e as String).toList(),
    workingDir: json['workingDir'] as String?,
    env: (json['env'] as Map?)?.map(
      (k, v) => MapEntry(k as String, v as String),
    ),
    autoStart: json['autoStart'] as bool?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'command': command,
    if (args != null && args!.isNotEmpty) 'args': args,
    if (workingDir != null) 'workingDir': workingDir,
    if (env != null && env!.isNotEmpty) 'env': env,
    if (autoStart != null) 'autoStart': autoStart,
  };

  AbService copyWith({
    String? name,
    String? command,
    List<String>? args,
    String? workingDir,
    Map<String, String>? env,
    bool? autoStart,
  }) => AbService(
    name: name ?? this.name,
    command: command ?? this.command,
    args: args ?? this.args,
    workingDir: workingDir ?? this.workingDir,
    env: env ?? this.env,
    autoStart: autoStart ?? this.autoStart,
  );
}

@immutable
class AbCommand {
  final String name;
  final String command;
  final List<String>? args;
  final String? workingDir;
  final Map<String, String>? env;
  final bool? confirm;
  final String? description;
  final String? icon;

  const AbCommand({
    required this.name,
    required this.command,
    this.args,
    this.workingDir,
    this.env,
    this.confirm,
    this.description,
    this.icon,
  });

  factory AbCommand.fromJson(Map<String, dynamic> json) => AbCommand(
    name: json['name'] as String,
    command: json['command'] as String,
    args: (json['args'] as List?)?.map((e) => e as String).toList(),
    workingDir: json['workingDir'] as String?,
    env: (json['env'] as Map?)?.map(
      (k, v) => MapEntry(k as String, v as String),
    ),
    confirm: json['confirm'] as bool?,
    description: json['description'] as String?,
    icon: json['icon'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'command': command,
    if (args != null && args!.isNotEmpty) 'args': args,
    if (workingDir != null) 'workingDir': workingDir,
    if (env != null && env!.isNotEmpty) 'env': env,
    if (confirm != null) 'confirm': confirm,
    if (description != null) 'description': description,
    if (icon != null) 'icon': icon,
  };

  AbCommand copyWith({
    String? name,
    String? command,
    List<String>? args,
    String? workingDir,
    Map<String, String>? env,
    bool? confirm,
    String? description,
    String? icon,
  }) => AbCommand(
    name: name ?? this.name,
    command: command ?? this.command,
    args: args ?? this.args,
    workingDir: workingDir ?? this.workingDir,
    env: env ?? this.env,
    confirm: confirm ?? this.confirm,
    description: description ?? this.description,
    icon: icon ?? this.icon,
  );
}

enum OnDetect { notify, openPreview, silent, ignore }

OnDetect? _onDetectFromString(String? s) =>
    s == null ? null : OnDetect.values.firstWhereOrNull((e) => e.name == s);

String _onDetectToString(OnDetect d) => d.name;

@immutable
class AbPort {
  final int port;
  final String? name;
  final OnDetect? onDetect;

  const AbPort({required this.port, this.name, this.onDetect});

  factory AbPort.fromJson(Map<String, dynamic> json) => AbPort(
    port: json['port'] as int,
    name: json['name'] as String?,
    onDetect: _onDetectFromString(json['onDetect'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'port': port,
    if (name != null) 'name': name,
    if (onDetect != null) 'onDetect': _onDetectToString(onDetect!),
  };

  AbPort copyWith({int? port, String? name, OnDetect? onDetect}) => AbPort(
    port: port ?? this.port,
    name: name ?? this.name,
    onDetect: onDetect ?? this.onDetect,
  );
}

@immutable
class AbConfig {
  final String? name;
  final String? relayUrl;
  final AbAgentBlock? agent;
  final List<AbService> services;
  final List<AbCommand> commands;
  final List<AbPort> ports;

  const AbConfig({
    this.name,
    this.relayUrl,
    this.agent,
    this.services = const [],
    this.commands = const [],
    this.ports = const [],
  });

  factory AbConfig.fromJson(Map<String, dynamic> json) => AbConfig(
    name: json['name'] as String?,
    relayUrl: json['relayUrl'] as String?,
    agent: json['agent'] == null
        ? null
        : AbAgentBlock.fromJson(json['agent'] as Map<String, dynamic>),
    services: ((json['services'] as List?) ?? const [])
        .map((e) => AbService.fromJson(e as Map<String, dynamic>))
        .toList(),
    commands: ((json['commands'] as List?) ?? const [])
        .map((e) => AbCommand.fromJson(e as Map<String, dynamic>))
        .toList(),
    ports: ((json['ports'] as List?) ?? const [])
        .map(
          (e) => e is int
              ? AbPort(port: e)
              : AbPort.fromJson(e as Map<String, dynamic>),
        )
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (relayUrl != null) 'relayUrl': relayUrl,
    if (agent != null) 'agent': agent!.toJson(),
    if (services.isNotEmpty)
      'services': services.map((s) => s.toJson()).toList(),
    if (commands.isNotEmpty)
      'commands': commands.map((c) => c.toJson()).toList(),
    if (ports.isNotEmpty) 'ports': ports.map((p) => p.toJson()).toList(),
  };

  AbConfig copyWith({
    String? name,
    String? relayUrl,
    bool clearRelayUrl = false,
    AbAgentBlock? agent,
    List<AbService>? services,
    List<AbCommand>? commands,
    List<AbPort>? ports,
  }) {
    assert(
      !(clearRelayUrl && relayUrl != null),
      'Cannot set clearRelayUrl with an explicit relayUrl value.',
    );
    return AbConfig(
      name: name ?? this.name,
      relayUrl: clearRelayUrl ? null : (relayUrl ?? this.relayUrl),
      agent: agent ?? this.agent,
      services: services ?? this.services,
      commands: commands ?? this.commands,
      ports: ports ?? this.ports,
    );
  }
}
