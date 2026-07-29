import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';

import '../util/ab_log.dart';
import 'github_release_update_service.dart' show isNewerVersion;

/// Pure interpretation of one iTunes lookup reply, isolated so it can be
/// unit-tested without network or platform channels.
///
/// `updateAvailable` is true only when the reply also carries a usable
/// `trackViewUrl` — an update the row can't route the user to is a dead
/// affordance — and when the listing's `minimumOsVersion` doesn't exclude
/// [deviceOsVersion] (the App Store would show that device "Open", not
/// "Update", forever). The OS gate fails OPEN on missing/unparseable input:
/// it exists to avoid a permanently dead row, not to be a second version
/// check. Everything else malformed resolves to unavailable (never prompt
/// on garbage).
({bool updateAvailable, String? listingUrl}) decideIosStoreUpdate({
  required Object? lookupJson,
  required String installedVersion,
  required String? deviceOsVersion,
}) {
  const none = (updateAvailable: false, listingUrl: null);
  if (lookupJson is! Map<String, Object?>) return none;
  final results = lookupJson['results'];
  // Empty results is the NORMAL reply for an app not (yet) published in the
  // queried storefront, not an error shape.
  if (results is! List || results.isEmpty) return none;
  final first = results.first;
  if (first is! Map<String, Object?>) return none;
  final storeVersion = first['version'];
  final listingUrl = first['trackViewUrl'];
  // isEmpty: a present-but-empty URL would pass the type check and light a
  // row whose tap opens nothing — the exact dead affordance gated above.
  if (storeVersion is! String || listingUrl is! String || listingUrl.isEmpty) {
    return none;
  }
  if (!isNewerVersion(current: installedVersion, latestTag: storeVersion)) {
    return none;
  }
  final minOs = first['minimumOsVersion'];
  if (minOs is String && deviceOsVersion != null) {
    final floor = _looseVersion(minOs);
    final device = _looseVersion(deviceOsVersion);
    if (floor != null && device != null && device < floor) return none;
  }
  return (updateAvailable: true, listingUrl: listingUrl);
}

/// OS versions aren't semver — Apple reports "18", "18.5" or "18.5.1" — so
/// pad missing components instead of letting `Version.parse` reject them.
Version? _looseVersion(String s) {
  final m = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(s.trim());
  if (m == null) return null;
  return Version(
    int.parse(m[1]!),
    int.parse(m[2] ?? '0'),
    int.parse(m[3] ?? '0'),
  );
}

/// iTunes' `country` param accepts ISO-3166 alpha-2 only, but a Flutter
/// locale's countryCode can be a UN M49 numeric region instead — "es_419"
/// (Spanish, Latin America) yields "419". Passing that back gets an HTTP-200
/// error body with no `results` key, which reads as "no update" forever, so
/// anything non-alpha-2 falls back to the default storefront instead.
String? storefrontCountry(String? countryCode) {
  if (countryCode == null) return null;
  if (!RegExp(r'^[A-Za-z]{2}$').hasMatch(countryCode)) return null;
  return countryCode;
}

Future<String?> _deviceSystemVersion() async {
  try {
    return (await DeviceInfoPlugin().iosInfo).systemVersion;
  } catch (e) {
    // Fail open — the OS-floor gate is best-effort (see decideIosStoreUpdate).
    AbLog.warn(
      'Update',
      'iOS systemVersion read failed (OS gate skipped)',
      fields: {'error': '$e'},
    );
    return null;
  }
}

/// Asks the App Store whether it carries a newer version than the running
/// build, via the iTunes lookup API keyed on our bundle id.
///
/// This is detection only — iOS apps cannot self-update, so the row's tap
/// opens the store listing ([listingUrl]) and the App Store owns the install.
/// The lookup is unauthenticated and served from Apple's CDN, which caches
/// replies for up to ~a day — a fresh release can take that long to light
/// the row, which is fine (the store itself rolls releases out gradually).
///
/// Never throws — any failure (offline, malformed reply, unpublished app)
/// resolves to `false`.
class IosAppStoreUpdateService {
  IosAppStoreUpdateService({
    http.Client? httpClient,
    Future<String?> Function()? systemVersion,
  }) : _injected = httpClient,
       _systemVersion = systemVersion ?? _deviceSystemVersion;

  /// Test seam only. When null, each check uses a short-lived client closed
  /// before returning — checks are ≥30 min apart, so a persistent pool would
  /// only hold dead keep-alive sockets (and nothing ever closes this class).
  final http.Client? _injected;

  final Future<String?> Function() _systemVersion;

  /// Both immutable for the process lifetime. Cached as values, not futures,
  /// so a transient failure is retried on the next check instead of being
  /// memoized forever.
  PackageInfo? _packageInfo;
  String? _osVersion;

  /// The store listing URL (`trackViewUrl`) from the last check that found an
  /// update; null until then. `UpdateRow`'s tap opens this — it must come
  /// from the reply because the App Store numeric app id appears nowhere in
  /// the repo, and hardcoding it would break silently if the listing moved.
  String? get listingUrl => _listingUrl;
  String? _listingUrl;

  static const String lookupAuthority = 'itunes.apple.com';
  static const String lookupPath = '/lookup';

  Future<bool> isUpdateAvailable() async {
    final client = _injected ?? http.Client();
    try {
      final info = _packageInfo ??= await PackageInfo.fromPlatform();
      // Same silent-forever failure mode the GitHub service guards: an empty
      // version makes isNewerVersion resolve false on every check.
      if (info.version.isEmpty) {
        AbLog.warn('Update', 'PackageInfo.version is empty (check skipped)');
        return false;
      }
      final os = _osVersion ??= await _systemVersion();
      // Storefronts differ per country — a lookup without `country` queries
      // the US store, where an app released elsewhere may not exist.
      final country = storefrontCountry(
        PlatformDispatcher.instance.locale.countryCode,
      );
      final uri = Uri.https(lookupAuthority, lookupPath, {
        'bundleId': info.packageName,
        'country': ?country,
      });
      final res = await client.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        AbLog.warn(
          'Update',
          'App Store lookup got non-200 (ignored)',
          fields: {'status': '${res.statusCode}'},
        );
        return false;
      }
      final decision = decideIosStoreUpdate(
        lookupJson: jsonDecode(res.body),
        installedVersion: info.version,
        deviceOsVersion: os,
      );
      if (decision.updateAvailable) _listingUrl = decision.listingUrl;
      return decision.updateAvailable;
    } catch (e) {
      AbLog.warn(
        'Update',
        'IosAppStoreUpdateService.isUpdateAvailable failed (ignored)',
        fields: {'error': '$e'},
      );
      return false;
    } finally {
      if (_injected == null) client.close();
    }
  }
}
