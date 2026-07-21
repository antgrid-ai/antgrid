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

/// Aggregate work status for a machine: the most severe status across ALL of
/// its projects in the live advert map (attention > error > working > done).
/// Returns null when no advert status is available for any project on this
/// machine (older bridge, all sockets closed, no projects running).
///
/// Used by the drawer machine header to show a single indicator when the
/// machine row is collapsed and individual project rows aren't visible.
final machineWorkStatusProvider =
    Provider.family<AgentWorkStatus?, String>((ref, machineUuid) {
  final prefix = '$machineUuid.';
  // Aggregation runs inside select so it returns AgentWorkStatus? (enum value
  // equality), not a List. A new List is never == to another List in Dart, so
  // returning one from select would defeat Riverpod's equality guard and cause
  // every machineWorkStatusProvider to rebuild on every unrelated machine's
  // status change.
  return ref.watch(
    remoteProjectStatusProvider.select((m) {
      // Precedence: attention > error > working > done. Null = no matching keys.
      AgentWorkStatus? best;
      for (final e in m.entries) {
        if (!e.key.startsWith(prefix)) continue;
        final s = e.value;
        if (s == AgentWorkStatus.attention) return AgentWorkStatus.attention;
        if (s == AgentWorkStatus.error) {
          best = AgentWorkStatus.error;
        } else if (s == AgentWorkStatus.working &&
            (best == null || best == AgentWorkStatus.done)) {
          best = AgentWorkStatus.working;
        } else {
          best ??= AgentWorkStatus.done;
        }
      }
      return best;
    }),
  );
});
