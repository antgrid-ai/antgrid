import 'package:flutter/foundation.dart';

enum CommandStatus { idle, running, success, failed }

class CommandExecution {
  final String commandName;
  final String projectId;
  final CommandStatus status;
  final int? exitCode;
  final ValueNotifier<String> output;

  CommandExecution({
    required this.commandName,
    required this.projectId,
    this.status = CommandStatus.running,
    this.exitCode,
    ValueNotifier<String>? output,
  }) : output = output ?? ValueNotifier('');

  CommandExecution copyWith({CommandStatus? status, int? exitCode}) {
    return CommandExecution(
      commandName: commandName,
      projectId: projectId,
      status: status ?? this.status,
      exitCode: exitCode ?? this.exitCode,
      output: output,
    );
  }
}

class CommandState {
  final CommandExecution? current;

  const CommandState({this.current});

  CommandState copyWith({
    CommandExecution? current,
    bool clearCurrent = false,
  }) {
    return CommandState(
      current: clearCurrent ? null : (current ?? this.current),
    );
  }
}
