import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cookie_api_client.dart';

enum DeleteAccountResult {
  ok,
  blockedBySubscription,
  blockedByTeam,

  /// Refused for a reason this build does not recognise.
  blocked,
  error,
}

/// [message] is the server's own explanation of a refusal, when it sent one.
/// Shown in preference to the app's wording so the two cannot drift, and so a
/// block newer than this build still says what it is.
typedef DeleteAccountReply = ({DeleteAccountResult result, String? message});

/// Calls the account-deletion endpoint with the stored session cookie.
class AccountApi extends CookieApiClient {
  AccountApi({
    required super.licenseApiUrl,
    required super.cookieProvider,
    super.httpClient,
  });

  Future<DeleteAccountReply> deleteAccount() async {
    const error = (result: DeleteAccountResult.error, message: null);
    final cookie = await cookieProvider();
    if (cookie == null) return error;
    http.Response res;
    try {
      res = await client.delete(
        Uri.parse('$licenseApiUrl/account/me'),
        headers: {'cookie': cookie},
      );
    } catch (_) {
      return error;
    }
    if (res.statusCode == 200) {
      return (result: DeleteAccountResult.ok, message: null);
    }
    if (res.statusCode == 409) return _blockedBy(res.body);
    return error;
  }

  /// The server answers 409 for more than one block (web/src/routes/devices.ts,
  /// `DELETE /account/me`), told apart only by the body's `error` code. An
  /// unrecognised code is not guessed at, since wrong advice sends the user to
  /// clear a block that is not the one in the way; nor is it an error, which
  /// would read as a connection problem that retrying never fixes.
  static DeleteAccountReply _blockedBy(String body) {
    Object? code, message;
    try {
      final json = jsonDecode(body);
      if (json is Map) (code, message) = (json['error'], json['message']);
    } on FormatException {
      // Still a deliberate refusal, just an unreadable one.
    }
    final result = switch (code) {
      'SUBSCRIPTION_ACTIVE' => DeleteAccountResult.blockedBySubscription,
      'TEAM_HAS_MEMBERS' => DeleteAccountResult.blockedByTeam,
      _ => DeleteAccountResult.blocked,
    };
    return (
      result: result,
      message: message is String && message.trim().isNotEmpty
          ? message.trim()
          : null,
    );
  }
}
