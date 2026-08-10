import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../config/build_info.dart';
import '../config/storage_scope.dart';

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
    this.tier,
    this.promotional = false,
  });
  final String userId;
  final String email;
  final String? tier;

  /// True when [tier] is a temporary, unpurchased promo grant rather than a
  /// real subscription — surfaced in the UI as free, not pro.
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

Uri buildOAuthStartUri({
  required String licenseApiUrl,
  required String provider,
}) {
  return Uri.parse('$licenseApiUrl/oauth/start').replace(
    queryParameters: {'provider': provider, 'callbackURL': '/oauth/handoff'},
  );
}

/// Thrown by magic-link flows on a non-recoverable failure (bad response,
/// insecure transport). Pending/transient poll failures are NOT exceptions —
/// see [MagicLinkStatus.error].
class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => 'AuthException: $message';
}

/// Opaque handle returned by [AuthService.startMagicLink] and passed to
/// [AuthService.pollStatus]. Holds the pending-row id and the browser-binding
/// cookie value. Kept out of [AuthService] instance state so the service stays
/// stateless and retry-safe.
class MagicLinkSession {
  MagicLinkSession({required this.id, required this.bindCookie, this.email});

  /// Address the link was sent to. Carried so a sign-in restored after the app
  /// was killed can still name the inbox to check. Null for sessions built
  /// in-memory, where the caller already has the address on hand.
  final String? email;

  /// Pending-row id, returned by `/start` for logging/debugging only. The
  /// server identifies the row from [bindCookie]; polling does not send this.
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
enum DeliveryStatus { bounced }

/// Result of one [AuthService.pollStatus] tick: the sign-in [status] plus an
/// optional [delivery] signal carried on the pending response.
class MagicLinkPoll {
  MagicLinkPoll({required this.status, this.delivery});
  final MagicLinkStatus status;
  final DeliveryStatus? delivery;
}

class AuthService {
  AuthService({
    required this.licenseApiUrl,
    required this.storage,
    http.Client? httpClient,
    DateTime Function()? now,
    Future<bool> Function(Uri url)? launchUrl,
  }) : _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now,
       _launchUrl = launchUrl ?? _launchExternal;

  final String licenseApiUrl;
  final AuthStorage storage;
  final http.Client _http;
  final DateTime Function() _now;

  /// Injectable for tests only: on desktop `flutter test` registers the REAL
  /// Dart url_launcher plugin, so exercising [startOAuth] against the default
  /// would open an actual browser on the test machine.
  final Future<bool> Function(Uri url) _launchUrl;

  static Future<bool> _launchExternal(Uri url) => url_launcher.launchUrl(
    url,
    mode: url_launcher.LaunchMode.externalApplication,
  );

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

  /// Open the system browser to begin OAuth. Provider is "github" or "google".
  /// We pass `callbackURL=/oauth/handoff` so the server can mint
  /// a single-use one-time token bound to the new session and return it in the
  /// `antgrid://` deep link; [handleDeepLink] redeems it for the session cookie.
  /// Deep links can't receive cookies directly, and forwarding the raw session
  /// would expose it to custom-scheme hijacking and logging.
  ///
  /// Throws [AuthException] when the browser cannot be opened; failures of the
  /// round-trip itself are reported on [oauthFailures].
  Future<void> startOAuth(String provider) async {
    _lastOAuthProvider = provider;
    // Better-Auth's social sign-in is POST-only; `/oauth/start` is the
    // browser-navigable GET wrapper that 302s to the provider authorize URL.
    final url = buildOAuthStartUri(
      licenseApiUrl: licenseApiUrl,
      provider: provider,
    );
    final bool opened;
    try {
      opened = await _launchUrl(url);
    } catch (_) {
      // url_launcher throws (rather than returning false) on some platforms
      // when nothing can take the URL; both shapes mean the same thing here.
      throw AuthException('Could not open the browser');
    }
    if (!opened) throw AuthException('Could not open the browser');
  }

  void _emitOAuthFailure() {
    final provider = switch (_lastOAuthProvider) {
      'github' => 'GitHub',
      'google' => 'Google',
      _ => null,
    };
    final message = provider == null
        ? "Sign-in didn't complete. Try again."
        : "$provider sign-in didn't complete. Try again.";
    // No listener yet (cold-start deep link consumed before the sign-in
    // screen subscribes) — hold the failure for onListen instead of dropping
    // it on the broadcast floor.
    if (_oauthFailures.hasListener) {
      _oauthFailures.add(message);
    } else {
      _pendingOAuthFailure = message;
    }
  }

  /// Parse `antgrid://auth/callback?token=<ott>`, redeem the single-use one-time
  /// token at the OTT verify endpoint, and persist the session cookie returned
  /// via `Set-Cookie`. The OTT (not the raw session) is what travels through
  /// the deep link, so a hijacked or logged link yields nothing replayable.
  Future<void> handleDeepLink(Uri uri) async {
    if (uri.scheme != 'antgrid' || uri.host != 'auth') return;
    // The handoff bounces its own failures back as `?error=` (no_session |
    // server_error — web/src/routes/oauth-handoff.ts) so the app regains the
    // foreground; without surfacing it the user lands on an unchanged sign-in
    // screen with no explanation.
    if (uri.queryParameters['error'] != null) {
      _emitOAuthFailure();
      return;
    }
    final token = uri.queryParameters['token'];
    if (token == null || token.isEmpty) return;
    // The verify response carries the session cookie; never redeem (and receive
    // it) over plaintext. Consistent with the magic-link methods' guard.
    if (!_transportIsSecure) return;
    // This may run on the cold-start deep link, unawaited from main() (see
    // main.dart's getInitialLink consumption), so a thrown network error here
    // would surface as an unhandled zone error. Redemption never throws: on
    // any failure the cookie stays unset and the failure is reported on
    // [oauthFailures] so the sign-in screen can offer a retry.
    try {
      final res = await _http.post(
        Uri.parse('$licenseApiUrl/api/auth/one-time-token/verify'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'token': token}),
      );
      if (res.statusCode != 200) {
        _emitOAuthFailure();
        return;
      }
      // The signed session cookie only exists in Set-Cookie — the JSON body's
      // `token` is the unsigned DB token, not the signed cookie the server
      // expects on replay. [_extractSessionCookie] captures the full
      // `name=value` pair (real name, prefix included) for verbatim replay.
      final cookie = _extractSessionCookie(res.headers['set-cookie']);
      if (cookie == null) {
        _emitOAuthFailure();
        return;
      }
      await storage.writeCookie(cookie);
    } catch (_) {
      // Offline, server unreachable, or malformed response — never rethrow.
      _emitOAuthFailure();
    }
  }

  Future<void> signOut() async {
    final cookie = await storage.readCookie();
    // Never transmit the session token over plaintext. On an insecure
    // transport we skip the server round-trip but still clear it locally.
    if (cookie != null && _transportIsSecure) {
      try {
        await _http.post(
          Uri.parse('$licenseApiUrl/api/auth/sign-out'),
          headers: {'cookie': cookie},
        );
      } catch (_) {
        /* best-effort */
      }
    }
    await storage.clearCookie();
    // A pending ticket outliving sign-out would let SignInScreen restore it on
    // the next launch and mint a fresh session the moment the old link is
    // approved — silently undoing the sign-out.
    await _discardQuietly();
  }

  /// Begin a magic-link sign-in. POSTs the email to the cross-device start
  /// endpoint and captures the `antgrid.cross_device_token` bind cookie from the
  /// response. The server emails an approval link to [email].
  Future<MagicLinkSession> startMagicLink(String email) async {
    _assertSecureTransport();
    final http.Response res;
    try {
      res = await _http.post(
        Uri.parse('$licenseApiUrl/api/auth/sign-in/cross-device/start'),
        headers: {
          'content-type': 'application/json',
          'user-agent': _antgridUserAgent(),
        },
        body: jsonEncode({'email': email}),
      );
    } catch (_) {
      // Network failure (offline, DNS, TLS, timeout) → surface as the
      // method's documented AuthException so callers handle it uniformly.
      throw AuthException('Could not reach the sign-in server');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AuthException('Could not send sign-in link');
    }
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      throw AuthException('Unexpected server response');
    }
    final id = body?['id'] as String?;
    final bind = _extractCookie(
      res.headers['set-cookie'],
      'antgrid.cross_device_token',
    );
    if (id == null || bind == null) {
      throw AuthException('Unexpected server response');
    }
    final session = MagicLinkSession(id: id, bindCookie: bind, email: email);
    // Survive the process: the user leaves the app to approve the link, and
    // Android may kill it while backgrounded. [bindCookie] is the only
    // credential that can claim the approval, so an in-memory-only copy leaves
    // an approved sign-in permanently unclaimable.
    //
    // Best-effort: the link is already sent by the time we get here, and this
    // only buys back the relaunch case. A store that won't write must not fail
    // the sign-in the caller can still finish in this process — callers catch
    // [AuthException], so anything else escapes to the top of a UI callback.
    try {
      await storage.writePendingSignIn(
        jsonEncode({
          'id': session.id,
          'bindCookie': session.bindCookie,
          'email': session.email,
          'startedAt': _now().toUtc().toIso8601String(),
        }),
      );
    } catch (_) {}
    return session;
  }

  /// Abandon the pending sign-in, so a later launch does not restore it.
  Future<void> discardPendingMagicLink() => storage.clearPendingSignIn();

  /// The pending sign-in left by a previous [startMagicLink], if one is still
  /// worth polling. Returns null — and drops the entry — when nothing was
  /// started, the record is unreadable, or its link window has lapsed.
  ///
  /// Never throws: callers restore fire-and-forget during widget init, where a
  /// raised error would surface as an unhandled async failure on app launch.
  Future<MagicLinkSession?> restorePendingMagicLink() async {
    try {
      final raw = await storage.readPendingSignIn();
      if (raw == null) return null;
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final id = body['id'] as String?;
      final bindCookie = body['bindCookie'] as String?;
      final startedAt = DateTime.tryParse(body['startedAt'] as String? ?? '');
      if (id == null || bindCookie == null || startedAt == null) {
        throw const FormatException('incomplete pending sign-in');
      }
      if (_now().toUtc().difference(startedAt.toUtc()) >= kMagicLinkWindow) {
        await _discardQuietly();
        return null;
      }
      return MagicLinkSession(
        id: id,
        bindCookie: bindCookie,
        email: body['email'] as String?,
      );
    } catch (_) {
      // Unreadable entry (corrupt, an older schema, or a store that won't open)
      // — drop it rather than wedging sign-in on every launch.
      await _discardQuietly();
      return null;
    }
  }

  /// Best-effort delete: used on paths that must not throw. Dropping the ticket
  /// is always cleanup behind work that already landed — a written session
  /// cookie, a terminal server state — so a store that won't delete must not
  /// cost the caller that result. A ticket left behind is self-limiting: the
  /// row it names is already dead server-side, and [restorePendingMagicLink]
  /// drops it outright once [kMagicLinkWindow] lapses.
  Future<void> _discardQuietly() async {
    try {
      await storage.clearPendingSignIn();
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
    final http.Response res;
    try {
      res = await _http.get(
        Uri.parse('$licenseApiUrl/api/auth/sign-in/cross-device/status'),
        headers: {'cookie': 'antgrid.cross_device_token=${session.bindCookie}'},
      );
    } catch (_) {
      return MagicLinkPoll(status: MagicLinkStatus.error);
    }
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
        await storage.writeCookie(cookie);
        await _discardQuietly();
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
        await _discardQuietly();
        return MagicLinkPoll(status: MagicLinkStatus.expired);
      case 'consumed':
        await _discardQuietly();
        return MagicLinkPoll(status: MagicLinkStatus.consumed);
      case 'unbound':
        await _discardQuietly();
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
    final res = await _http.get(
      Uri.parse('$licenseApiUrl/account/me'),
      headers: {'cookie': cookie},
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>?;
    if (body == null) return null;
    final userId = body['userId'] as String?;
    final email = body['email'] as String?;
    if (userId == null || email == null) return null;
    return CurrentUser(
      userId: userId,
      email: email,
      tier: body['tier'] as String?,
      promotional: body['promotional'] as bool? ?? false,
    );
  }
}
