import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/drawer_entry.dart';
import '../models/session_entry.dart';
import '../providers/drawer_entries.dart';
import '../providers/sessions.dart';

/// One live membership: a session led on THIS machine and one machine that is
/// currently part of it. The unit both the carrier's legs and the warm-project
/// pin are derived from, so neither can be right about a membership the other
/// is wrong about.
@immutable
class SessionBusLink {
  const SessionBusLink({
    required this.leadProjectId,
    required this.leadSessionId,
    required this.peer,
  });

  /// A LOCAL project id — also the drawer entry id and the key of the loopback
  /// transport the lead bridge speaks over. A TRANSPORT key, never an identity:
  /// the same checkout can be open as more than one project, so this says how to
  /// reach the lead from this app, not which lead it is. [leadSessionId] is the
  /// identity, and the only half a frame is matched on.
  final String leadProjectId;
  final String leadSessionId;

  /// The member as the lead's own row records it (`SessionEntry.members`).
  final SessionMemberRef peer;

  /// `agentTransportForProvider`'s compound key for the peer's project.
  String get peerRegistrationId => '${peer.machineId}.${peer.projectId}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionBusLink &&
          other.leadProjectId == leadProjectId &&
          other.leadSessionId == leadSessionId &&
          other.peer.machineId == peer.machineId &&
          other.peer.projectId == peer.projectId &&
          other.peer.sessionId == peer.sessionId;

  @override
  int get hashCode => Object.hash(
    leadProjectId,
    leadSessionId,
    peer.machineId,
    peer.projectId,
    peer.sessionId,
  );

  @override
  String toString() =>
      'SessionBusLink($leadProjectId/$leadSessionId -> ${peer.key})';
}

/// Value-equal snapshot of every live link.
///
/// The equality is the point, not tidiness: this is rebuilt by every
/// `session:updated` burst (a name, a `lastUsedAt`, a run-state flip), and
/// `controlPlaneAliveTargetsProvider` — whose fan-in has already produced a
/// "rebuilt multiple times in the same frame" crash once — is on the other end
/// of it. A bare `List` would notify on every one of those; this notifies only
/// when a membership actually appears or disappears.
@immutable
class SessionBusLinks {
  const SessionBusLinks(this.links);

  static const SessionBusLinks empty = SessionBusLinks(<SessionBusLink>[]);

  final List<SessionBusLink> links;

  bool get isEmpty => links.isEmpty;
  bool get isNotEmpty => links.isNotEmpty;
  int get length => links.length;

  /// Bare device uuids of every machine holding an active member.
  Set<String> get peerMachineIds => {for (final l in links) l.peer.machineId};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionBusLinks && listEquals(other.links, links);

  @override
  int get hashCode => Object.hashAll(links);
}

/// Every active membership of a session led on this machine, right now.
///
/// Only LOCAL entries are scanned: a session led on another machine is that
/// machine's app's problem to carry (D7 — the carrier is the lead's desktop),
/// and a peer's own row carries `memberOf`, never `members`, so it produces no
/// link here even when this app can see it.
///
/// Released members drop out with no extra code — `isActive` is false for both
/// `released` and `released-delete-refused`, so every 5.4 removal path unpins
/// and detaches by simply not being in this list any more. That is the ONLY
/// unpin: nothing commands one.
final sessionBusLinksProvider = Provider<SessionBusLinks>((ref) {
  final entries = ref.watch(drawerEntriesProvider);
  final links = <SessionBusLink>[];
  for (final entry in entries) {
    if (entry.kind != EntryKind.local) continue;
    for (final session in ref.watch(sessionsForEntryProvider(entry.id))) {
      for (final member in session.members) {
        if (!member.isActive) continue;
        links.add(
          SessionBusLink(
            leadProjectId: entry.id,
            leadSessionId: session.id,
            peer: member.ref,
          ),
        );
      }
    }
  }
  return SessionBusLinks(List.unmodifiable(links));
});
