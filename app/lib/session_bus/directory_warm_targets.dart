// The other half of the peek-only directory (E13, `docs/session-messaging.md`):
// what a MISS does. The pump only ever asks the peer control planes this app
// already holds, and a desktop at rest holds none, so the ordinary first answer
// to `list_sessions` is "3 machines, none connected, none asked" — honest, and
// thin.
//
// Rather than make that permanent, or hold standing sockets to every machine
// sharing a repo so it can never happen, a read the bridge could not serve
// marks the machines it missed as wanted for a while. Thin once, then real.
// Nothing here pins: an entry expires on its own, so an idle desktop falls back
// to holding nothing without anyone having to remember to release it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show setEquals;

import '../services/account_agents_api.dart' show InventoryAgent;

/// How long one unserved read keeps a machine warm.
///
/// Long enough to cover the retry an agent actually makes — it reads the reach
/// line, sees nobody was asked, and asks again — and short enough that a
/// desktop nobody is asking anything drops back to zero peer sockets. Deliberately
/// longer than the pump's own fast window: the fast window governs how often
/// this app re-ASKS the peers it has, which is worth nothing until there is a
/// peer to ask.
const Duration kDirectoryWarmWindow = Duration(minutes: 5);

/// Ceiling on machines warmed by one miss. Each is a persistent WebSocket plus
/// an E2E session, the same cost `kEagerControlPlaneCap` bounds on mobile — and
/// desktop is lazy precisely because connecting to everything at once has
/// already caused connection storms here (see `eagerControlPlanesEnabledProvider`).
/// A miss is evidence that SOME peer was wanted, never evidence that all of them
/// were.
const int kDirectoryWarmCap = 3;

/// The account machines a read just missed: everything in [inventory] that is
/// neither this machine nor already open, most recently seen first, capped.
///
/// Most-recently-seen first because nothing here can tell which machine holds
/// the repo the read asked about — that is exactly what the read would have to
/// connect to find out — so recency is the only ranking available, and it is
/// the same one the picker already trusts.
Set<String> directoryWarmCandidates(
  Iterable<InventoryAgent> inventory,
  String? localUuid,
  Iterable<String> openIds, {
  int cap = kDirectoryWarmCap,
}) {
  final open = openIds.toSet();
  final missed = [
    for (final a in inventory)
      if (a.deviceUuid != localUuid && !open.contains(a.deviceUuid)) a,
  ];
  // Nulls last: a machine the account has never seen connect is the weakest
  // candidate, not the strongest, and `DateTime` cannot sort a null itself.
  missed.sort((a, b) {
    final at = a.lastSeenAt;
    final bt = b.lastSeenAt;
    if (at == null && bt == null) return 0;
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  });
  return {for (final a in missed.take(cap)) a.deviceUuid};
}

/// Machines to hold a control plane open for because a directory read missed
/// them, each until its own deadline.
///
/// Unioned into `controlPlaneAliveTargetsProvider` so the reaper leaves them
/// alone while they are warm — being in that set is what keeps a socket, but it
/// does not open one, so [RemoteDirectoryPumpHost] dials what it warms.
class DirectoryWarmTargets extends Notifier<Set<String>> {
  final Map<String, DateTime> _until = {};

  @override
  Set<String> build() => const {};

  /// Warm [uuids] until [now] + [kDirectoryWarmWindow], extending any that are
  /// already warm. A machine asked about again keeps its socket rather than
  /// losing it mid-conversation.
  void warm(Iterable<String> uuids, DateTime now) {
    final deadline = now.add(kDirectoryWarmWindow);
    for (final uuid in uuids) {
      _until[uuid] = deadline;
    }
    _emit();
  }

  /// Drop whatever has expired. Called on the pump's own tick rather than by a
  /// timer of its own — an expiry nobody is polling for changes nothing anyone
  /// can observe.
  void prune(DateTime now) {
    _until.removeWhere((_, until) => !now.isBefore(until));
    _emit();
  }

  void _emit() {
    final next = _until.keys.toSet();
    // A fresh Set is never `==` to the last one, and this feeds a provider whose
    // fan-in has crashed a frame before (see `controlPlaneAliveTargetsProvider`),
    // so an unchanged membership must not notify.
    if (setEquals(next, state)) return;
    state = next;
  }
}

final directoryWarmTargetsProvider =
    NotifierProvider<DirectoryWarmTargets, Set<String>>(
      DirectoryWarmTargets.new,
    );
