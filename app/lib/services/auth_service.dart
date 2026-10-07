import 'dart:async';
import 'package:clock/clock.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'bounded_http_request.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../config/build_info.dart';
import '../config/storage_scope.dart';
import '../util/ab_log.dart';

/// Abstract over secure storage so tests can substitute an in-memory impl.
///
/// The stored value is the FULL session cookie `name=value` pair (e.g.
/// `__Secure-better-auth.session_token=<token>.<sig>`), captured verbatim from
/// the server's `Set-Cookie`. Storing the real name — not just the value — is
/// what lets every replay site send the exact cookie the server reads back,
/// without any client re-deriving Better-Auth's `__Secure-`/`__Host-` prefix
/// rule. See [AuthService._extractSessionCookie].
abstract class AuthStorage {
  Future<String?> readCookie();
  Future<void> writeCookie(String cookie);
  Future<void> clearCookie();

  /// A pending magic-link sign-in, as the JSON written by
  /// [AuthService.startMagicLink]. Distinct from the session cookie: this is a
  /// short-lived ticket for claiming an approval, not proof of a live session.
  Future<String?> readPendingSignIn();
  Future<void> writePendingSignIn(String value);
  Future<void> clearPendingSignIn();
}

class SecureAuthStorage implements AuthStorage {
  // v2 stores the full `name=value` pair (v1 stored the bare value). The bump
  // invalidates any v1 entry so a stale value-only cookie is never replayed as
  // a malformed nameless header — affected users simply re-authenticate once.
  static final _key = scopedStorageKey('antgrid.session_cookie.v2');
  static final _pendingKey = scopedStorageKey('antgrid.pending_signin.v1');
  final FlutterSecureStorage _storage;
  SecureAuthStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> readCookie() => _storage.read(key: _key);
  @override
  Future<void> writeCookie(String cookie) =>
      _storage.write(key: _key, value: cookie);
  @override
  Future<void> clearCookie() => _storage.delete(key: _key);
  @override
  Future<String?> readPendingSignIn() => _storage.read(key: _pendingKey);
  @override
  Future<void> writePendingSignIn(String value) =>
      _storage.write(key: _pendingKey, value: value);
  @override
  Future<void> clearPendingSignIn() => _storage.delete(key: _pendingKey);
}

/// How long a pending magic-link row stays claimable. Mirrors the server's
/// `PENDING_TTL_SECONDS` (web/src/models/pending-sign-in.ts) — keep in
/// lockstep: restoring a session older than this can only ever resolve to
/// "Link expired", so it is dropped locally instead.
const Duration kMagicLinkWindow = Duration(minutes: 10);

class CurrentUser {
  CurrentUser({
    required this.userId,
    required this.email,
    this.name,
    this.tier,
    this.promotional = false,
  });
  final String userId;
  final String email;
  final String? name;
  final String? tier;

  /// True when [tier] is a temporary, unpurchased promo grant rather than a
  /// real subscription — surfaced in the UI as the beta grant, not as [tier].
  final bool promotional;
}

/// User-Agent sent on account/sign-in requests so the magic-link approval page
/// and email identify the requester as the Antgrid app on a specific OS,
/// instead of the bare `Dart/<v> (dart:io)` default. Example:
/// `Antgrid/1.0.6 (windows 10.0.26200)`.
String _antgridUserAgent() {
  final os = Platform.operatingSystem;
  final version = Platform.operatingSystemVersion;
  return 'Antgrid/${BuildInfo.version} ($os $version)';
}

/// Bounds enforced before a password ever leaves the device. Mirror of
/// `MIN_PASSWORD_LENGTH` / `MAX_PASSWORD_LENGTH` in
/// web/src/auth/better-auth.ts — keep in lockstep. The server rejects an
/// out-of-range value with PASSWORD_TOO_SHORT / PASSWORD_TOO_LONG, codes this
/// client has no branch for, so drift surfaces as a generic "try again" the
/// user can never satisfy.
const int kMinPasswordLength = 12;
const int kMaxPasswordLength = 128;

/// Both bounds in one message, or null when [password] is acceptable. Mirrors
/// `passwordLengthError` in web/src/routes/ui.tsx so the two surfaces word the
/// same rule the same way.
String? passwordLengthError(String password) {
  if (password.length < kMinPasswordLength) {
    return 'Password must be at least $kMinPasswordLength characters';
  }
  if (password.length > kMaxPasswordLength) {
    return 'Password must be at most $kMaxPasswordLength characters';
  }
  return null;
}

/// Outcome of [AuthService.signInWithPassword].
///
/// [emailNotVerified] is a STATE, not a failure — Better-Auth verifies the
/// password before it checks `emailVerified` (api/routes/sign-in.mjs), so
/// reaching it means the credentials were right. The caller routes to
/// verification instead of showing an error.
///
/// [invalidCredentials] deliberately collapses several server answers into one:
/// a wrong password, an unknown address, and an account that has no password at
/// all (magic-link/OAuth only) all return INVALID_EMAIL_OR_PASSWORD. Telling
/// them apart in the UI would rebuild the enumeration oracle the server is
/// avoiding.
enum PasswordSignIn { ok, invalidCredentials, emailNotVerified }

/// What the Apple sign-in sheet hands back, reduced to the fields the server
/// takes. A seam for tests: the real sheet is a system UI no widget test can
/// drive.
class AppleCredential {
  const AppleCredential({
    required this.identityToken,
    required this.authorizationCode,
    this.givenName,
    this.familyName,
  });

  final String identityToken;

  /// Single-use and valid for five minutes; traded server-side for the refresh
  /// token that account deletion revokes.
  final String authorizationCode;

  /// Apple supplies the name on the FIRST authorization only, so this is the
  /// one chance to send it.
  final String? givenName;
  final String? familyName;
}

/// Presents Apple's sheet for [nonce]. Resolves to null when the user
/// dismissed it, and throws [AuthException] when it could not complete.
typedef AppleCredentialRequest =
    Future<AppleCredential?> Function(String nonce);

/// Runs an OAuth round trip inside the app, resolving to the callback URL the
/// flow ended on, or to null when the user closed the sheet. Throws
/// [AuthException] when the sheet could not be shown.
typedef InAppWebAuth = Future<Uri?> Function(Uri url, String callbackScheme);

/// How far [AuthService.startOAuth] got before returning.
enum OAuthStart {
  /// The system browser is up; the outcome arrives later as a deep link.
  handedOff,

  /// The round trip ran in the app and the session cookie is stored.
  signedIn,

  /// The round trip ran in the app and ended without a session: the user
  /// closed the sheet, or redemption failed and was reported on
  /// [AuthService.oauthFailures].
  notSignedIn,
}

/// Thrown by magic-link flows on a non-recoverable failure (bad response,
/// insecure transport). Pending/transient poll failures are NOT exceptions —
/// see [MagicLinkStatus.error].
enum AuthFailure {
  validation,
  throttled,
  unavailable,
  network,
  storage,
  cancelled,
  expired,
}

class AuthException implements Exception {
  AuthException(
    this.message, {
    this.kind = AuthFailure.validation,
    this.retryAfter,
  });
  final String message;
  final AuthFailure kind;
  final Duration? retryAfter;
  @override
  String toString() => 'AuthException: $message';
}

/// Opaque handle returned by [AuthService.startMagicLink] and passed to
/// [AuthService.pollStatus]. Holds the pending-row id and the browser-binding
/// cookie value. Kept out of [AuthService] instance state so the service stays
/// stateless and retry-safe.
class MagicLinkSession {
  MagicLinkSession({
    required this.id,
    required this.bindCookie,
    this.email,
    this.expiresAt,
    this.retryAt,
    this.generation,
    this.journeyId,
  });

  final DateTime? expiresAt;
  final DateTime? retryAt;
  final int? generation;
  final String? journeyId;

  /// Address the link was sent to. Carried so a sign-in restored after the app
  /// was killed can still name the inbox to check. Null for sessions built
  /// in-memory, where the caller already has the address on hand.
  final String? email;

  /// Server-generated flow id. The
  /// server requires this exact id together with [bindCookie] when polling.
  final String id;

  /// Value of the `antgrid.cross_device_token` bind cookie that authorizes
  /// status polling for this pending sign-in.
  final String bindCookie;
}

/// Mirrors the server's cross-device status strings, plus a local-only
/// [error] for transient poll failures the caller should ignore.
enum MagicLinkStatus { pending, ready, expired, consumed, unbound, error }

/// Delivery outcome of the magic-link email, reported by the server's ZeptoMail
/// webhook. Orthogonal to [MagicLinkStatus]: a hard bounce means the link will
/// never arrive even while the sign-in is still pending. Absent (null) until a
/// bounce is reported — ZeptoMail emits no "delivered" event, so there is no
/// success signal to surface.
enum DeliveryStatus {
  accepted,
  queued,
  sending,
  providerAccepted,
  failed,
  expired,
  bounced,
}

/// Result of one [AuthService.pollStatus] tick: the sign-in [status] plus an
/// optional [delivery] signal carried on the pending response.
class MagicLinkPoll {
  MagicLinkPoll({required this.status, this.delivery});
  final MagicLinkStatus status;
  final DeliveryStatus? delivery;
}

class AuthFlowReceipt {
  AuthFlowReceipt({
    required this.id,
    required this.journeyId,
    required this.status,
    required this.serverTime,
    required this.expiresAt,
    required this.retryAt,
    required this.delivery,
  });
  final String id;
  final String journeyId;
  final MagicLinkStatus status;
  final DateTime serverTime;
  final DateTime expiresAt;
  final DateTime retryAt;
  final DeliveryStatus? delivery;
  factory AuthFlowReceipt.fromJson(Map<String, dynamic> json) {
    try {
      return AuthFlowReceipt(
        id: json['id'] as String,
        journeyId: json['journeyId'] as String,
        status: MagicLinkStatus.values.byName(json['status'] as String),
        serverTime: DateTime.parse(json['serverTime'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        retryAt: DateTime.parse(json['retryAt'] as String),
        delivery: switch (json['delivery']) {
          'provider_accepted' => DeliveryStatus.providerAccepted,
          null => null,
          final String name => DeliveryStatus.values.byName(name),
          _ => throw const FormatException('invalid delivery'),
        },
      );
    } catch (_) {
      throw AuthException('Unexpected server response');
    }
  }
}

class AuthService {
  AuthService({
    required this.licenseApiUrl,
    required this.storage,
    http.Client? httpClient,
    DateTime Function()? now,
    Future<bool> Function(Uri url)? launchUrl,
    AppleCredentialRequest? requestAppleCredential,
    InAppWebAuth? authenticateInApp,
  }) : _http = httpClient ?? http.Client(),
       _now = now ?? clock.now,
       _launchUrl = launchUrl ?? _launchExternal,
       _requestAppleCredential = requestAppleCredential ?? _presentAppleSignIn,
       _authenticateInApp = authenticateInApp ?? _presentWebAuthSession;

  final String licenseApiUrl;
  final AuthStorage storage;
  final http.Client _http;
  final DateTime Function() _now;
  int _generation = 0;
  Future<void> _storageTail = Future.value();
  Map<String, dynamic>? _oauthAttempt;
  String? _requestFlowCookie;
  String? _requestEmail;
  Object? _magicResendGuard;
  String? _magicResendFlowId;

  Future<T> _serializeStorage<T>(Future<T> Function() action) {
    final result = _storageTail.then((_) => action());
    _storageTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _commitCookie(
    String cookie,
    int generation,
  ) => _serializeStorage(() async {
    if (generation != _generation) {
      throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
    }
    try {
      final previous = await storage.readCookie();
      if (generation != _generation) {
        throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
      }
      await storage.writeCookie(cookie);
      if (generation != _generation) {
        if (previous == null) {
          await storage.clearCookie();
        } else {
          await storage.writeCookie(previous);
        }
        throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
      }
    } on AuthException {
      rethrow;
    } catch (_) {
      throw AuthException(
        'Could not securely save sign-in. Try again.',
        kind: AuthFailure.storage,
      );
    }
  });

  Future<void> cancelAuthentication() {
    final generation = ++_generation;
    _oauthAttempt = null;
    _magicResendGuard = null;
    _magicResendFlowId = null;
    return _serializeStorage(() async {
      if (generation == _generation) await storage.clearPendingSignIn();
    });
  }

  Map<String, String> get _clientHeaders => {
    'x-antgrid-surface': 'flutter',
    'x-antgrid-platform': Platform.operatingSystem,
    'x-antgrid-version': BuildInfo.version,
  };

  void _checkAccepted(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 429) {
      final raw = response.headers['retry-after'];
      final seconds = int.tryParse(raw ?? '');
      final date = raw == null ? null : _parseHttpDate(raw);
      final retry = seconds != null
          ? Duration(seconds: seconds)
          : date?.difference(_now());
      throw AuthException(
        'Too many requests. Please wait before trying again.',
        kind: AuthFailure.throttled,
        retryAfter: retry,
      );
    }
    if (response.statusCode >= 500) {
      throw AuthException(
        'Sign-in service is temporarily unavailable. Try again.',
        kind: AuthFailure.unavailable,
      );
    }
    throw AuthException(
      'Request was not accepted. Check your details and try again.',
      kind: AuthFailure.validation,
    );
  }

  static DateTime? _parseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  /// Injectable for tests only: on desktop `flutter test` registers the REAL
  /// Dart url_launcher plugin, so exercising [startOAuth] against the default
  /// would open an actual browser on the test machine.
  final Future<bool> Function(Uri url) _launchUrl;

  static Future<bool> _launchExternal(Uri url) => url_launcher.launchUrl(
    url,
    mode: url_launcher.LaunchMode.externalApplication,
  );

  final InAppWebAuth _authenticateInApp;

  static const _webAuthChannel = MethodChannel('ai.radhaai.antgrid/web_auth');

  static Future<Uri?> _presentWebAuthSession(
    Uri url,
    String callbackScheme,
  ) async {
    final String? callback;
    try {
      callback = await _webAuthChannel.invokeMethod<String>('authenticate', {
        'url': url.toString(),
        'callbackScheme': callbackScheme,
      });
    } on PlatformException catch (e) {
      AbLog.warn(
        'AuthService',
        'In-app sign-in sheet failed',
        fields: {'code': e.code},
      );
      throw AuthException('Could not open the sign-in page');
    }
    return callback == null ? null : Uri.parse(callback);
  }

  final AppleCredentialRequest _requestAppleCredential;

  static Future<AppleCredential?> _presentAppleSignIn(String nonce) async {
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: nonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      AbLog.warn(
        'AuthService',
        'Apple sign-in sheet failed',
        fields: {'code': e.code.name},
      );
      throw AuthException('Apple sign-in failed. Try again.');
    } on SignInWithAppleException catch (e) {
      AbLog.warn(
        'AuthService',
        'Apple sign-in unavailable',
        fields: {'failure': e.runtimeType.toString()},
      );
      throw AuthException('Apple sign-in is not available on this device.');
    }
    final identityToken = credential.identityToken;
    if (identityToken == null) {
      throw AuthException('Apple sign-in failed. Try again.');
    }
    return AppleCredential(
      identityToken: identityToken,
      authorizationCode: credential.authorizationCode,
      givenName: credential.givenName,
      familyName: credential.familyName,
    );
  }

  /// User-facing OAuth failures that surface OUTSIDE any call stack: the
  /// browser detour means the outcome arrives later as a deep link, long after
  /// [startOAuth]'s future completed, so [handleDeepLink] has no caller to
  /// throw to that could show UI. Whatever sign-in surface is on screen
  /// listens here. A failure with no listener yet (the cold-start deep link
  /// can be consumed before any sign-in surface subscribes) is held and
  /// replayed to the first subscriber instead of being dropped.
  Stream<String> get oauthFailures => _oauthFailures.stream;
  late final StreamController<String> _oauthFailures =
      StreamController<String>.broadcast(
        onListen: () {
          final pending = _pendingOAuthFailure;
          if (pending == null) return;
          _pendingOAuthFailure = null;
          // Microtask: the subscriber that triggered onListen must be fully
          // registered before the replayed event is dispatched.
          scheduleMicrotask(() {
            if (_oauthFailures.hasListener) _oauthFailures.add(pending);
          });
        },
      );
  String? _pendingOAuthFailure;

  /// Provider of the most recent [startOAuth] in this process, kept only to
  /// name it in failure copy. Null on a cold-start callback (the process was
  /// killed during the browser detour) — copy falls back to the generic form.
  String? _lastOAuthProvider;

  /// Begin OAuth. Provider is "github", "google" or "apple".
  /// The server carries the attempt in OAuth state and issues a handoff code
  /// bound to the app verifier; [handleDeepLink] redeems it for the session cookie.
  /// Deep links can't receive cookies directly, and forwarding the raw session
  /// would expose it to custom-scheme hijacking and logging.
  ///
  /// iOS runs the round trip in the app's own sign-in sheet and returns once it
  /// is over, because App Review rejects a hand-off to Safari (guideline 4).
  /// Everywhere else this opens the system browser and returns
  /// [OAuthStart.handedOff].
  ///
  /// Throws [AuthException] when the browser or sheet cannot be opened;
  /// failures of the round-trip itself are reported on [oauthFailures].
  /// Whether [startOAuth] runs the whole round trip before returning, rather
  /// than handing off to the system browser.
  bool get oauthRunsInApp => defaultTargetPlatform == TargetPlatform.iOS;

  Future<OAuthStart> startOAuth(String provider) async {
    _assertSecureTransport();
    final generation = ++_generation;
    _lastOAuthProvider = provider;
    final verifier = _newNonce();
    final response = await _postAuthJson('/api/auth/sign-in/native/start', {
      'provider': provider,
      'challenge': base64Url
          .encode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', ''),
    });
    _checkAccepted(response);
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw AuthException('Unexpected server response');
    }
    if (body['id'] is! String ||
        body['serverTime'] is! String ||
        body['expiresAt'] is! String ||
        body['url'] is! String) {
      throw AuthException('Unexpected server response');
    }
    final serverTime = DateTime.tryParse(body['serverTime'] as String);
    final serverExpiry = DateTime.tryParse(body['expiresAt'] as String);
    if (serverTime == null || serverExpiry == null) {
      throw AuthException('Unexpected server response');
    }
    final expiresAt = _now().add(serverExpiry.difference(serverTime));
    final attempt = {
      'kind': 'oauth',
      'id': body['id'],
      'verifier': verifier,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    };
    final url = Uri.parse(body['url'] as String);
    if (url.origin != Uri.parse(licenseApiUrl).origin ||
        url.path != '/oauth/start') {
      throw AuthException('Unexpected server response');
    }
    await _serializeStorage(() async {
      if (generation != _generation) {
        throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
      }
      try {
        await storage.writePendingSignIn(jsonEncode(attempt));
      } catch (_) {
        throw AuthException(
          'Could not securely save sign-in. Try again.',
          kind: AuthFailure.storage,
        );
      }
      if (generation != _generation) {
        await storage.clearPendingSignIn();
        throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
      }
      _oauthAttempt = attempt;
    });
    if (oauthRunsInApp) {
      final callback = await _authenticateInApp(url, 'antgrid');
      if (callback == null) {
        await cancelAuthentication();
        return OAuthStart.notSignedIn;
      }
      return await handleDeepLink(callback)
          ? OAuthStart.signedIn
          : OAuthStart.notSignedIn;
    }
    final bool opened;
    try {
      opened = await _launchUrl(url);
    } catch (_) {
      // url_launcher throws (rather than returning false) on some platforms
      // when nothing can take the URL; both shapes mean the same thing here.
      if (generation == _generation) await cancelAuthentication();
      throw AuthException('Could not open the browser');
    }
    if (!opened) {
      if (generation == _generation) await cancelAuthentication();
      throw AuthException('Could not open the browser');
    }
    return OAuthStart.handedOff;
  }

  void _emitOAuthFailure([String? detail]) {
    final provider = switch (_lastOAuthProvider) {
      'github' => 'GitHub',
      'google' => 'Google',
      'apple' => 'Apple',
      _ => null,
    };
    final message =
        detail ??
        (provider == null
            ? "Sign-in didn't complete. Try again."
            : "$provider sign-in didn't complete. Try again.");
    // No listener yet (cold-start deep link consumed before the sign-in
    // screen subscribes) — hold the failure for onListen instead of dropping
    // it on the broadcast floor.
    if (_oauthFailures.hasListener) {
      _oauthFailures.add(message);
    } else {
      _pendingOAuthFailure = message;
    }
  }

  /// Redeem only the active OAuth callback with its securely stored verifier.
  /// The browser handoff code cannot authenticate a client without that verifier.
  ///
  /// Resolves to true once a session cookie is stored.
  Future<bool> handleDeepLink(Uri uri) async {
    if (uri.scheme != 'antgrid' ||
        uri.host != 'auth' ||
        uri.path != '/callback' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    final Map<String, String> query;
    try {
      query = uri.queryParameters;
    } on FormatException {
      // The getter percent-DECODES, and an escape that is not valid UTF-8
      // (`antgrid://auth/x?token=%80`) throws out of it. Any web page can fire
      // that URL, and main()'s handleLink is unawaited, so the throw would land
      // as an unhandled async error rather than an ignored link.
      return false;
    }
    if (uri.queryParametersAll.values.any((values) => values.length != 1) ||
        query.keys.any((key) => !{'flow', 'code', 'error'}.contains(key)) ||
        (query.containsKey('code') && query.containsKey('error'))) {
      return false;
    }
    if (!_transportIsSecure) return false;
    final generation = _generation;
    try {
      if (_oauthAttempt == null) {
        final raw = await storage.readPendingSignIn();
        if (raw != null) {
          final record = jsonDecode(raw) as Map<String, dynamic>;
          if (record['kind'] == 'oauth' &&
              generation == _generation &&
              _oauthAttempt == null) {
            _oauthAttempt = record;
          }
        }
      }
    } catch (_) {
      return false;
    }
    final attempt = _oauthAttempt;
    if (generation != _generation ||
        attempt == null ||
        query['flow'] != attempt['id'] ||
        DateTime.tryParse(
              attempt['expiresAt'] as String? ?? '',
            )?.isAfter(_now()) !=
            true) {
      return false;
    }
    if (query['error'] != null) {
      await cancelAuthentication();
      if (generation + 1 == _generation) _emitOAuthFailure();
      return false;
    }
    final code = query['code'];
    if (code == null ||
        code.isEmpty ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      return false;
    }
    try {
      final res = await boundedHttpRequest(
        _http,
        'POST',
        Uri.parse('$licenseApiUrl/api/auth/sign-in/native/redeem'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'id': attempt['id'],
          'code': code,
          'verifier': attempt['verifier'],
        }),
      );
      _checkAccepted(res);
      // The signed session cookie only exists in Set-Cookie — the JSON body's
      // `token` is the unsigned DB token, not the signed cookie the server
      // expects on replay. [_extractSessionCookie] captures the full
      // `name=value` pair (real name, prefix included) for verbatim replay.
      final cookie = _extractSessionCookie(res.headers['set-cookie']);
      if (cookie == null) {
        if (generation == _generation) _emitOAuthFailure();
        return false;
      }
      await _commitCookie(cookie, generation);
      await _discardQuietly(generation);
      if (generation != _generation) return false;
      _oauthAttempt = null;
      return true;
    } catch (e) {
      AbLog.warn(
        'AuthService',
        'OAuth callback redemption failed',
        fields: {'failure': e.runtimeType.toString()},
      );
      if (generation == _generation) {
        _emitOAuthFailure(e is AuthException ? e.message : null);
      }
      return false;
    }
  }

  Future<void> signOut() async {
    final generation = ++_generation;
    _requestFlowCookie = null;
    _requestEmail = null;
    _oauthAttempt = null;
    final cookie = await storage.readCookie();
    // Never transmit the session token over plaintext. On an insecure
    // transport we skip the server round-trip but still clear it locally.
    if (cookie != null && _transportIsSecure) {
      try {
        await boundedHttpRequest(
          _http,
          'POST',
          Uri.parse('$licenseApiUrl/api/auth/sign-out'),
          headers: {'cookie': cookie},
        );
      } catch (_) {
        /* best-effort */
      }
    }
    await _serializeStorage(() async {
      if (generation == _generation) await storage.clearCookie();
    });
    // A pending ticket outliving sign-out would let SignInScreen restore it on
    // the next launch and mint a fresh session the moment the old link is
    // approved — silently undoing the sign-out.
    await _discardQuietly(generation);
  }

  /// POST JSON to an account-service path, carrying the app's User-Agent and
  /// NO cookie.
  ///
  /// Cookieless is load-bearing, not incidental: `/send-verification-email`
  /// looks up a session first and, finding one, throws EMAIL_MISMATCH or
  /// EMAIL_ALREADY_VERIFIED instead of taking the anonymous branch these flows
  /// need (api/routes/email-verification.mjs). The web routes strip the cookie
  /// for the same reason — see `anonymousHeaders` in web/src/routes/ui.tsx.
  Future<http.Response> _postAuthJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final generation = _generation;
    final email = body['email'] as String?;
    if (email != null && email != _requestEmail) {
      _requestEmail = email;
      _requestFlowCookie = null;
    }
    try {
      final response = await boundedHttpRequest(
        _http,
        'POST',
        Uri.parse('$licenseApiUrl$path'),
        headers: {
          'content-type': 'application/json',
          'origin': Uri.parse(licenseApiUrl).origin,
          'user-agent': _antgridUserAgent(),
          ..._clientHeaders,
          if (email != null && _requestFlowCookie != null)
            'cookie': _requestFlowCookie!,
        },
        body: jsonEncode(body),
      );
      if (generation == _generation &&
          email != null &&
          email == _requestEmail) {
        final binding = RegExp(
          r'(antgrid\.request_flow\.[^=;, ]+=[^;, ]+)',
        ).firstMatch(response.headers['set-cookie'] ?? '');
        if (binding != null) _requestFlowCookie = binding.group(1);
      }
      return response;
    } catch (_) {
      throw AuthException(
        'Could not reach the sign-in server',
        kind: AuthFailure.network,
      );
    }
  }

  AuthFlowReceipt? _flowReceipt(http.Response response) {
    if (response.body.trim().isEmpty) return null;
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return json['flow'] == null
          ? null
          : AuthFlowReceipt.fromJson(json['flow'] as Map<String, dynamic>);
    } catch (_) {
      throw AuthException('Unexpected server response');
    }
  }

  /// Better-Auth serializes a thrown APIError as `{code, message}`. Match on
  /// `code` — the stable BASE_ERROR_CODES key — never `message`, which is prose
  /// and gets reworded upstream. Mirrors `authErrorCode` in
  /// web/src/routes/ui.tsx.
  static String? _errorCode(http.Response res) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>?;
      final code = body?['code'];
      return code is String ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// Normalized the same way web/src/routes/ui.tsx normalizes a submitted form,
  /// so an address typed here and one typed there resolve to the same user.
  static String _normalizeEmail(String email) => email.trim().toLowerCase();

  /// Sign in with an email and password, persisting the session cookie on
  /// success. Never throws for a rejected credential — see [PasswordSignIn].
  ///
  /// [password] is passed through untouched. Leading and trailing spaces are
  /// part of what the user chose; trimming here would break every later
  /// comparison against what the server stored.
  Future<PasswordSignIn> signInWithPassword({
    required String email,
    required String password,
  }) async {
    _assertSecureTransport();
    final generation = ++_generation;
    final res = await _postAuthJson('/api/auth/sign-in/email', {
      'email': _normalizeEmail(email),
      'password': password,
    });
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final cookie = _extractSessionCookie(res.headers['set-cookie']);
      if (cookie == null) throw AuthException('Unexpected server response');
      await _commitCookie(cookie, generation);
      return PasswordSignIn.ok;
    }
    if (res.statusCode == 429 || res.statusCode >= 500) _checkAccepted(res);
    switch (_errorCode(res)) {
      case 'EMAIL_NOT_VERIFIED':
        return PasswordSignIn.emailNotVerified;
      case 'INVALID_EMAIL_OR_PASSWORD':
      case 'INVALID_EMAIL':
        return PasswordSignIn.invalidCredentials;
      default:
        throw AuthException('Could not sign in. Try again.');
    }
  }

  /// Sign in with Apple's native sheet, persisting the session cookie on
  /// success. Returns false when the user dismissed the sheet.
  ///
  /// The server verifies Apple's identity token and signs in, or creates, the
  /// account it names. The nonce binds that token to this attempt, and it goes
  /// to Apple and to the server as the SAME string: Better-Auth compares the
  /// token's `nonce` claim with the one it is sent verbatim, where Firebase's
  /// convention hashes one side.
  Future<bool> signInWithApple() async {
    _assertSecureTransport();
    final generation = ++_generation;
    final nonce = _newNonce();
    final credential = await _requestAppleCredential(nonce);
    if (credential == null) return false;
    final name = {
      if (credential.givenName case final given? when given.isNotEmpty)
        'firstName': given,
      if (credential.familyName case final family? when family.isNotEmpty)
        'lastName': family,
    };
    final res = await _postAuthJson('/api/auth/sign-in/social', {
      'provider': 'apple',
      'idToken': {
        'token': credential.identityToken,
        'nonce': nonce,
        if (name.isNotEmpty) 'user': {'name': name},
      },
    });
    if (res.statusCode == 429 || res.statusCode >= 500) _checkAccepted(res);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // Apple's sheet has already succeeded by now, so the one copy the user
      // sees stands for every server-side cause — a deployment without Apple
      // configured (PROVIDER_NOT_FOUND) reads the same as a rejected token.
      AbLog.warn(
        'AuthService',
        'Apple sign-in rejected by server',
        fields: {'status': res.statusCode, 'code': _errorCode(res)},
      );
      throw AuthException('Could not sign in with Apple. Try again.');
    }
    final cookie = _extractSessionCookie(res.headers['set-cookie']);
    if (cookie == null) throw AuthException('Unexpected server response');
    await _commitCookie(cookie, generation);
    await _sendAppleAuthorizationCode(cookie, credential.authorizationCode);
    return true;
  }

  /// Hands the server the sign-in's authorization code, which it trades for
  /// the refresh token it must revoke if this account is ever deleted.
  ///
  /// Never throws: the user is signed in by now, and losing this call costs
  /// only that revocation, never the sign-in.
  Future<void> _sendAppleAuthorizationCode(String cookie, String code) async {
    try {
      final res = await boundedHttpRequest(
        _http,
        'POST',
        Uri.parse('$licenseApiUrl/account/apple/authorization-code'),
        headers: {'cookie': cookie, 'content-type': 'application/json'},
        body: jsonEncode({'code': code}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) return;
      AbLog.warn(
        'AuthService',
        'Apple authorization code was not accepted',
        fields: {'status': res.statusCode},
      );
    } catch (e) {
      AbLog.warn(
        'AuthService',
        'Apple authorization code could not be sent',
        fields: {'failure': e.runtimeType.toString()},
      );
    }
  }

  static String _newNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Create an account. Mints NO session — the server runs `autoSignIn: false`
  /// with `requireEmailVerification`, so the caller's next step is always
  /// "check your email", never a signed-in shell.
  ///
  /// Success here does NOT mean the address was free. Better-Auth answers an
  /// address that already has an account with a synthetic success and sends
  /// nothing, so that sign-up cannot enumerate users (api/routes/sign-up.mjs);
  /// this client cannot tell the two apart and the copy downstream must not
  /// claim to.
  Future<AuthFlowReceipt?> signUpWithPassword({
    required String email,
    required String password,
  }) async {
    _assertSecureTransport();
    final lengthError = passwordLengthError(password);
    if (lengthError != null) throw AuthException(lengthError);
    final res = await _postAuthJson('/api/auth/sign-up/email', {
      'email': _normalizeEmail(email),
      'password': password,
      // Required by the endpoint and unused by us — the address stands in for
      // it, exactly as /ui/signup does on the web.
      'name': _normalizeEmail(email),
    });
    if (res.statusCode >= 200 && res.statusCode < 300) return _flowReceipt(res);
    if (res.statusCode == 429 || res.statusCode >= 500) _checkAccepted(res);
    throw AuthException('Could not create the account. Try again.');
  }

  /// Ask the server to re-send the verification link for [email].
  ///
  /// Uniform successful responses preserve account privacy. Throttling and
  /// service failures must still reach the user instead of claiming a send.
  Future<AuthFlowReceipt?> sendVerificationEmail(String email) async {
    _assertSecureTransport();
    final response = await _postAuthJson('/api/auth/send-verification-email', {
      'email': _normalizeEmail(email),
    });
    _checkAccepted(response);
    return _flowReceipt(response);
  }

  /// Ask the server to email a password-reset link for [email]. The reset
  /// itself happens in a browser; the app only starts it.
  ///
  /// No `redirectTo` — the endpoint runs `originCheck` over that field, and our
  /// `sendResetPassword` builds the link from its own base URL regardless
  /// (web/src/auth/better-auth.ts), so sending one could only ever fail.
  /// Uniform acceptance does not imply the address has an account.
  Future<AuthFlowReceipt?> requestPasswordReset(String email) async {
    _assertSecureTransport();
    final response = await _postAuthJson('/api/auth/request-password-reset', {
      'email': _normalizeEmail(email),
    });
    _checkAccepted(response);
    return _flowReceipt(response);
  }

  /// Begin a magic-link sign-in. POSTs the email to the cross-device start
  /// endpoint and captures the `antgrid.cross_device_token` bind cookie from the
  /// response. The server emails an approval link to [email].
  Future<MagicLinkSession> startMagicLink(
    String email, {
    MagicLinkSession? previous,
  }) async {
    _assertSecureTransport();
    final resending = previous != null;
    if (resending &&
        ((previous.generation ?? _generation) != _generation ||
            _normalizeEmail(previous.email ?? '') != _normalizeEmail(email))) {
      throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
    }
    if (resending && _magicResendGuard != null) {
      throw AuthException('A resend is already in progress.');
    }
    // A rejected resend must leave the existing approval claimable.
    var generation = resending ? _generation : ++_generation;
    final resendGuard = resending ? Object() : null;
    if (resending) {
      _magicResendGuard = resendGuard;
      _magicResendFlowId = previous.id;
    }
    try {
      final http.Response res;
      try {
        res = await boundedHttpRequest(
          _http,
          'POST',
          Uri.parse('$licenseApiUrl/api/auth/sign-in/cross-device/start'),
          headers: {
            'content-type': 'application/json',
            'origin': Uri.parse(licenseApiUrl).origin,
            'user-agent': _antgridUserAgent(),
            ..._clientHeaders,
            if (previous != null)
              'cookie':
                  'antgrid.cross_device_token.${previous.id}=${previous.bindCookie}',
          },
          body: jsonEncode({
            'email': _normalizeEmail(email),
            if (previous != null) 'previousId': previous.id,
          }),
        );
      } catch (_) {
        // Network failure (offline, DNS, TLS, timeout) → surface as the
        // method's documented AuthException so callers handle it uniformly.
        throw AuthException(
          'Could not reach the sign-in server',
          kind: AuthFailure.network,
        );
      }
      _checkAccepted(res);
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (_) {
        throw AuthException('Unexpected server response');
      }
      final id = body?['id'] as String?;
      final bind = _extractCookie(
        res.headers['set-cookie'],
        'antgrid.cross_device_token.$id',
      );
      if (id == null || bind == null) {
        throw AuthException('Unexpected server response');
      }
      final serverTime = DateTime.tryParse(
        body?['serverTime'] as String? ?? '',
      );
      final serverExpiry = DateTime.tryParse(
        body?['expiresAt'] as String? ?? '',
      );
      final serverRetry = DateTime.tryParse(body?['retryAt'] as String? ?? '');
      if (serverTime == null || serverExpiry == null || serverRetry == null) {
        throw AuthException('Unexpected server response');
      }
      final expiresAt = _now().add(serverExpiry.difference(serverTime));
      final retryAt = _now().add(serverRetry.difference(serverTime));
      // The binding and server deadline must survive the browser detour.
      await _serializeStorage(() async {
        if (generation != _generation) {
          throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
        }
        try {
          await storage.writePendingSignIn(
            jsonEncode({
              'kind': 'magic',
              'id': id,
              'bindCookie': bind,
              'email': email,
              'expiresAt': expiresAt.toUtc().toIso8601String(),
              'retryAt': retryAt.toUtc().toIso8601String(),
              'journeyId': body?['journeyId'],
            }),
          );
        } catch (_) {
          throw AuthException(
            'Could not securely save sign-in. Try again.',
            kind: AuthFailure.storage,
          );
        }
        if (generation != _generation) {
          await storage.clearPendingSignIn();
          throw AuthException('Sign-in cancelled', kind: AuthFailure.cancelled);
        }
        if (resending) generation = ++_generation;
      });
      return MagicLinkSession(
        id: id,
        bindCookie: bind,
        email: email,
        generation: generation,
        journeyId: body?['journeyId'] as String?,
        expiresAt: expiresAt,
        retryAt: retryAt,
      );
    } finally {
      if (identical(_magicResendGuard, resendGuard)) {
        _magicResendGuard = null;
        _magicResendFlowId = null;
      }
    }
  }

  /// Abandon the pending sign-in, so a later launch does not restore it.
  Future<void> discardPendingMagicLink() => cancelAuthentication();

  /// The pending sign-in left by a previous [startMagicLink], if one is still
  /// worth polling. Returns null — and drops the entry — when nothing was
  /// started, the record is unreadable, or its link window has lapsed.
  ///
  /// Never throws: callers restore fire-and-forget during widget init, where a
  /// raised error would surface as an unhandled async failure on app launch.
  Future<MagicLinkSession?> restorePendingMagicLink() async {
    final generation = _generation;
    try {
      final raw = await storage.readPendingSignIn();
      if (generation != _generation || raw == null) return null;
      final body = jsonDecode(raw) as Map<String, dynamic>;
      if (body['kind'] == 'oauth') return null;
      final id = body['id'] as String?;
      final bindCookie = body['bindCookie'] as String?;
      final expiresAt =
          DateTime.tryParse(body['expiresAt'] as String? ?? '') ??
          DateTime.tryParse(
            body['startedAt'] as String? ?? '',
          )?.add(kMagicLinkWindow);
      if (id == null || bindCookie == null || expiresAt == null) {
        throw const FormatException('incomplete pending sign-in');
      }
      if (!expiresAt.isAfter(_now())) {
        await _discardQuietly(generation);
        return null;
      }
      return MagicLinkSession(
        id: id,
        bindCookie: bindCookie,
        email: body['email'] as String?,
        expiresAt: expiresAt,
        retryAt: DateTime.tryParse(body['retryAt'] as String? ?? ''),
        generation: _generation,
        journeyId: body['journeyId'] as String?,
      );
    } catch (_) {
      // Unreadable entry (corrupt, an older schema, or a store that won't open)
      // — drop it rather than wedging sign-in on every launch.
      await _discardQuietly(generation);
      return null;
    }
  }

  /// Best-effort delete: used on paths that must not throw. Dropping the ticket
  /// is always cleanup behind work that already landed — a written session
  /// cookie, a terminal server state — so a store that won't delete must not
  /// cost the caller that result. A ticket left behind is self-limiting: the
  /// row it names is already dead server-side, and [restorePendingMagicLink]
  /// drops it outright once [kMagicLinkWindow] lapses.
  Future<void> _discardQuietly(int generation) async {
    try {
      await _serializeStorage(() async {
        if (generation == _generation) await storage.clearPendingSignIn();
      });
    } catch (_) {}
  }

  /// The `LICENSE_API_URL` dart-define, if the app was launched with one
  /// (e.g. `aspire run`'s local full-stack dev flow, see apphost.ts
  /// `pickLanIp`). Baked in at build/launch time by the developer's own
  /// tooling — never attacker- or runtime-reachable — so it's a safe trust
  /// anchor for [_transportIsSecure] independent of the host's address range.
  static const String _licenseApiUrlDartDefine = String.fromEnvironment(
    'LICENSE_API_URL',
  );

  /// Whether [licenseApiUrl] is a transport safe to send credentials over:
  /// `https` to any host, or plain `http` to loopback (covers IPv4
  /// `127.0.0.1`, IPv6 `::1`, `localhost`, and the Android emulator's
  /// `10.0.2.2` alias).
  ///
  /// In DEBUG builds only, also trusts plain `http` to exactly the
  /// `LICENSE_API_URL` dart-define value (whatever host/IP that is — a LAN IP
  /// so emulators/phones can reach the dev machine). The dart-define is
  /// developer-supplied at launch, not something a compromised network path
  /// can inject, so no IP-range check is needed on top of it. Release builds
  /// still require https/loopback: kDebugMode is false and the dart-define is
  /// baked out of CI/store builds, so a misconfigured prod URL can never leak
  /// the session cookie over the wire.
  bool get _transportIsSecure {
    final uri = Uri.parse(licenseApiUrl);
    final isLoopback =
        uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1' ||
        uri.host == '10.0.2.2';
    final trustedDevOrigin =
        kDebugMode &&
        _licenseApiUrlDartDefine.isNotEmpty &&
        licenseApiUrl == _licenseApiUrlDartDefine;
    return uri.scheme == 'https' || isLoopback || trustedDevOrigin;
  }

  /// Reject sending credentials over plaintext unless talking to loopback.
  void _assertSecureTransport() {
    if (!_transportIsSecure) {
      throw AuthException(
        'Refusing to send credentials over insecure transport',
      );
    }
  }

  /// Extract the FULL session-cookie `name=value` pair from a (possibly
  /// comma-folded) Set-Cookie header, preserving whatever name the server
  /// actually used — bare `better-auth.session_token` in dev, or the
  /// `__Secure-`/`__Host-` prefixed name in production (Better-Auth's
  /// `useSecureCookies` rule keys off the https base URL). Returning the real
  /// name (not just the value) is the whole point: callers replay the stored
  /// pair verbatim, so the cookie always matches what the server reads back and
  /// no client has to reconstruct the prefix. `[^;,]+` stops cleanly at the
  /// first attribute even when a later `Expires=` date or a sibling cookie
  /// introduces a comma (Better-Auth session values are base64url + '.', so
  /// they never contain `;` or `,`). Returns null if absent.
  static String? _extractSessionCookie(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'(__Secure-|__Host-)?better-auth\.session_token=([^;,]+)',
    ).firstMatch(header);
    if (match == null) return null;
    final prefix = match.group(1) ?? '';
    return '${prefix}better-auth.session_token=${match.group(2)}';
  }

  /// Extract a cookie VALUE by [name] from a (possibly comma-folded) Set-Cookie
  /// header. Used for the magic-link bind cookie (`antgrid.cross_device_token`),
  /// whose name is never prefixed (the relay sets it via a raw cookie write), so
  /// a value-only read is sufficient and is replayed under the literal name.
  static String? _extractCookie(String? header, String name) {
    if (header == null) return null;
    final escaped = name.replaceAll('.', r'\.');
    final match = RegExp('$escaped=([^;,]+)').firstMatch(header);
    return match?.group(1);
  }

  /// Poll the cross-device status endpoint with the bind cookie. On `ready`,
  /// the session cookie is extracted from the response and persisted via
  /// [storage]. Transient failures return [MagicLinkStatus.error] (not an
  /// exception) so the caller can keep polling until the link window lapses.
  Future<MagicLinkPoll> pollStatus(MagicLinkSession session) async {
    _assertSecureTransport();
    if (_magicResendGuard != null && _magicResendFlowId == session.id) {
      return MagicLinkPoll(status: MagicLinkStatus.error);
    }
    final generation = session.generation ?? _generation;
    if (generation != _generation) {
      return MagicLinkPoll(status: MagicLinkStatus.unbound);
    }
    if (session.expiresAt?.isAfter(_now()) == false) {
      return MagicLinkPoll(status: MagicLinkStatus.expired);
    }
    final http.Response res;
    try {
      res = await boundedHttpRequest(
        _http,
        'GET',
        Uri.parse(
          '$licenseApiUrl/api/auth/sign-in/cross-device/status',
        ).replace(queryParameters: {'id': session.id}),
        headers: {
          'cookie':
              'antgrid.cross_device_token.${session.id}=${session.bindCookie}',
        },
      );
    } catch (_) {
      return MagicLinkPoll(status: MagicLinkStatus.error);
    }
    if (generation != _generation) {
      return MagicLinkPoll(status: MagicLinkStatus.unbound);
    }
    if (_magicResendGuard != null && _magicResendFlowId == session.id) {
      return MagicLinkPoll(status: MagicLinkStatus.error);
    }
    if (res.statusCode == 429) _checkAccepted(res);
    if (res.statusCode != 200) {
      return MagicLinkPoll(status: MagicLinkStatus.error);
    }
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      return MagicLinkPoll(status: MagicLinkStatus.error);
    }
    final delivery = switch (body?['delivery'] as String?) {
      'bounced' => DeliveryStatus.bounced,
      'queued' => DeliveryStatus.queued,
      'sending' => DeliveryStatus.sending,
      'provider_accepted' => DeliveryStatus.providerAccepted,
      'failed' => DeliveryStatus.failed,
      'expired' => DeliveryStatus.expired,
      _ => null,
    };
    switch (body?['status'] as String?) {
      case 'ready':
        final cookie = _extractSessionCookie(res.headers['set-cookie']);
        if (cookie == null) return MagicLinkPoll(status: MagicLinkStatus.error);
        // Store the full `name=value` pair verbatim — do NOT URL-decode it.
        // Better-Auth session tokens are base64url `<token>.<sig>` with no
        // percent-encoded characters, and [fetchCurrentUser]/signOut replay
        // the pair unencoded. This matches the OAuth/deeplink path
        // ([handleDeepLink]); decoding here would break parity.
        await _commitCookie(cookie, generation);
        await _discardQuietly(generation);
        return MagicLinkPoll(status: MagicLinkStatus.ready);
      case 'pending':
        return MagicLinkPoll(
          status: MagicLinkStatus.pending,
          delivery: delivery,
        );
      // Terminal server states: the row can never be claimed now, so drop the
      // ticket. `error` deliberately keeps it — the approval may still be
      // waiting behind a flaky network.
      case 'expired':
        await _discardQuietly(generation);
        return MagicLinkPoll(status: MagicLinkStatus.expired);
      case 'consumed':
        await _discardQuietly(generation);
        return MagicLinkPoll(status: MagicLinkStatus.consumed);
      case 'unbound':
        await _discardQuietly(generation);
        return MagicLinkPoll(status: MagicLinkStatus.unbound);
      default:
        return MagicLinkPoll(status: MagicLinkStatus.error);
    }
  }

  Future<CurrentUser?> fetchCurrentUser() async {
    final cookie = await storage.readCookie();
    if (cookie == null) return null;
    // Never transmit the session token over plaintext; treat a misconfigured
    // insecure transport as signed-out rather than leaking the cookie.
    if (!_transportIsSecure) return null;
    // /account/me joins the Better-Auth session to the active subscription
    // so we get the tier in one round-trip; /api/auth/get-session doesn't
    // know about subscriptions.
    final res = await boundedHttpRequest(
      _http,
      'GET',
      Uri.parse('$licenseApiUrl/account/me'),
      headers: {'cookie': cookie},
    );
    if (res.statusCode == 401) {
      // A definitive rejection, not a transport hiccup: drop the cookie so
      // `hasStoredSessionProvider` stops reading true. Leaving it at rest keeps
      // the optimistic fallback in `signedInProvider` re-asserting "signed in"
      // on every later offline blip, for a session the server already refuses.
      await _serializeStorage(() async {
        if (await storage.readCookie() == cookie) await storage.clearCookie();
      });
      return null;
    }
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>?;
    if (body == null) return null;
    final userId = body['userId'] as String?;
    final email = body['email'] as String?;
    if (userId == null || email == null) return null;
    return CurrentUser(
      userId: userId,
      email: email,
      name: body['name'] as String?,
      tier: body['tier'] as String?,
      promotional: body['promotional'] as bool? ?? false,
    );
  }
}
