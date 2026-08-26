import '../services/account_agents_api.dart';
import '../storage/recent_agents_store.dart';
import 'ab_project.dart';

/// Kind of a drawer row. Drives the visual badge (LOCAL muted vs REMOTE accent)
/// and disambiguates the two subclasses below for switch-based dispatch.
enum EntryKind { local, remote }

/// One row in the projects drawer. Either a local-mode project the user has
/// opened, or a remote agent the phone has paired with.
sealed class DrawerEntry {
  String get id;
  String get displayName;
  String get subtitle;
  DateTime get lastAccessAt;
  EntryKind get kind;

  /// Bare device uuid when this entry represents a remote MACHINE (a
  /// same-account paired machine or an inventory machine) — the value whose
  /// control plane advertises projects and under which open projects' sessions
  /// nest. Null for a local project or an entry that is itself a single remote
  /// project (compound `<uuid>.<projectId>` id), neither of which is a machine
  /// the drawer expands into per-project sessions.
  String? get machineUuid => null;
}

class LocalProjectEntry extends DrawerEntry {
  final AbProject project;
  LocalProjectEntry(this.project);

  @override
  String get id => project.projectId;
  @override
  String get displayName => project.displayName;
  @override
  String get subtitle => project.folder;
  @override
  DateTime get lastAccessAt => project.lastOpenedAt;
  @override
  EntryKind get kind => EntryKind.local;
}

class RemoteAgentEntry extends DrawerEntry {
  final RecentAgent agent;
  RemoteAgentEntry(this.agent);

  /// A machine persists the BARE `deviceUuid` (no dot); a legacy per-project
  /// row persists the compound `<uuid>.<projectId>`. The dot tells the two
  /// apart: bare → this row is a machine; compound → a single project.
  bool get _isMachineLevel => !agent.agentDeviceId.contains('.');

  @override
  String get id => agent.agentDeviceId;
  @override
  String? get machineUuid => _isMachineLevel ? agent.agentDeviceId : null;
  @override
  String get displayName => _isMachineLevel
      ? _machineLabel(agent)
      : _projectNameFromId(agent.agentDeviceId);
  @override
  String get subtitle => agent.agentLabel;
  @override
  DateTime get lastAccessAt => agent.lastConnectedAt;
  @override
  EntryKind get kind => EntryKind.remote;
}

/// A same-account agent from the remote inventory that has not yet been paired
/// with this phone. Distinct from [RemoteAgentEntry] which requires a
/// previously-paired [RecentAgent].
class InventoryAgentEntry extends DrawerEntry {
  final InventoryAgent agent;
  InventoryAgentEntry(this.agent);

  @override
  String get id => agent.deviceUuid;
  @override
  String? get machineUuid => agent.deviceUuid;
  @override
  String get displayName => agent.displayName;
  @override
  String get subtitle => agent.platform;
  @override
  DateTime get lastAccessAt =>
      agent.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  @override
  EntryKind get kind => EntryKind.remote;
}

/// Mirror of `projectNameFromId` in `providers.dart`. Duplicated to avoid a
/// providers.dart → models cycle. Both implementations split on the first dot.
String _projectNameFromId(String agentDeviceId) {
  final i = agentDeviceId.indexOf('.');
  return i < 0 ? agentDeviceId : agentDeviceId.substring(i + 1);
}

/// Human label for a machine-level [RemoteAgentEntry]: the host machine name if
/// known, else the pairing label, else the bare uuid as a last resort. Without
/// this a same-account machine (whose `agentDeviceId` is the bare uuid) would
/// render its raw uuid as the row title.
String _machineLabel(RecentAgent agent) {
  final machine = agent.hostMachineName?.trim();
  if (machine != null && machine.isNotEmpty) return machine;
  final label = agent.agentLabel.trim();
  if (label.isNotEmpty) return label;
  return agent.agentDeviceId;
}
