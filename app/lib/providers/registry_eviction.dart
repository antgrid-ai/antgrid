import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../demo/demo_identity.dart';
import '../project/project_session_registry.dart';
import '../project/project_status_cache.dart';
import 'agent_transport.dart';
import 'drawer_entries.dart';

/// The registry's eviction callback: snapshot the evicted project's final
/// status for drawer hydration, then invalidate its session + transport family
/// entries so the WS closes and the agent's owner-lock is released.
///
/// The status snapshot is GATED on [projectId] still being a live drawer entry.
/// A delete/forget removes the entry, then purges the status file; a session
/// warm-up that resolves AFTER that purge would otherwise re-evict and rewrite
/// the file, resurrecting status for a project that no longer exists. Because
/// [drawerEntriesProvider] is exactly what [projectStatusProvider] hydrates
/// from, skipping the write for an absent entry makes the purge the final word
/// — independent of how late an abandoned warm-up settles.
Future<void> snapshotAndInvalidateOnEvict(
  Ref ref,
  ProjectStatusCache cache,
  String projectId,
) async {
  final session = ref.read(projectSessionProvider(projectId)).value;
  final stillListed = ref
      .read(drawerEntriesProvider)
      .any((e) => e.id == projectId);
  // The demo gate does not lean on `stillListed` being false for the sample
  // project: nothing about the demo may reach disk, whatever a later change
  // does to drawer entries.
  if (session != null && stillListed && !isDemoEntryId(projectId)) {
    await cache.write(projectId, session.status.value);
  }
  // Invalidate BOTH the session and the transport family entry so the WS is
  // closed and the agent's owner-lock released — otherwise reopening the
  // project later trips 4409 ("already owned") because the relay still has us
  // as owner.
  ref.invalidate(projectSessionProvider(projectId));
  ref.invalidate(agentTransportForProvider(projectId));
}
