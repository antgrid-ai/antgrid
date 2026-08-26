/// Reduce a possibly-compound `<deviceUuid>.<projectId>` id to its bare
/// `<deviceUuid>` prefix, matching `InventoryAgent.deviceUuid` format. The
/// stored value is either a bare UUID (a machine) or a compound
/// `<deviceUuid>.<projectId>` (one remote project on that machine).
String baseDeviceUuid(String agentDeviceId) {
  final dot = agentDeviceId.indexOf('.');
  return dot < 0 ? agentDeviceId : agentDeviceId.substring(0, dot);
}

/// Reduce a possibly-compound `<deviceUuid>.<projectId>` registrationId to its
/// bare `<projectId>` suffix — the local id the bridge keys its
/// file/git/search/command handlers by (`fileWatchers.get(msg.projectId)` in
/// bridge/src/agent-core.ts). The relay routing id is the compound form, but
/// wire payloads must carry the bare project id. Returns the input unchanged
/// when there's no `.` (already-bare local ids).
String baseProjectId(String registrationId) {
  final dot = registrationId.indexOf('.');
  return dot < 0 ? registrationId : registrationId.substring(dot + 1);
}
