import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';

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

  /// The address of the machine on the far side of the link.
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

/// Every link this app can carry, right now — empty until the machine-level
/// directory (`docs/session-messaging.md` §5.4) gives it a source.
///
/// A session no longer records who else is in it, so there is nothing left on
/// a local row to derive a link from. The type stays because the carrier and
/// the warm-project pin are both written against it and must keep deriving
/// from ONE unit, and because dropping out of this list is still the only
/// unpin there is — a second source would be a second answer.
///
/// While this is empty the carrier attaches no legs, so a frame addressed to
/// another machine has no route out of this app.
final sessionBusLinksProvider = Provider<SessionBusLinks>(
  (ref) => SessionBusLinks.empty,
);
