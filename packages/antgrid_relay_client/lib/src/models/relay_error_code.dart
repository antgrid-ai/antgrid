/// Wire codes for non-license `ErrorMessage`s sent by the relay during
/// pairing/protocol exchanges. License-related codes live in
/// `RelayLicenseErrorCode` because they trigger different client behavior
/// (no auto-reconnect).
enum RelayErrorCode {
  agentOffline('AGENT_OFFLINE'),
  pairRejected('PAIR_REJECTED'),
  unknownPhone('UNKNOWN_PHONE'),
  pairingWindowClosed('PAIRING_WINDOW_CLOSED'),
  nonceMismatch('NONCE_MISMATCH'),
  approvalExpired('APPROVAL_EXPIRED'),
  superseded('SUPERSEDED'),
  peerOffline('PEER_OFFLINE'),
  protocolViolation('PROTOCOL_VIOLATION'),
  expired('EXPIRED'),
  notAuthorized('NOT_AUTHORIZED'),
  peerReplaced('PEER_REPLACED'),
  sessionLimitExceeded('SESSION_LIMIT_EXCEEDED'),
  streamLimitExceeded('STREAM_LIMIT_EXCEEDED');

  final String wireValue;
  const RelayErrorCode(this.wireValue);

  /// Returns the matching enum value for a wire code, or null if `code` is
  /// null or unrecognized.
  static RelayErrorCode? fromWire(String? code) {
    if (code == null) return null;
    for (final c in RelayErrorCode.values) {
      if (c.wireValue == code) return c;
    }
    return null;
  }
}
