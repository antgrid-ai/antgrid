import 'package:http/http.dart' as http;

/// Base for account-service API clients that authenticate by replaying the
/// stored session cookie.
///
/// [cookieProvider] yields the full session cookie `name=value` pair (see
/// AuthStorage), replayed verbatim so the cookie name matches what the server
/// reads back — the `__Secure-`-prefixed name over https; a bare name is
/// silently ignored.
abstract class CookieApiClient {
  CookieApiClient({
    required this.licenseApiUrl,
    required this.cookieProvider,
    http.Client? httpClient,
  }) : client = httpClient ?? http.Client();

  final String licenseApiUrl;
  final Future<String?> Function() cookieProvider;
  final http.Client client;
}
