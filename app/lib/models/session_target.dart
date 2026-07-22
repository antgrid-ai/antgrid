sealed class SessionTarget {
  const SessionTarget();

  String get registrationId;
  bool get isLocal;
}

final class LocalProject extends SessionTarget {
  final String projectId;

  const LocalProject(this.projectId);

  @override
  String get registrationId => projectId;

  @override
  bool get isLocal => true;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalProject && other.projectId == projectId;

  @override
  int get hashCode => Object.hash('local', projectId);
}

final class RemoteProject extends SessionTarget {
  final String machineUuid;
  final String projectId;

  const RemoteProject({required this.machineUuid, required this.projectId});

  @override
  String get registrationId => '$machineUuid.$projectId';

  @override
  bool get isLocal => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteProject &&
          other.machineUuid == machineUuid &&
          other.projectId == projectId;

  @override
  int get hashCode => Object.hash('remote', machineUuid, projectId);
}

final class RemoteTarget extends SessionTarget {
  final String agentDeviceId;

  const RemoteTarget._legacy(this.agentDeviceId);

  // Migration bridge: older callers may already hold a full registration id.
  const factory RemoteTarget.legacy(String agentDeviceId) =
      RemoteTarget._legacy;

  @override
  String get registrationId => agentDeviceId;

  @override
  bool get isLocal => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteTarget && other.agentDeviceId == agentDeviceId;

  @override
  int get hashCode => Object.hash('remote-legacy', agentDeviceId);
}
