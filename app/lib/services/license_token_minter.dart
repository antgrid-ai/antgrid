import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thrown when the web rejects our client credentials with 401
/// `invalid_client`. Caller (the provisioning hook) should clear the
/// keychain so the next sign-in re-provisions.
class DeviceRevokedException implements Exception {
  const DeviceRevokedException();
  @override
  String toString() =>
      'DeviceRevokedException: device revoked or client deleted';
}

/// Thin OAuth `client_credentials` minter. Mirrors `bridge/src/auth/oauth-client.ts`.
///
/// In-memory only: the minter does NOT persist tokens — the
/// `clientId`/`clientSecret` it was constructed with live in the keychain
/// via `KeychainDeviceStore`.
class LicenseTokenMinter {
  LicenseTokenMinter({
    required this.licenseApiUrl,
    required this.clientId,
    required this.clientSecret,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String licenseApiUrl;
  final String clientId;
  final String clientSecret;
  final http.Client _http;

  String? _current;
  DateTime? _expiresAt;

  String _basicAuth() {
    return 'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}';
  }

  String _base() => licenseApiUrl.replaceAll(RegExp(r'/+$'), '');

  /// Mint a fresh token and cache it. Returns the new `access_token`.
  ///
  /// Throws [DeviceRevokedException] on 401 (device revoked), or a plain
  /// `Exception` on other transport/server failures.
  Future<String> mint() async {
    final base = _base();
    final res = await _http.post(
      Uri.parse('$base/api/auth/oauth2/token'),
      headers: {
        'authorization': _basicAuth(),
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type': 'client_credentials',
        'scope': 'agent',
        'resource': '$base/api/auth',
      },
    );
    if (res.statusCode == 401) {
      throw const DeviceRevokedException();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        'oauth: token endpoint returned ${res.statusCode}: '
        '${res.body.substring(0, res.body.length.clamp(0, 200))}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final token = body['access_token'] as String?;
    final expiresIn = body['expires_in'];
    if (token == null || expiresIn is! int) {
      throw Exception('oauth: malformed token response (no access_token)');
    }
    _current = token;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    return token;
  }

  /// Sync accessor — returns the most recently minted token, or `null` if
  /// `mint()` has not yet succeeded.
  String? getToken() => _current;

  Timer? _refreshTimer;
  bool _stopped = false;

  /// Mint once, then schedule re-mints at 80% of each token's TTL.
  /// Safe to call multiple times — subsequent calls are no-ops until [stop].
  Future<void> start() async {
    if (_refreshTimer != null) return;
    _stopped = false;
    await mint();
    _scheduleRefresh();
  }

  /// Cancel any pending refresh. The most recent token remains cached
  /// (accessible via [getToken]) until it expires server-side.
  void stop() {
    _stopped = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _scheduleRefresh() {
    if (_stopped) return;
    final expiresAt = _expiresAt;
    if (expiresAt == null) return;
    final ttl = expiresAt.difference(DateTime.now());
    // For short-TTL test scenarios use raw 80%; for production-scale TTLs
    // (>=60s) honor a 60s floor.
    // Clamp at 0 so a stale `_expiresAt` (e.g. when a retry inherits the
    // previous token's expiry after mint() threw) never produces a negative
    // Duration that fires next-tick and undercuts the 30s retry backoff.
    final refreshMs = (ttl.inMilliseconds * 0.8).floor().clamp(0, 1 << 30);
    final refreshIn = ttl.inSeconds < 60
        ? Duration(milliseconds: refreshMs)
        : Duration(milliseconds: refreshMs.clamp(60 * 1000, 1 << 30));
    _refreshTimer = Timer(refreshIn, () async {
      if (_stopped) return;
      try {
        await mint();
      } catch (_) {
        // Retry in 30s on transient failures.
        if (!_stopped) {
          _refreshTimer = Timer(const Duration(seconds: 30), _scheduleRefresh);
        }
        return;
      }
      _scheduleRefresh();
    });
  }
}
