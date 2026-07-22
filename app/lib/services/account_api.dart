import 'package:http/http.dart' as http;

import 'cookie_api_client.dart';

enum DeleteAccountResult { ok, blockedBySubscription, error }

/// Calls the account-deletion endpoint with the stored session cookie.
class AccountApi extends CookieApiClient {
  AccountApi({
    required super.licenseApiUrl,
    required super.cookieProvider,
    super.httpClient,
  });

  Future<DeleteAccountResult> deleteAccount() async {
    final cookie = await cookieProvider();
    if (cookie == null) return DeleteAccountResult.error;
    http.Response res;
    try {
      res = await client.delete(
        Uri.parse('$licenseApiUrl/account/me'),
        headers: {'cookie': cookie},
      );
    } catch (_) {
      return DeleteAccountResult.error;
    }
    if (res.statusCode == 200) return DeleteAccountResult.ok;
    if (res.statusCode == 409) return DeleteAccountResult.blockedBySubscription;
    return DeleteAccountResult.error;
  }
}
