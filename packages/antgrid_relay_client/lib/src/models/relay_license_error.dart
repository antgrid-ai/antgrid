/// Fatal license-verdict codes sent in a relay `ErrorMessage`.
///
/// `LICENSE_UNAVAILABLE` is deliberately absent: it means verification
/// infrastructure is unreachable, so retrying is appropriate.
enum RelayLicenseErrorCode {
  licenseInvalid('LICENSE_INVALID'),
  licenseExpired('LICENSE_EXPIRED'),
  licenseRevoked('LICENSE_REVOKED'),
  licenseRequired('LICENSE_REQUIRED');

  final String wireValue;
  const RelayLicenseErrorCode(this.wireValue);

  /// Returns the matching enum value for a wire code, or null if `code` is
  /// null or unrecognized.
  static RelayLicenseErrorCode? fromWire(String? code) {
    if (code == null) return null;
    for (final c in RelayLicenseErrorCode.values) {
      if (c.wireValue == code) return c;
    }
    return null;
  }
}
