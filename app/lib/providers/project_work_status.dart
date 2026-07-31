import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/control_plane_client.dart';
import 'recent_sessions.dart';

/// Effective per-project work status for the Recent list and the sidebar dot.
///
/// The live control-plane advert — which carries working/attention/error/done
/// for a project WITHOUT warming (opening) it — is the ONLY source, read from
/// [remoteProjectStatusProvider], a plain map the app_shell reaper fills from
/// ALREADY-open machine sockets. Reading that map never dials a socket (the
/// heavy control-plane graph is the reaper's job, not this hot per-row
/// provider).
///
/// No advert (older bridge, cold project, closed socket) ⇒ "done". A running
/// session is deliberately NOT a fallback for "working": the bridge only calls
/// a project working while a prompt is actually in flight (see the bridge's
/// work-status.ts), and an open-but-idle chat reading "working" was exactly the
/// bug that rule fixes — re-deriving it here from the session list would put it
/// straight back for every project whose advert hasn't arrived.
final projectWorkStatusProvider = Provider.family<AgentWorkStatus, String>((
  ref,
  entryId,
) {
  return ref.watch(
        remoteProjectStatusProvider.select((m) => m[entryId]),
      ) ??
      AgentWorkStatus.done;
});

/// Effective status for ONE session.
///
/// [perSession] is that project's live per-session map — the authoritative
/// source, and the reason a session blocked on a question no longer paints its
/// working sibling amber. Null means the advert carried no per-session data
/// (older bridge, cold project, closed socket): fall back to the project-level
/// [advert], which is what every row used to show.
///
/// A stopped session is always done: it can neither be working nor be the one
/// blocked on a permission.
AgentWorkStatus sessionRowStatus({
  required AgentWorkStatus? advert,
  required Map<String, AgentWorkStatus>? perSession,
  required String sessionId,
  required bool running,
}) {
  if (!running) return AgentWorkStatus.done;
  if (perSession != null) return perSession[sessionId] ?? AgentWorkStatus.done;
  return advert ?? AgentWorkStatus.done;
}

/// Live status for one session of one project, for the drawer's session rows.
/// Reads the two advert maps directly — like [projectWorkStatusProvider], this
/// never dials anything.
final sessionWorkStatusProvider =
    Provider.family<AgentWorkStatus, ({String entryId, String sessionId, bool running})>((
  ref,
  args,
) {
  return sessionRowStatus(
    advert: ref.watch(
      remoteProjectStatusProvider.select((m) => m[args.entryId]),
    ),
    perSession: ref.watch(
      remoteSessionStatusProvider.select((m) => m[args.entryId]),
    ),
    sessionId: args.sessionId,
    running: args.running,
  );
});

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
