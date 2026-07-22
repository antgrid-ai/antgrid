/// Wire codes the relay sends in an `ErrorMessage` when license verification
/// fails on `register` (M4), or when the register frame's license-shape is
/// itself invalid (agent missing token, app sending one). The relay sends one
/// of these as JSON, then closes the WebSocket with code 1008. The Dart
/// `WebSocketChannel` doesn't surface close codes through `onDone`/`onError`
/// reliably, so the app routes off the `ErrorMessage` instead.
///
/// All codes here are treated as fatal by the client: the relay-service marks
/// the disconnect as intentional and stops auto-reconnecting. `LICENSE_REQUIRED`
/// and `UNEXPECTED_LICENSE` indicate a config/code bug (not a transient
/// failure) and won't resolve by retrying.
///
/// This is the FATAL set, not the LICENSE_* set — `LICENSE_UNAVAILABLE` is
/// deliberately absent. It reports that the relay could not reach the license
/// service, so retrying is exactly right; it falls through to the generic
/// error path, which keeps reconnecting.
enum RelayLicenseErrorCode {
  licenseInvalid('LICENSE_INVALID'),
  licenseExpired('LICENSE_EXPIRED'),
  licenseRevoked('LICENSE_REVOKED'),
  licenseRequired('LICENSE_REQUIRED'),
  unexpectedLicense('UNEXPECTED_LICENSE'),
  deviceHardwareMismatch('DEVICE_HARDWARE_MISMATCH');

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
