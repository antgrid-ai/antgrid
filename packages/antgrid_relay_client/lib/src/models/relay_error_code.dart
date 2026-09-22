/// Non-license relay control errors understood by the app.
enum RelayErrorCode {
  authFailed('AUTH_FAILED'),
  maxConnections('MAX_CONNECTIONS'),
  rateLimited('RATE_LIMITED'),
  invalidMessage('INVALID_MESSAGE'),
  notAuthenticated('NOT_AUTHENTICATED'),
  wrongDeviceType('WRONG_DEVICE_TYPE'),
  messageRateLimited('MESSAGE_RATE_LIMITED'),
  licenseUnavailable('LICENSE_UNAVAILABLE'),
  unknownPhone('UNKNOWN_PHONE'),
  nonceMismatch('NONCE_MISMATCH'),
  approvalExpired('APPROVAL_EXPIRED'),
  superseded('SUPERSEDED'),
  protocolViolation('PROTOCOL_VIOLATION');

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
