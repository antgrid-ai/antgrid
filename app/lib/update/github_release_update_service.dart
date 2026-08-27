import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';

import '../util/ab_log.dart';

/// Pure "is the released tag newer than what's installed?" comparison,
/// isolated so it can be unit-tested without network or platform channels.
///
/// pub_semver precedence already does the right thing for every input we
/// see: the installed version's build metadata (`1.0.6+7`) never outranks
/// its own triple, and a tag prerelease suffix (`v1.1.0-beta.1`) sorts below
/// its release — defensive only, since the feed below is `releases/latest`,
/// which GitHub never points at a prerelease. Malformed input on either side
/// resolves to `false` (never prompt on garbage).
bool isNewerVersion({required String current, required String latestTag}) {
  var tag = latestTag.trim();
  if (tag.startsWith('v') || tag.startsWith('V')) tag = tag.substring(1);
  try {
    return Version.parse(tag) > Version.parse(current.trim());
  } on FormatException {
    return false;
  }
}

/// Asks GitHub whether `antgrid` carries a newer desktop release
/// than the running build.
///
/// This is detection only — installing is someone else's job (Sparkle on
/// macOS; the releases download page on Linux). The repo is
/// public, so the unauthenticated API suffices; `UpdateGate`'s 30-minute
/// throttle keeps us far under the 60 req/hr anonymous rate limit.
///
/// Never throws — any failure (offline, rate-limited, malformed reply)
/// resolves to `false`.
class GithubReleaseUpdateService {
  GithubReleaseUpdateService({http.Client? httpClient})
    : _injected = httpClient;

  /// Test seam only. When null, each check uses a short-lived client closed
  /// before returning — checks are ≥30 min apart, so a persistent pool would
  /// only hold dead keep-alive sockets (and nothing ever closes this class).
  final http.Client? _injected;

  /// The installed version can't change while the process runs. Cached as a
  /// value, not a future, so a transient channel failure is retried on the
  /// next check instead of being memoized forever.
  PackageInfo? _packageInfo;

  /// `releases/latest` excludes prereleases and drafts, matching the build
  /// workflow's rule that a prerelease tag never moves the stable channel.
  static const String latestReleaseUrl =
      'https://api.github.com/repos/antgrid-ai/antgrid/releases/latest';

  /// Human-facing release page. Linux's update row opens this in the browser
  /// rather than direct-downloading the AppImage: replacing an AppImage is a
  /// manual step, and the page carries the per-asset install notes.
  static const String latestDownloadPageUrl =
      'https://github.com/antgrid-ai/antgrid/releases/latest';

  Future<bool> isUpdateAvailable() async {
    final client = _injected ?? http.Client();
    try {
      final info = _packageInfo ??= await PackageInfo.fromPlatform();
      // package_info_plus's Linux implementation returns '' for every field
      // when its version.json lookup fails (e.g. a packaging change moved the
      // bundle relative to /proc/self/exe). isNewerVersion would then resolve
      // false forever with no signal — make that failure mode loud.
      if (info.version.isEmpty) {
        AbLog.warn('Update', 'PackageInfo.version is empty (check skipped)');
        return false;
      }
      final res = await client
          .get(
            Uri.parse(latestReleaseUrl),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        AbLog.warn(
          'Update',
          'release check got non-200 (ignored)',
          fields: {'status': '${res.statusCode}'},
        );
        return false;
      }
      final body = jsonDecode(res.body);
      final tag = body is Map<String, Object?> ? body['tag_name'] : null;
      if (tag is! String) return false;
      return isNewerVersion(current: info.version, latestTag: tag);
    } catch (e) {
      AbLog.warn(
        'Update',
        'GithubReleaseUpdateService.isUpdateAvailable failed (ignored)',
        fields: {'error': '$e'},
      );
      return false;
    } finally {
      if (_injected == null) client.close();
    }
  }
}
