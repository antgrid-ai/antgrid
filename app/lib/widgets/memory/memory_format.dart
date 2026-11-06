import '../../models/agent_descriptor.dart';
import '../../models/memory.dart';
import '../../util/relative_time.dart';

String memoryAgentName(
  MemoryRecord record,
  Map<String, AgentDescriptor> catalog,
) {
  if (record.byApp) return 'you';
  final id = record.agentId;
  return catalog[id]?.label ?? id ?? 'an agent';
}

String memoryMetaLine({
  required String project,
  required String agent,
  required DateTime? created,
  DateTime? now,
}) {
  const sep = '  ·  ';
  final age = created == null ? '' : '$sep${compactRelativeTime(created, now: now)}';
  return '$project$sep$agent$age';
}

/// One tag per row, strongest state first: a replaced memory that also belongs
/// to a session still reads as replaced.
String? memoryRowTag(MemoryRecord record, {required bool projectRemoved}) {
  if (record.lifecycle == 'superseded') return 'Replaced';
  if (record.lifecycle == 'expired') return 'Expired';
  if (record.isTaskScope) return 'This session';
  if (projectRemoved) return 'Removed project';
  return null;
}

String memoryScopeLabel(MemoryRecord record) => record.isTaskScope
    ? 'Session ${record.shortSessionId} only'
    : 'Project memory';

/// Expiry is time-based on the bridge, not tied to the session ending.
String? memoryLifecycleLabel(MemoryRecord record) =>
    switch (record.lifecycle) {
      'superseded' => 'Replaced by a newer version',
      'expired' => 'Expired after 30 days without an update',
      _ => null,
    };

String memoryAppliesText(MemoryRecord record, {required String project}) {
  if (record.applicability.trim().isNotEmpty) return record.applicability;
  if (record.isTaskScope) return 'Only inside session ${record.shortSessionId}.';
  return 'Not stated. Agents treat it as a general note for $project.';
}

String memorySavedLine(
  MemoryRecord record, {
  required String agent,
  required String project,
  required bool projectRemoved,
  DateTime? now,
}) {
  final created = record.createdAt;
  final age = created == null ? '' : ', ${relativeTime(created, now: now)}';
  final removed = projectRemoved ? ' (project removed from Antgrid)' : '';
  return 'Saved by $agent$age, in $project$removed';
}

String memoryEarlierWhen(
  MemoryRecord record, {
  required String agent,
  DateTime? now,
}) {
  final created = record.createdAt;
  return created == null
      ? 'Saved by $agent'
      : 'Saved by $agent, ${relativeTime(created, now: now)}';
}

String memoryEarlierLabel(int n, {bool more = false}) {
  if (more) return '$n+ earlier versions';
  return n == 1 ? '1 earlier version' : '$n earlier versions';
}

String memoryCountLabel(int n) => n == 1 ? '1 memory' : '$n memories';

String memoryTechSavedBy(MemoryRecord record) => record.byApp
    ? 'you (app)'
    : '${record.agentId ?? 'unknown'} (agent)';
