import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/control_plane_client.dart';
import '../services/sessions_service.dart';
import 'recent_sessions.dart';
import 'sessions.dart';

/// Effective per-project work status, for the surfaces that speak for a whole
/// project: the title bar's focused-project pill, and a COLLAPSED drawer
/// project row (local or advertised-remote), whose session rows are off screen
/// and so cannot speak for themselves. An EXPANDED drawer project row shows no
/// dot — its sessions are right there. Session-level surfaces speak for ONE
/// session instead: session rows read [sessionWorkStatusProvider], and the
/// whole Recent list shares [recentSessionStatusesProvider].
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
  return ref.watch(remoteProjectStatusProvider.select((m) => m[entryId])) ??
      AgentWorkStatus.done;
});

/// The OPEN project's own live stamp for [sessionId], or null when [entryId]
/// isn't the focused project or the entry carries no status.
///
/// The bridge stamps `workStatus` on every session of every `session:updated` it
/// emits on the project's DATA plane, so this moves the instant a turn starts or
/// a question blocks — ahead of, and independent of, the control-plane advert
/// that fills the two maps below. Without it the chat you are actively looking
/// at is the LAST row to move: it waits on its machine's next advert, which on
/// mobile is a push and on desktop a 2s poll, so a prompt you just sent leaves
/// its own row reading "done".
///
/// Deliberately scoped to the focused project: that is the only session list the
/// app keeps live, and the cache strips `workStatus` on write precisely so a
/// stale "working" can't outlive the process that reported it.
AgentWorkStatus? liveSessionWorkStatus(
  SessionsState? fresh,
  String entryId,
  String sessionId,
) {
  if (fresh == null || fresh.projectId != entryId) return null;
  for (final s in fresh.sessions) {
    if (s.id == sessionId) return s.workStatus;
  }
  return null;
}

/// Effective status for ONE session.
///
/// [live] is the focused project's own data-plane stamp (see
/// [liveSessionWorkStatus]) and outranks everything: it comes from the same
/// reduction the advert is built from, only sooner.
///
/// [perSession] is that project's live per-session map — the authoritative
/// source, and the reason a session blocked on a question no longer paints its
/// working sibling amber. Null means the advert carried no per-session data
/// (older bridge, cold project, closed socket): fall back to the project-level
/// [advert], which is what every row used to show.
///
/// An entry in [perSession] outranks [running], deliberately. The bridge only
/// ever files a status for a session it lists as RUNNING (see `build()` in
/// work-status.ts), so the entry itself proves liveness — whereas [running]
/// comes from the row's cached copy, which is forced false for every session on
/// disk load and is only refreshed while that project is warm. Masking on it
/// made every Recent row read "done" after a restart, including the one the
/// agent was actively blocked on.
///
/// Without per-session data a stopped session is still always done: it can
/// neither be working nor be the one blocked on a permission.
AgentWorkStatus sessionRowStatus({
  required AgentWorkStatus? advert,
  required Map<String, AgentWorkStatus>? perSession,
  required String sessionId,
  required bool running,
  AgentWorkStatus? live,
}) {
  if (live != null) return live;
  if (perSession != null) return perSession[sessionId] ?? AgentWorkStatus.done;
  if (!running) return AgentWorkStatus.done;
  return advert ?? AgentWorkStatus.done;
}

/// Live status for ONE session of one project — the single computation site for
/// a session-level dot anywhere in the app (drawer rows, title bar, Recent
/// rows). Reads the two advert maps directly; like [projectWorkStatusProvider],
/// this never dials anything.
///
/// [recentSessionStatusesProvider] is a projection of this, not a second
/// implementation, so the Recent rows can't disagree with the group headers and
/// summary counts computed over them. Add a term here and every one of those
/// surfaces moves together.
///
/// `autoDispose` is load-bearing, not an optimization: [running] is part of the
/// family key and flips over a session's life, so a plain family would mint a
/// second permanent instance — each holding two `select` subscriptions — every
/// time a session starts or stops, for as long as the app runs.
final sessionWorkStatusProvider = Provider.autoDispose
    .family<
      AgentWorkStatus,
      ({String entryId, String sessionId, bool running})
    >((ref, args) {
      return sessionRowStatus(
        live: liveSessionWorkStatus(
          ref.watch(freshSessionsStateProvider),
          args.entryId,
          args.sessionId,
        ),
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

/// Key for one Recent row inside [recentSessionStatusesProvider].
String recentStatusKey(String entryId, String sessionId) =>
    '$entryId:$sessionId';

/// Effective status of every row in the Recent list, keyed by
/// [recentStatusKey] — for the surfaces that speak about the list as a whole
/// (the group-by-status buckets, and the summary counts, which mobile hoists
/// out of the list into the canvas's top bar).
///
/// A projection of [sessionWorkStatusProvider], deliberately: the rows paint
/// themselves from that provider directly, so recomputing the status here
/// instead of watching it is what would let a row contradict the bucket it sits
/// in. Watching it also keeps the rows' `autoDispose` instances alive while the
/// list is mounted, so the two never race to rebuild.
///
/// Keyed by a string, not by the row object: [recentSessionsProvider] mints
/// fresh row instances on every rebuild, so a row-keyed map would miss on the
/// very next frame.
final recentSessionStatusesProvider = Provider<Map<String, AgentWorkStatus>>((
  ref,
) {
  return {
    for (final r in ref.watch(recentSessionsProvider))
      recentStatusKey(r.origin.registrationId, r.session.id): ref.watch(
        sessionWorkStatusProvider((
          entryId: r.origin.registrationId,
          sessionId: r.session.id,
          running: r.session.running,
        )),
      ),
  };
});

/// How many Recent rows sit in each state, for the summary badges.
final recentSessionStatusCountsProvider = Provider<Map<AgentWorkStatus, int>>((
  ref,
) {
  final counts = <AgentWorkStatus, int>{};
  for (final s in ref.watch(recentSessionStatusesProvider).values) {
    counts[s] = (counts[s] ?? 0) + 1;
  }
  return counts;
});

/// Aggregate work status for a machine: the most severe status across ALL of
/// its projects in the live advert map (attention > error > working > unread >
/// done).
/// Returns null when no advert status is available for any project on this
/// machine (older bridge, all sockets closed, no projects running).
///
/// Used by the drawer machine header to show a single indicator when the
/// machine row is collapsed and individual project rows aren't visible.
/// Severity rank for the machine rollup. Mirrors the bridge's `RANK`; kept as a
/// switch rather than the enum's own index so reordering [AgentWorkStatus] —
/// whose order is the WIRE's, not a severity — cannot silently re-rank machines.
int _machineRank(AgentWorkStatus s) => switch (s) {
  AgentWorkStatus.attention => 4,
  AgentWorkStatus.error => 3,
  AgentWorkStatus.working => 2,
  AgentWorkStatus.unread => 1,
  AgentWorkStatus.done => 0,
};

final machineWorkStatusProvider = Provider.family<AgentWorkStatus?, String>((
  ref,
  machineUuid,
) {
  final prefix = '$machineUuid.';
  // Aggregation runs inside select so it returns AgentWorkStatus? (enum value
  // equality), not a List. A new List is never == to another List in Dart, so
  // returning one from select would defeat Riverpod's equality guard and cause
  // every machineWorkStatusProvider to rebuild on every unrelated machine's
  // status change.
  return ref.watch(
    remoteProjectStatusProvider.select((m) {
      // Precedence: attention > error > working > unread > done, the same rank
      // the bridge rolls a project up by (`RANK` in work-status.ts). Null = no
      // matching keys.
      AgentWorkStatus? best;
      for (final e in m.entries) {
        if (!e.key.startsWith(prefix)) continue;
        final s = e.value;
        if (s == AgentWorkStatus.attention) return AgentWorkStatus.attention;
        if (best == null || _machineRank(s) > _machineRank(best)) best = s;
      }
      return best;
    }),
  );
});
