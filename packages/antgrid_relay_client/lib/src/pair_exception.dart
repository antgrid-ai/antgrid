/// Thrown when a pairing flow fails. Caller should surface [message] to the
/// user (e.g. via a SnackBar) and may retry when [agentOffline] is set.
///
/// Lives in the relay client (not the Flutter app) so the pure-Dart eval client
/// and the app share one exception type and one notion of "retryable" — the
/// value mirrors the relay error frame's `retryable` verdict.
class PairException implements Exception {
  final String message;

  /// True when the failure is a transient routing miss — the relay's retryable
  /// `AGENT_OFFLINE` (a project core whose relay slot hasn't registered yet) or
  /// a plain network drop before any agent saw the pair-request. The pairing
  /// service re-sends on the SAME still-open socket to ride this out. A genuine
  /// rejection or a terminal close (license errorCode) is NOT marked offline,
  /// so callers don't retry it.
  final bool agentOffline;

  PairException(this.message, {this.agentOffline = false});
  @override
  String toString() => 'PairException: $message';
}
