class ServiceStatus {
  final String id;
  final String name;
  final bool running;
  final String command;
  final int? exitCode;

  const ServiceStatus({
    required this.id,
    required this.name,
    required this.running,
    required this.command,
    this.exitCode,
  });

  static ServiceStatus? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    final running = j['running'];
    final command = j['command'];
    if (id is! String ||
        name is! String ||
        running is! bool ||
        command is! String) {
      return null;
    }
    return ServiceStatus(
      id: id,
      name: name,
      running: running,
      command: command,
      exitCode: j['exitCode'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'running': running,
    'command': command,
    if (exitCode != null) 'exitCode': exitCode,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServiceStatus &&
          id == other.id &&
          name == other.name &&
          running == other.running &&
          command == other.command &&
          exitCode == other.exitCode;

  @override
  int get hashCode => Object.hash(id, name, running, command, exitCode);
}
