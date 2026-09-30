import 'package:antgrid/services/license_token_minter.dart';

class TestLicenseTokenMinter extends LicenseTokenMinter {
  TestLicenseTokenMinter()
    : super(
        licenseApiUrl: 'https://unused.invalid',
        clientId: 'test',
        clientSecret: 'test',
      );

  @override
  Future<String> mint() async => 'test-token';
}
