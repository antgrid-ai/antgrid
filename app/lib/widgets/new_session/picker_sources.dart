/// A selectable project row inside a picker source.
class PickerProject {
  final String id; // local: projectId. remote: RemoteProject.registrationId.
  final String name;
  final String detail; // folder path (local) or platform/branch (remote)
  final bool isLocal;
  final DateTime? lastActiveAt; // null → no "last active" label

  // Remote-only: the machine's bare deviceUuid and the project id, kept split so
  // activation can rebuild RemoteProject(machineUuid, projectId). Null for local.
  final String? machineUuid;
  final String? projectId;

  // Whether the project's core is running on the machine. Drives the row badge
  // and the start-on-open decision. Always true for local rows (openable as-is).
  final bool running;

  const PickerProject({
    required this.id,
    required this.name,
    required this.detail,
    required this.isLocal,
    this.lastActiveAt,
    this.machineUuid,
    this.projectId,
    this.running = true,
  });
}

/// A rail source: "Local" or one remote MACHINE (keyed by bare deviceUuid).
class PickerSource {
  final String id; // 'local' or 'machine:<deviceUuid>'
  final String label;
  final bool isLocal;
  final List<PickerProject> projects; // local: folders. remote: always empty —
  // remote rows come from controlPlaneStateProvider(machineUuid) in the widget.
  final String? machineUuid; // remote: the bare deviceUuid. null for local.
  const PickerSource({
    required this.id,
    required this.label,
    required this.isLocal,
    required this.projects,
    this.machineUuid,
  });
  int get count => projects.length;
}
