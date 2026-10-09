import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cookie_api_client.dart';

enum DeleteAccountResult { ok, blockedBySubscription, blockedByTeam, error }

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
    if (res.statusCode == 409) return _blockedBy(res.body);
    return DeleteAccountResult.error;
  }

  /// The server answers 409 for more than one block (web/src/routes/devices.ts,
  /// `DELETE /account/me`), told apart only by the body's `error` code. An
  /// unrecognised code is an error rather than a guess: wrong advice sends the
  /// user to cancel a subscription that is not what stands in the way.
  static DeleteAccountResult _blockedBy(String body) {
    Object? code;
    try {
      final json = jsonDecode(body);
      if (json is Map) code = json['error'];
    } on FormatException {
      return DeleteAccountResult.error;
    }
    return switch (code) {
      'SUBSCRIPTION_ACTIVE' => DeleteAccountResult.blockedBySubscription,
      'TEAM_HAS_MEMBERS' => DeleteAccountResult.blockedByTeam,
      _ => DeleteAccountResult.error,
    };
  }
}
