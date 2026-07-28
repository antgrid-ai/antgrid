/// Ladder rungs, lowest first. streamsBound/hydrated stay OUTSIDE the
/// supervisor (StreamTransport + the tier-2/3 hydrate contract own them).
enum ConnRung { wanted, coords, socket, routable, established }

/// Why the supervisor stopped climbing on its own.
///
/// A block is sticky: only the input named on the reason clears it. Anything
/// else — including a fresh `evaluate()` — is a no-op, which is what keeps a
/// terminal condition from being retried in a hot loop.
enum BlockReason {
  licenseExpired, // unblocks: noteFreshToken()
  agentOffline, // unblocks: notePresence(true) or noteCoordsChanged()
  sessionTakenOver, // unblocks: retry() only (prevents two-device ping-pong)
  superseded, // unblocks: retry()
  deviceRevoked, // unblocks: retry() (after re-provision)
  handshakeFailing, // unblocks: retry() or notePresence(true)
}

/// Statuses carry value equality so the supervisor can suppress duplicate
/// emissions on its status stream — a level-triggered engine re-derives the
/// same status constantly, and the UI must not rebuild for every re-derivation.
sealed class SupervisorStatus {
  const SupervisorStatus();
}

class Climbing extends SupervisorStatus {
  const Climbing(this.rung);

  /// Highest rung currently satisfied — the one BELOW the rung being worked on.
  final ConnRung rung;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Climbing && other.rung == rung);

  @override
  int get hashCode => Object.hash(Climbing, rung);

  @override
  String toString() => 'Climbing(${rung.name})';
}

class Connected extends SupervisorStatus {
  const Connected();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Connected;

  @override
  int get hashCode => (Connected).hashCode;

  @override
  String toString() => 'Connected()';
}

class Blocked extends SupervisorStatus {
  const Blocked(this.reason);

  final BlockReason reason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Blocked && other.reason == reason);

  @override
  int get hashCode => Object.hash(Blocked, reason);

  @override
  String toString() => 'Blocked(${reason.name})';
}

/// `wanted == false` — everything torn down on purpose.
class Released extends SupervisorStatus {
  const Released();

  @override
  bool operator ==(Object other) => identical(this, other) || other is Released;

  @override
  int get hashCode => (Released).hashCode;

  @override
  String toString() => 'Released()';
}
