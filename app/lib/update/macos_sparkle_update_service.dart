import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';

import '../util/ab_log.dart';
import 'github_release_update_service.dart';

/// macOS-only wrapper over Sparkle (via `auto_updater`).
///
/// Detection is NOT Sparkle's job here — `MacosAppcastUpdateService` decides
/// whether the drawer row lights up, silently, by reading [appcastUrl]: the
/// very document this class installs from, so a lit row always has something
/// Sparkle can install. Sparkle only takes over when
/// the user clicks: [startUpdate] opens its standard dialog, which downloads,
/// verifies (Developer ID / EdDSA), installs, and relaunches. Scheduled
/// Sparkle checks are disabled in Info.plist (`SUEnableAutomaticChecks`) so
/// it never shows UI on its own.
///
/// Every method is a safe no-op off macOS and swallows plugin errors — an
/// unpackaged dev build has no Sparkle to talk to and the feature must
/// degrade silently rather than block startup.
class MacosSparkleUpdateService {
  const MacosSparkleUpdateService();

  /// Published as a release asset by build-desktop.yml; `releases/latest`
  /// makes this URL stable across versions (prereleases never move it).
  /// Derived so the releases owner/repo lives in exactly one Dart constant.
  static const String appcastUrl =
      '${GithubReleaseUpdateService.latestDownloadPageUrl}/download/appcast.xml';

  bool get _supported => defaultTargetPlatform == TargetPlatform.macOS;

  /// Points Sparkle at the appcast. Must have run once before [startUpdate];
  /// `UpdateGate` calls it at startup on macOS. Never throws.
  Future<void> configureFeed() async {
    if (!_supported) return;
    try {
      await autoUpdater.setFeedURL(appcastUrl);
    } catch (e) {
      AbLog.warn(
        'Update',
        'MacosSparkleUpdateService.configureFeed failed (ignored)',
        fields: {'error': '$e'},
      );
    }
  }

  /// Opens Sparkle's update flow (its own dialog: release notes → Install →
  /// relaunch). A repeat call just re-opens it. Never throws.
  Future<void> startUpdate() async {
    if (!_supported) return;
    try {
      await autoUpdater.checkForUpdates();
    } catch (e) {
      AbLog.warn(
        'Update',
        'MacosSparkleUpdateService.startUpdate failed (ignored)',
        fields: {'error': '$e'},
      );
    }
  }
}
