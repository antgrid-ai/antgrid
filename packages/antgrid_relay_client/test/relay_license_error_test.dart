import 'package:test/test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

void main() {
  group('RelayLicenseErrorCode.fromWire', () {
    test('parses each known wire code', () {
      expect(
        RelayLicenseErrorCode.fromWire('LICENSE_INVALID'),
        RelayLicenseErrorCode.licenseInvalid,
      );
      expect(
        RelayLicenseErrorCode.fromWire('LICENSE_EXPIRED'),
        RelayLicenseErrorCode.licenseExpired,
      );
      expect(
        RelayLicenseErrorCode.fromWire('LICENSE_REVOKED'),
        RelayLicenseErrorCode.licenseRevoked,
      );
      expect(
        RelayLicenseErrorCode.fromWire('LICENSE_REQUIRED'),
        RelayLicenseErrorCode.licenseRequired,
      );
      expect(
        RelayLicenseErrorCode.fromWire('UNEXPECTED_LICENSE'),
        RelayLicenseErrorCode.unexpectedLicense,
      );
      expect(
        RelayLicenseErrorCode.fromWire('DEVICE_HARDWARE_MISMATCH'),
        RelayLicenseErrorCode.deviceHardwareMismatch,
      );
    });

    test('returns null for unknown / null input', () {
      expect(RelayLicenseErrorCode.fromWire('UNKNOWN'), isNull);
      expect(RelayLicenseErrorCode.fromWire(null), isNull);
      expect(RelayLicenseErrorCode.fromWire(''), isNull);
    });

    test('LICENSE_UNAVAILABLE is NOT in the fatal set', () {
      // This enum is the fatal set, and RelayService flips
      // `_intentionalDisconnect` for anything it matches. LICENSE_UNAVAILABLE
      // means the relay couldn't reach the license service to check — adding it
      // here would strand every phone through a transient web outage.
      expect(RelayLicenseErrorCode.fromWire('LICENSE_UNAVAILABLE'), isNull);
    });

    test('round-trips via wireValue', () {
      for (final c in RelayLicenseErrorCode.values) {
        expect(RelayLicenseErrorCode.fromWire(c.wireValue), c);
      }
    });
  });
}
