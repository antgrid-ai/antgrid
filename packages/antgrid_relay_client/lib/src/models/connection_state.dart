/// Phases of the machine socket itself, ordered cold → live. Consumers compare
/// by `index`, so the order is load-bearing. Admission is account trust: there
/// is no pairing rung, and `authenticated` (the relay answered `welcome`) is the
/// terminal state — agent presence is reported separately, on
/// `RelayService.peerPresenceStream`.
enum RelayConnectionState {
  disconnected,
  connecting,
  authenticating,
  authenticated,
}

/// Sentinel value used in [AppState.copyWith] to explicitly clear a field.
const _cleared = '_@@CLEARED@@_';

class AppState {
  final RelayConnectionState connectionState;

  /// The wire `code` from the most recent relay `ErrorMessage`, if any
  /// (e.g. `PAIR_TIMEOUT`, `LICENSE_INVALID`). Consumers should match on
  /// this rather than parsing [error] (which is the human "code: message"
  /// concatenation).
  final String? errorCode;
  final String? error;
  final String? peerDeviceId;
  final String? peerName;
  final DateTime? connectedAt;

  const AppState({
    this.connectionState = RelayConnectionState.disconnected,
    this.errorCode,
    this.error,
    this.peerDeviceId,
    this.peerName,
    this.connectedAt,
  });

  /// Creates a copy with the given fields replaced.
  ///
  /// Pass [_cleared] to explicitly set a field to null.
  /// Pass null (the default) to keep the existing value — EXCEPT [errorCode]
  /// and [error], which deliberately auto-clear on any copy: they describe one
  /// failure instant, and every state transition supersedes it. A carried-forward
  /// stale code would keep reading as "the relay just told us why". Callers that
  /// must preserve them across a transition re-pass them explicitly (see
  /// _onDisconnected).
  AppState copyWith({
    RelayConnectionState? connectionState,
    String? errorCode,
    String? error,
    String? peerDeviceId = _cleared,
    String? peerName = _cleared,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
  }) {
    return AppState(
      connectionState: connectionState ?? this.connectionState,
      errorCode: errorCode,
      error: error,
      peerDeviceId: peerDeviceId == _cleared ? this.peerDeviceId : peerDeviceId,
      peerName: peerName == _cleared ? this.peerName : peerName,
      connectedAt: clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
    );
  }
}
