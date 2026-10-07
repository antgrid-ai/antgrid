import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'bounded_http_request.dart';

/// Thrown when the web rejects our client credentials with 401 or
/// 400 `invalid_client`. Caller (the provisioning hook) should clear the
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
    this.requestTimeout = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now;

  final String licenseApiUrl;
  final String clientId;
  final String clientSecret;
  final http.Client _http;
  final Duration requestTimeout;
  final DateTime Function() _now;

  _CachedToken? _cached;
  Future<String>? _minting;
  ({Object error, StackTrace stack, DateTime retryAt})? _renewalFailure;
  int _renewalAttempts = 0;
  bool _revoked = false;

  String _basicAuth() {
    return 'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}';
  }

  String _base() => licenseApiUrl.replaceAll(RegExp(r'/+$'), '');

  /// Mint a fresh token and cache it. Returns the new `access_token`.
  ///
  /// Throws [DeviceRevokedException] on rejected client credentials, or a plain
  /// `Exception` on other transport/server failures.
  Future<String> mint() async {
    if (_revoked) throw const DeviceRevokedException();
    final base = _base();
    final res = await boundedHttpRequest(
      _http,
      'POST',
      Uri.parse('$base/api/auth/oauth2/token'),
      headers: {
        'authorization': _basicAuth(),
        'content-type': 'application/x-www-form-urlencoded',
      },
      bodyFields: {
        'grant_type': 'client_credentials',
        'scope': 'agent',
        'resource': '$base/api/auth',
      },
      timeout: requestTimeout,
    );
    if (_revoked) throw const DeviceRevokedException();
    if (res.statusCode == 401 ||
        (res.statusCode == 400 && _isInvalidClient(res.body))) {
      _revoked = true;
      _cached = null;
      throw const DeviceRevokedException();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final retrySeconds = int.tryParse(
        res.headers['x-retry-after'] ?? res.headers['retry-after'] ?? '',
      );
      throw _TokenRequestException(
        'oauth: token endpoint returned ${res.statusCode}: '
        '${res.body.substring(0, res.body.length.clamp(0, 200))}',
        retryAfter:
            (res.statusCode == 429 || res.statusCode == 503) &&
                retrySeconds != null &&
                retrySeconds > 0
            ? Duration(seconds: retrySeconds)
            : null,
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final token = body['access_token'] as String?;
    final expiresIn = body['expires_in'];
    if (token == null || expiresIn is! int) {
      throw Exception('oauth: malformed token response (no access_token)');
    }
    final issuedAt = _now();
    final lifetime = Duration(seconds: expiresIn);
    _cached = _CachedToken(
      token,
      refreshAt: issuedAt.add(lifetime * 0.8),
      expiresAt: issuedAt.add(lifetime),
    );
    _renewalFailure = null;
    _renewalAttempts = 0;
    return token;
  }

  /// The cached token until 80% of its lifetime, then a fresh one; concurrent
  /// callers share a single mint, and a failed renewal falls back to the
  /// cached token while it is unexpired. Failed renewals back off independently
  /// of lease polling, honoring longer server retry delays.
  ///
  /// For callers on a timer: lease polling must not mint at its own frequency.
  Future<String> token() async {
    if (_revoked) throw const DeviceRevokedException();
    final cached = _cached;
    if (cached != null && _now().isBefore(cached.refreshAt)) {
      cached.reused = true;
      return cached.value;
    }
    try {
      final failure = _renewalFailure;
      if (failure != null && _now().isBefore(failure.retryAt)) {
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
      return await (_minting ??= _renewToken().whenComplete(
        () => _minting = null,
      ));
    } on DeviceRevokedException {
      rethrow;
    } catch (_) {
      final fallback = _cached;
      if (fallback == null || !_now().isBefore(fallback.expiresAt)) rethrow;
      fallback.reused = true;
      return fallback.value;
    }
  }

  Future<String> _renewToken() async {
    try {
      return await mint();
    } on DeviceRevokedException {
      rethrow;
    } catch (error, stack) {
      _renewalAttempts = (_renewalAttempts + 1).clamp(1, 4);
      // Older servers reset their OAuth bucket after 60 seconds of silence.
      // Leave a margin so lease polling cannot keep it occupied after failure.
      var delay = Duration(
        seconds: (65 * (1 << (_renewalAttempts - 1))).clamp(65, 300),
      );
      if (error is _TokenRequestException) {
        final retryAfter = error.retryAfter;
        if (retryAfter != null && retryAfter > delay) delay = retryAfter;
      }
      _renewalFailure = (
        error: error,
        stack: stack,
        retryAt: _now().add(delay),
      );
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Forgets [rejected] if it is still the cached token, so the next [token]
  /// mints; a different cached token is kept.
  ///
  /// Returns false when [rejected] was never reused from the cache: the
  /// server refusing a token it has just issued is a verdict on the device,
  /// which another fresh token would only repeat.
  bool discard(String rejected) {
    final cached = _cached;
    if (cached == null || cached.value != rejected) return true;
    _cached = null;
    return cached.reused;
  }

  /// The cached token, or `null` before a successful [mint] or after a
  /// [discard].
  String? getToken() => _cached?.value;

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

  /// Cancel any pending refresh; the cached token stays readable through
  /// [getToken].
  void stop() {
    _stopped = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _scheduleRefresh() {
    if (_stopped) return;
    final expiresAt = _cached?.expiresAt;
    if (expiresAt == null) return;
    final ttl = expiresAt.difference(_now());
    // For short-TTL test scenarios use raw 80%; for production-scale TTLs
    // (>=60s) honor a 60s floor.
    // The wall clock can advance past expiry before scheduling resumes.
    final refreshMs = (ttl.inMilliseconds * 0.8).floor().clamp(0, 1 << 30);
    final refreshIn = ttl.inSeconds < 60
        ? Duration(milliseconds: refreshMs)
        : Duration(milliseconds: refreshMs.clamp(60 * 1000, 1 << 30));
    _refreshTimer = Timer(refreshIn, _refresh);
  }

  Future<void> _refresh() async {
    if (_stopped) return;
    try {
      await mint();
    } catch (_) {
      // Retry in 30s on transient failures.
      if (!_stopped) {
        _refreshTimer = Timer(const Duration(seconds: 30), _refresh);
      }
      return;
    }
    _scheduleRefresh();
  }
}

bool _isInvalidClient(String response) {
  try {
    final body = jsonDecode(response);
    return body is Map<String, dynamic> && body['error'] == 'invalid_client';
  } on FormatException {
    return false;
  }
}

final class _TokenRequestException implements Exception {
  const _TokenRequestException(this.message, {this.retryAfter});

  final String message;
  final Duration? retryAfter;

  @override
  String toString() => 'Exception: $message';
}

final class _CachedToken {
  _CachedToken(this.value, {required this.refreshAt, required this.expiresAt});

  final String value;
  final DateTime refreshAt;
  final DateTime expiresAt;
  bool reused = false;
}
