/// Pure wire vocabulary and routing decision for the session bus.
///
/// No Riverpod, no transports: everything here is a function of one frame plus
/// the facts the carrier already holds, so the whole routing rule is
/// unit-testable without a socket. `SessionBusCarrier` is the only caller.
library;

/// The five agent<->agent frame types (`SessionBus*Wire` in
/// `bridge/src/protocol.ts`). Mirrored BY HAND, like every other wire set the
/// app shares with the bridge; adding a type on one side only is silent — an
/// unmirrored type is dropped by `parseAbMessage` with no log at all.
const Set<String> kSessionBusTypes = <String>{
  'session-bus:post',
  'session-bus:notify',
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
  /// the relay stream a frame leaving this machine belongs on.
  String get registrationId => '$machineId.$projectId';

  /// Identity across all three ids. Deliberately the same spelling as
  /// `addressKey` (`bridge/src/session-bus/address.ts`) so a frame's endpoint
  /// and a bridge's member key compare as strings without either side
  /// reconstructing the other.
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
  /// Out: send verbatim on the relay stream of the addressed machine+project.
  toPeer,

  /// In: send verbatim on the loopback transport of the local project that
  /// carries the addressed session.
  toLocal,

  /// Drop it. Counted and logged, never thrown.
  refuse,
}

/// The decision plus, when it is a refusal, the fact the app did not have.
///
/// The reason travels with the decision because the carrier's warn line is the
/// only record either machine keeps of a frame that went nowhere: the sending
/// bridge is told the frame LEFT the moment its owner socket accepts it, so
/// "refused" with no cause is a dead end for whoever greps for it.
typedef BusRouting = ({BusForward forward, String? because});

/// Where one frame goes, from its own address and nothing else.
///
/// The rule is symmetric and has exactly two clauses. §4.2 leaves the two ends
/// of an exchange symmetric, so a frame is placed by where its target IS and
/// never by which side opened it:
///
///  - `to.machineId` is not this machine — it leaves, on the leg keyed
///    `'${to.machineId}.${to.projectId}'`. Whether that leg exists yet is not
///    asked here: an unlegged peer is what ASKS for a leg (see
///    `sessionBusLinksProvider`), so refusing on it would make the first frame
///    of every exchange the one that cannot be sent.
///  - `to.machineId` is this machine — it lands, on the local leg whose session
///    set holds `to.sessionId`, and never on `to.projectId`. One checkout can
///    be open as more than one project (a managed worktree opened in its own
///    right hashes to an id of its own), so the two machines' project ids for
///    the same session differ routinely and both are right. A session id is a
///    uuid both bridges copy rather than derive, so it is the one part of the
///    address that cannot drift — the bridge matches on the same half and warns
///    about the disagreement (`addressesSameSession` in
///    `bridge/src/session-bus/address.ts`).
///
/// [localMachineId] is null until this app's own device uuid resolves. Rather
/// than refuse everything for that window, the session set decides: a frame for
/// a session a local leg carries lands, and anything else is offered outward,
/// which is where the frame's own `to` says it belongs.
BusRouting classifyBusFrame({
  required Map<String, dynamic> json,
  required String? localMachineId,
  required Set<String> localSessionIds,
}) {
  if (!isSessionBusFrame(json)) {
    return (forward: BusForward.refuse, because: 'not a session-bus frame');
  }
  final from = busFrom(json);
  final to = busTo(json);
  if (from == null) {
    return (forward: BusForward.refuse, because: 'the frame names no sender');
  }
  if (to == null) {
    return (forward: BusForward.refuse, because: 'the frame names no target');
  }

  final carried = localSessionIds.contains(to.sessionId);
  final inbound = localMachineId == null
      ? carried
      : to.machineId == localMachineId;
  if (!inbound) return (forward: BusForward.toPeer, because: null);
  if (!carried) {
    return (
      forward: BusForward.refuse,
      because: 'no open local project carries session ${to.sessionId}',
    );
  }
  return (forward: BusForward.toLocal, because: null);
}
