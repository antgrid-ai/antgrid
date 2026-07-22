import '../models/ab_project.dart';
import '../models/session_entry.dart';
import '../services/account_agents_api.dart';
import '../storage/recent_agents_store.dart';
import '../util/device_id.dart';

/// Where a recent session lives — its project + device, plus the ids needed to
/// open or delete it. Built by [buildRecentSessions]; never persisted.
class RecentOrigin {
  final bool isLocal;

  /// Cache key and open/delete id: bare `projectId` for local,
  /// `<uuid>.<projectId>` for remote.
  final String registrationId;
  final String projectId;
  final String? machineUuid; // null for local
  final String projectName;
  final String deviceName;

  const RecentOrigin({
    required this.isLocal,
    required this.registrationId,
    required this.projectId,
    required this.machineUuid,
    required this.projectName,
    required this.deviceName,
  });
}

class RecentSessionRow {
  final SessionEntry session;
  final RecentOrigin origin;
  const RecentSessionRow({required this.session, required this.origin});
}

/// Flatten every cached project's non-archived sessions into one recency-sorted
/// list, resolving each cache key to a [RecentOrigin]. Pure — no Riverpod, no
/// I/O — so it unit-tests directly.
///
/// Cache keys: a LOCAL project keys by bare `projectId`; a REMOTE project keys
/// by the compound `<machineUuid>.<projectId>` registration id (see
/// CachedSessionsStore + drawer_entry). We discriminate by matching a local
/// project first, then falling back to the compound split.
///
/// [remoteProjectLabels] maps `"<machineUuid>.<projectId>"` → human-readable
/// label from the live control-plane advertisement. Pass empty when offline;
/// the raw projectId is the stable fallback.
List<RecentSessionRow> buildRecentSessions({
  required Map<String, List<SessionEntry>> cached,
  required List<AbProject> locals,
  required List<RecentAgent> remotes,
  required List<InventoryAgent> inventory,
  required String localDeviceLabel,
  Map<String, String> remoteProjectLabels = const {},
}) {
  final localById = {for (final p in locals) p.projectId: p};
  final rows = <RecentSessionRow>[];

  cached.forEach((entryId, sessions) {
    final origin = _resolveOrigin(
      entryId,
      localById: localById,
      remotes: remotes,
      inventory: inventory,
      localDeviceLabel: localDeviceLabel,
      remoteProjectLabels: remoteProjectLabels,
    );
    for (final session in sessions) {
      if (session.archived) continue;
      rows.add(RecentSessionRow(session: session, origin: origin));
    }
  });

  rows.sort((a, b) => b.session.lastUsedAt.compareTo(a.session.lastUsedAt));
  return List.unmodifiable(rows);
}

RecentOrigin _resolveOrigin(
  String entryId, {
  required Map<String, AbProject> localById,
  required List<RecentAgent> remotes,
  required List<InventoryAgent> inventory,
  required String localDeviceLabel,
  required Map<String, String> remoteProjectLabels,
}) {
  // Local project: cache key is the bare projectId.
  final local = localById[entryId];
  if (local != null) {
    return RecentOrigin(
      isLocal: true,
      registrationId: entryId,
      projectId: entryId,
      machineUuid: null,
      projectName: local.displayName,
      deviceName: localDeviceLabel,
    );
  }

  final machineUuid = baseDeviceUuid(entryId);
  if (machineUuid != entryId) {
    // Compound `<uuid>.<projectId>` → remote project.
    final projectId = entryId.substring(machineUuid.length + 1);
    return RecentOrigin(
      isLocal: false,
      registrationId: entryId,
      projectId: projectId,
      machineUuid: machineUuid,
      // Prefer the live control-plane label; fall back to the raw projectId
      // when the machine is offline or the advert hasn't arrived yet.
      projectName: remoteProjectLabels[entryId] ?? projectId,
      deviceName: _remoteMachineLabel(machineUuid, remotes, inventory),
    );
  }

  // Bare id with no local match (e.g. a removed local project still in cache).
  // Best-effort: keep the row rather than silently dropping it.
  return RecentOrigin(
    isLocal: true,
    registrationId: entryId,
    projectId: entryId,
    machineUuid: null,
    projectName: entryId,
    deviceName: localDeviceLabel,
  );
}

/// Mirrors [_machineLabel] in drawer_entry.dart: hostMachineName → agentLabel
/// → bare uuid. For inventory agents (no matching recent), machineName wins
/// over displayName.
String _remoteMachineLabel(
  String uuid,
  List<RecentAgent> remotes,
  List<InventoryAgent> inventory,
) {
  for (final r in remotes) {
    if (baseDeviceUuid(r.agentDeviceId) != uuid) continue;
    final machine = r.hostMachineName?.trim();
    if (machine != null && machine.isNotEmpty) return machine;
    final label = r.agentLabel.trim();
    if (label.isNotEmpty) return label;
    return uuid;
  }
  for (final a in inventory) {
    if (a.deviceUuid != uuid) continue;
    final machine = a.machineName?.trim();
    if (machine != null && machine.isNotEmpty) return machine;
    return a.displayName;
  }
  return uuid;
}
