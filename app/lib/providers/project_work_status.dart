import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/control_plane_client.dart';
import 'recent_sessions.dart';
import 'sessions.dart';

/// Effective per-project work status for the Recent list and the sidebar dot.
///
/// Prefers the live control-plane advert — which carries working/attention/
/// error/done for a project WITHOUT warming (opening) it — read from
/// [remoteProjectStatusProvider], a plain map the app_shell reaper fills from
/// ALREADY-open machine sockets. Reading that map never dials a socket (the
/// heavy control-plane graph is the reaper's job, not this hot per-row
/// provider). Falls back to session-running (working vs done) from the
/// live/cached session list when no advert status applies: an older bridge, a
/// cold project, a local project (bare id, no advert), or a closed socket.
final projectWorkStatusProvider = Provider.family<AgentWorkStatus, String>((
  ref,
  entryId,
) {
  final advertised = ref.watch(
    remoteProjectStatusProvider.select((m) => m[entryId]),
  );
  if (advertised != null) return advertised;
  final running = ref.watch(
    sessionsForEntryProvider(
      entryId,
    ).select((list) => list.any((s) => !s.archived && s.running)),
  );
  return running ? AgentWorkStatus.working : AgentWorkStatus.done;
});

/// Effective status for a single Recent row: the project-level [advert]
/// attention/error (which concern the whole project) win; otherwise fall to
/// this session's own [running] flag. [advert] is null when no live advert is
/// available (older bridge, cold project, closed socket).
AgentWorkStatus recentRowStatus(AgentWorkStatus? advert, bool running) {
  if (advert == AgentWorkStatus.attention || advert == AgentWorkStatus.error) {
    return advert!;
  }
  return running ? AgentWorkStatus.working : AgentWorkStatus.done;
}
