import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/recent_agents_store.dart';
import '../util/device_id.dart';
import '../utils/platform_utils.dart';
import 'recent_agents.dart';

/// Whether this platform dials known machines proactively at launch/resume.
///
/// Mobile only: the phone is opened to check on sessions already running
/// elsewhere, and without eager dials the first paint shows every machine
/// offline until the user expands a drawer row or pulls to refresh. Desktop
/// keeps the fully lazy flow — it sits next to its agents, typically holds
/// many more machines, and an earlier eager-connect-everywhere design caused
/// connection storms (see _seedNeverSyncedSessions in app_shell.dart).
///
/// A provider (not a bare [isMobilePlatform] read) so tests can force either
/// platform without `debugDefaultTargetPlatformOverride`.
final eagerControlPlanesEnabledProvider = Provider<bool>(
  (_) => isMobilePlatform,
);

/// Ceiling on proactive dials per launch. Each dial is a persistent WebSocket
/// + E2E session held for the whole foregrounded lifetime — a battery and
/// radio cost per machine, and the relay meters no per-account quota against
/// them (see the Streams bullet in `relay/CLAUDE.md`) — so eagerness is
/// bounded to the machines the user most recently connected to; the rest keep
/// the on-demand flow.
const int kEagerControlPlaneCap = 3;

/// Bare machine uuids the app should hold live control planes for right now,
/// without waiting for a selection or a drawer expand: the most recently
/// connected machines from the reconnect list, capped at
/// [kEagerControlPlaneCap]. Always empty when
/// [eagerControlPlanesEnabledProvider] is off (desktop).
///
/// Derived from recents (not `/account/agents`): a recent row proves this
/// device actually used the machine and pins offline-capable coordinates,
/// whereas an inventory-only machine was never connected from here and doesn't
/// justify an unprompted socket.
final eagerControlPlaneTargetsProvider = Provider<Set<String>>((ref) {
  if (!ref.watch(eagerControlPlanesEnabledProvider)) return const {};
  // Watched through a select() on a joined key, not the Set itself: recents
  // rewrite on every successful connect (the lastConnectedAt upsert), and a
  // freshly built Set never compares == to the last one, so without a
  // value-equal cutoff every connect would ripple a no-op rebuild through the
  // alive set into the reaper's reconcile. uuids never contain '\n'.
  final key = ref.watch(
    recentAgentsProvider.select(
      (rows) => (eagerControlPlaneTargets(rows).toList()..sort()).join('\n'),
    ),
  );
  return key.isEmpty ? const {} : key.split('\n').toSet();
});

/// Pure derivation behind [eagerControlPlaneTargetsProvider]. Dedupes to bare
/// machine uuids BEFORE applying [cap], so a machine remembered under both its
/// bare uuid and a legacy compound `<uuid>.<projectId>` row spends one slot.
Set<String> eagerControlPlaneTargets(
  List<RecentAgent> recents, {
  int cap = kEagerControlPlaneCap,
}) {
  final sorted = [...recents]
    ..sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
  final out = <String>{};
  for (final r in sorted) {
    out.add(baseDeviceUuid(r.agentDeviceId));
    if (out.length >= cap) break;
  }
  return out;
}
