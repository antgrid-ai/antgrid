import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xml/xml.dart';

import '../util/ab_log.dart';
import 'macos_sparkle_update_service.dart';

/// Pure "would Sparkle offer this appcast item?" comparison.
///
/// Deliberately compares CFBundleVersion — Sparkle's own install decision
/// uses `sparkle:version`, NOT the human-facing `shortVersionString`, so
/// anything else here can light a row that Sparkle then reports as
/// up-to-date. Both sides are integers by construction (CI stamps
/// `--build-number` and `<sparkle:version>` from the same run counter);
/// anything unparseable resolves to `false`, never a phantom update.
bool isNewerBuild({required String currentBuild, required String appcastBuild}) {
  final current = int.tryParse(currentBuild.trim());
  final appcast = int.tryParse(appcastBuild.trim());
  if (current == null || appcast == null) return false;
  return appcast > current;
}

/// Asks the Sparkle appcast whether it advertises a build newer than the
/// running one.
///
/// macOS detects from the SAME document Sparkle installs from, rather than
/// from the GitHub releases API, so a lit drawer row implies Sparkle has
/// something installable. The two can otherwise drift: publishing the dmg
/// and publishing the appcast are separate workflow steps and the appcast
/// one is gated on signing secrets, so an API-driven row lights on every
/// release whose appcast step was skipped and then dead-ends in Sparkle's
/// "error in retrieving update information" dialog, permanently.
///
/// Never throws — any failure (offline, 404, malformed feed) resolves to
/// `false`. Fail-closed is the whole point: a missing appcast is exactly the
/// case where the row must stay dark.
class MacosAppcastUpdateService {
  MacosAppcastUpdateService({http.Client? httpClient}) : _injected = httpClient;

  /// Test seam only. When null, each check uses a short-lived client closed
  /// before returning — checks are ≥30 min apart, so a persistent pool would
  /// only hold dead keep-alive sockets.
  final http.Client? _injected;

  /// The installed build can't change while the process runs. Cached as a
  /// value, not a future, so a transient channel failure is retried on the
  /// next check instead of being memoized forever.
  PackageInfo? _packageInfo;

  Future<bool> isUpdateAvailable() async {
    final client = _injected ?? http.Client();
    try {
      final info = _packageInfo ??= await PackageInfo.fromPlatform();
      if (info.buildNumber.isEmpty) {
        AbLog.warn('Update', 'PackageInfo.buildNumber is empty (check skipped)');
        return false;
      }
      final res = await client
          .get(Uri.parse(MacosSparkleUpdateService.appcastUrl))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        AbLog.warn(
          'Update',
          'appcast fetch got non-200 (ignored)',
          fields: {'status': '${res.statusCode}'},
        );
        return false;
      }
      final advertised = _firstItemVersion(res.body);
      if (advertised == null) return false;
      return isNewerBuild(
        currentBuild: info.buildNumber,
        appcastBuild: advertised,
      );
    } catch (e) {
      AbLog.warn(
        'Update',
        'MacosAppcastUpdateService.isUpdateAvailable failed (ignored)',
        fields: {'error': '$e'},
      );
      return false;
    } finally {
      if (_injected == null) client.close();
    }
  }

  /// `<sparkle:version>` of the feed's FIRST `<item>`, or null if the
  /// document is unusable.
  ///
  /// Scoped to one item rather than searching the whole document: the feed
  /// grows a version history over time, and a document-wide search would
  /// happily read an older entry's build number.
  String? _firstItemVersion(String body) {
    try {
      final item = XmlDocument.parse(
        body,
      ).findAllElements('item').firstOrNull;
      if (item == null) {
        AbLog.warn('Update', 'appcast has no <item> (check skipped)');
        return null;
      }
      // Namespace wildcard: the element is `sparkle:version`, and pinning the
      // prefix would break on a feed that binds the namespace differently.
      final version = item
          .findElements('version', namespace: '*')
          .firstOrNull
          ?.innerText;
      if (version == null || version.trim().isEmpty) {
        AbLog.warn('Update', 'appcast item has no sparkle:version');
        return null;
      }
      return version;
    } on XmlException catch (e) {
      AbLog.warn(
        'Update',
        'appcast is not well-formed XML (ignored)',
        fields: {'error': '$e'},
      );
      return null;
    }
  }
}
