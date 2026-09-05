/// Pure wire vocabulary and routing decision for the session bus.
///
/// No Riverpod, no transports: everything here is a function of one frame plus
/// the membership facts the carrier already holds, so the whole routing rule is
/// unit-testable without a socket. `SessionBusCarrier` is the only caller.
library;

/// The seven agent<->agent frame types (`SessionBus*Wire` in
/// `bridge/src/protocol.ts`). Mirrored BY HAND, like every other wire set the
/// app shares with the bridge; adding a type on one side only is silent.
const Set<String> kSessionBusTypes = <String>{
  'session-bus:assign',
  'session-bus:transition',
  'session-bus:cancel',
  'session-bus:message',
  'session-bus:fetch',
  'session-bus:fetch:result',
  'session-bus:ack',
};

bool isSessionBusFrame(Map<String, dynamic> json) =>
    kSessionBusTypes.contains(json['type']);

/// One end of a bus frame: the `from`/`to` member key every type carries
/// (`SessionBusBaseWire`).
class BusEndpoint {
  const BusEndpoint({
    required this.machineId,
    required this.projectId,
    required this.sessionId,
  });

  final String machineId;
  final String projectId;
  final String sessionId;

  /// The transport family key for the machine+project half of this endpoint —
  /// `agentTransportForProvider`'s compound id, which is how the carrier finds
  /// the relay stream a peer-addressed frame belongs on.
  String get registrationId => '$machineId.$projectId';

  /// Identity across all three ids. Deliberately the same spelling as
  /// `SessionMemberRef.key` (`app/lib/models/session_entry.dart`) so a frame's
  /// endpoint and a session's member record compare as strings without either
  /// side reconstructing the other.
  String get key => '$machineId/$projectId/$sessionId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BusEndpoint &&
          other.machineId == machineId &&
          other.projectId == projectId &&
          other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(machineId, projectId, sessionId);

  @override
  String toString() => 'BusEndpoint($key)';
}

/// Identity of a LEAD session as the carrier keys it: project + session, no
/// machine. A lead frame arrives on that project's loopback transport, which
/// can only belong to that project's own bridge, so the machine id in the frame
/// adds nothing an app could independently verify — while requiring it would
/// make delivery depend on the app and its co-located bridge agreeing on a uuid
/// neither derives from the other.
String busLeadKey(String projectId, String sessionId) =>
    '$projectId/$sessionId';

BusEndpoint? _endpoint(Object? raw) {
  if (raw is! Map) return null;
  final machineId = raw['machineId'];
  final projectId = raw['projectId'];
  final sessionId = raw['sessionId'];
  if (machineId is! String || machineId.isEmpty) return null;
  if (projectId is! String || projectId.isEmpty) return null;
  if (sessionId is! String || sessionId.isEmpty) return null;
  return BusEndpoint(
    machineId: machineId,
    projectId: projectId,
    sessionId: sessionId,
  );
}

BusEndpoint? busFrom(Map<String, dynamic> json) => _endpoint(json['from']);
BusEndpoint? busTo(Map<String, dynamic> json) => _endpoint(json['to']);

/// What the carrier does with one frame.
enum BusForward {
  /// Send verbatim on the addressed member's relay stream.
  toPeer,

  /// Send verbatim on the addressed lead project's loopback transport.
  toLead,

  /// Drop it. Counted and logged, never thrown: a refusal is a frame the app
  /// has no membership for, which a stale link or a racing release produces
  /// routinely.
  refuse,
}

/// The routing decision for one frame, given which leg delivered it.
///
/// Both endpoints are checked in both directions, and the caller narrows the
/// two allowed sets to the delivering transport — so a frame arriving on lead
/// project A's loopback can only ever reach a member OF A, and a frame arriving
/// on peer P's stream can only ever reach a lead that P is a member of.
///
/// [localMachineId] is checked only against a peer's `to` (the memo's rule: a
/// frame addressed to another machine is not ours to hand to a local bridge).
/// A null value skips that one check rather than refusing everything: the
/// project+session halves of `to` still have to name a lead this app carries,
/// which is the substantive guard, and a carrier whose own device uuid has not
/// resolved yet must not be a carrier that silently drops every reply.
BusForward classifyBusFrame({
  required Map<String, dynamic> json,
  required bool fromLead,
  required String? localMachineId,
  required Set<String> allowedPeerKeys,
  required Set<String> allowedLeadKeys,
}) {
  if (!isSessionBusFrame(json)) return BusForward.refuse;
  final from = busFrom(json);
  final to = busTo(json);
  if (from == null || to == null) return BusForward.refuse;

  if (fromLead) {
    if (!allowedLeadKeys.contains(busLeadKey(from.projectId, from.sessionId))) {
      return BusForward.refuse;
    }
    if (!allowedPeerKeys.contains(to.key)) return BusForward.refuse;
    return BusForward.toPeer;
  }

  if (localMachineId != null && to.machineId != localMachineId) {
    return BusForward.refuse;
  }
  if (!allowedLeadKeys.contains(busLeadKey(to.projectId, to.sessionId))) {
    return BusForward.refuse;
  }
  if (!allowedPeerKeys.contains(from.key)) return BusForward.refuse;
  return BusForward.toLead;
}
