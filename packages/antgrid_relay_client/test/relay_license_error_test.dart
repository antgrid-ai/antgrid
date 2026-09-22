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
    });

    test('returns null for unknown / null input', () {
      expect(RelayLicenseErrorCode.fromWire('UNKNOWN'), isNull);
      expect(RelayLicenseErrorCode.fromWire(null), isNull);
      expect(RelayLicenseErrorCode.fromWire(''), isNull);
    });

    test('LICENSE_UNAVAILABLE is NOT in the fatal set', () {
      // An infrastructure outage is retryable, not a license verdict.
      expect(RelayLicenseErrorCode.fromWire('LICENSE_UNAVAILABLE'), isNull);
    });

    test('round-trips via wireValue', () {
      for (final c in RelayLicenseErrorCode.values) {
        expect(RelayLicenseErrorCode.fromWire(c.wireValue), c);
      }
    });
  });
}
