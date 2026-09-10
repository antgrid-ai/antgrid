import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/cached_sessions.dart';

/// One peer this app carries for: the machine+project half of a bus address,
/// which is all a relay stream is keyed on.
///
/// A session id is deliberately absent. Legs are per machine+project — one
/// stream carries every session in that project — and holding a session here
/// would make the same leg appear once per conversation.
@immutable
class SessionBusLink {
  const SessionBusLink({required this.machineId, required this.projectId});

  final String machineId;

  /// The project id the SENDING bridge used to address this peer. A label to
  /// this app and a transport key to the relay, never an identity: one checkout
  /// can be open as more than one project, so two machines can legitimately
  /// hold different ids for the same tree.
  final String projectId;

  /// `agentTransportForProvider`'s compound key for the peer's project.
  String get registrationId => '$machineId.$projectId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionBusLink &&
          other.machineId == machineId &&
          other.projectId == projectId;

  @override
  int get hashCode => Object.hash(machineId, projectId);

  @override
  String toString() => 'SessionBusLink($registrationId)';
}

/// Value-equal snapshot of every leg this app is holding open.
///
/// The equality is the point, not tidiness: `controlPlaneAliveTargetsProvider`
/// — whose fan-in has already produced a "rebuilt multiple times in the same
/// frame" crash once — is on the other end of it, and ordinary bus traffic
/// rewrites this on every frame of a busy exchange. A fresh non-equal object per
/// frame would reproduce that crash at runtime, where nothing type-checks it.
@immutable
class SessionBusLinks {
  const SessionBusLinks(this.links);

  static const SessionBusLinks empty = SessionBusLinks(<SessionBusLink>[]);

  final List<SessionBusLink> links;

  bool get isEmpty => links.isEmpty;
  bool get isNotEmpty => links.isNotEmpty;
  int get length => links.length;

  /// Bare device uuids of every machine on the far side of a leg.
  Set<String> get peerMachineIds => {for (final l in links) l.machineId};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionBusLinks && listEquals(other.links, links);

  @override
  int get hashCode => Object.hashAll(links);
}

/// How long a peer leg outlives the last frame carried over it.
///
/// Long enough to cover a turn the other agent is spending on the answer, short
/// enough that a desktop nobody is exchanging anything on falls back to holding
/// no peer sockets at all. Idle expiry is the whole release mechanism: nothing
/// tells this app an exchange is over, so a leg that is never used again must
/// let go by itself.
const Duration kSessionBusLinkIdle = Duration(minutes: 5);

/// The most peers this app will hold demand for at once.
///
/// Demand is written from the ADDRESS on a frame, and a connected peer chooses
/// what it puts there — so without a ceiling one peer can mint an entry per
/// invented machine+project, each of which becomes a relay dial and a PIN on
/// the session registry. A pinned bucket is exempt from `relayCap`
/// (`registry_lru_test.dart` pins that behaviour), so the growth is unbounded
/// in the one place nothing else would stop it. Well above any real fan-out:
/// this is a backstop, not a working limit, and a machine exchanging with more
/// peers than this at once is already the shape E13 refused.
const int kSessionBusMaxLinks = 24;

/// The idle window the demand actually uses, as a provider so a test can shrink
/// it — the real one is minutes long.
final sessionBusLinkIdleProvider = Provider<Duration>(
  (ref) => kSessionBusLinkIdle,
);

/// The session ids one local project carries, for the inbound leg match.
///
/// A seam over the session cache rather than a direct read, so the carrier's
/// routing can be exercised without standing up the whole store. The cache is
/// the right source: it write-throughs for exactly the WARM local projects a
/// loopback leg can exist for.
final sessionBusLocalSessionsProvider = Provider.family<Set<String>, String>((
  ref,
  projectId,
) {
  return {for (final s in ref.watch(cachedSessionsProvider(projectId))) s.id};
});

/// Every peer this app is carrying for, derived from ADDRESSING.
///
/// A leg is asked for when a local bridge hands over a frame naming a machine
/// and project this app has no leg for, and released when nothing has been
/// carried over it for [kSessionBusLinkIdle]. Discovery stays peek-only and
/// separate: E13 (`docs/session-messaging.md` §14) refuses pinning peers by
/// shared repo key precisely because it would hold standing connections on an
/// idle desktop to keep fresh an answer nobody asked for. Demand cannot do
/// that — a leg exists only after an agent has actually addressed one.
class SessionBusLinkDemand extends Notifier<SessionBusLinks> {
  final Map<String, ({SessionBusLink link, DateTime until})> _wanted = {};
  Timer? _sweep;

  @override
  SessionBusLinks build() {
    ref.onDispose(() {
      _sweep?.cancel();
      _sweep = null;
    });
    return SessionBusLinks.empty;
  }

  /// Records that a frame named [machineId]/[projectId], extending its window.
  void reach(String machineId, String projectId) {
    final link = SessionBusLink(machineId: machineId, projectId: projectId);
    final idle = ref.read(sessionBusLinkIdleProvider);
    // Assigning into an existing key keeps its insertion position, so a refresh
    // leaves the emitted list order alone — order is part of the equality.
    _wanted[link.registrationId] = (
      link: link,
      until: DateTime.now().add(idle),
    );
    _evictOverCap();
    _arm(idle);
    _emit();
  }

  /// Drops the coldest entries once over [kSessionBusMaxLinks].
  ///
  /// Coldest by deadline, so what goes is whatever has been quiet longest — an
  /// exchange in flight refreshed its own deadline on the frame that got here.
  /// A flood of invented addresses therefore evicts itself before it can reach
  /// a leg a real conversation is using.
  void _evictOverCap() {
    if (_wanted.length <= kSessionBusMaxLinks) return;
    final coldestFirst = _wanted.entries.toList()
      ..sort((a, b) => a.value.until.compareTo(b.value.until));
    for (final e in coldestFirst.take(_wanted.length - kSessionBusMaxLinks)) {
      _wanted.remove(e.key);
    }
  }

  /// Drops whatever has gone quiet. Public so the sweep is drivable from a test
  /// without waiting out a real window.
  void prune() {
    final now = DateTime.now();
    _wanted.removeWhere((_, e) => !now.isBefore(e.until));
    _emit();
  }

  /// One pending sweep at a time, re-armed only while something is still held.
  ///
  /// A refresh does NOT reschedule, so a leg can outlive its window by up to
  /// one more of them. That is the cheap direction to be wrong in: the cost is
  /// a socket held slightly too long, where a timer per refresh would rearm on
  /// every frame of a busy exchange.
  void _arm(Duration idle) {
    if (_sweep != null) return;
    _sweep = Timer(idle, () {
      _sweep = null;
      prune();
      if (_wanted.isNotEmpty) _arm(idle);
    });
  }

  void _emit() {
    final next = SessionBusLinks([for (final e in _wanted.values) e.link]);
    if (next == state) return;
    state = next;
  }
}

final sessionBusLinksProvider =
    NotifierProvider<SessionBusLinkDemand, SessionBusLinks>(
      SessionBusLinkDemand.new,
    );
