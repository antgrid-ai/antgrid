import 'dart:async';

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
class MacosSparkleUpdateService implements UpdaterListener {
  MacosSparkleUpdateService();

  /// Published as a release asset by build-desktop.yml; `releases/latest`
  /// makes this URL stable across versions (prereleases never move it).
  /// Derived so the releases owner/repo lives in exactly one Dart constant.
  static const String appcastUrl =
      '${GithubReleaseUpdateService.latestDownloadPageUrl}/download/appcast.xml';

  final _noUpdateFound = StreamController<void>.broadcast();
  bool _listening = false;

  bool get _supported => defaultTargetPlatform == TargetPlatform.macOS;

  /// Fires when Sparkle's own check disagrees with the appcast read that lit
  /// the row: it looked at the same feed and found nothing it will install.
  ///
  /// The two can differ honestly. `MacosAppcastUpdateService` takes the newest
  /// `<item>`'s `sparkle:version`; Sparkle additionally honours
  /// `minimumSystemVersion` and the item's channel, so a release built for a
  /// newer macOS than the user runs is advertised to us and refused by
  /// Sparkle. Without this the row stays lit for the rest of the process — and
  /// re-lights on every launch — over an Update button that can never do
  /// anything.
  Stream<void> get noUpdateFound => _noUpdateFound.stream;

  /// Points Sparkle at the appcast. Must have run once before [startUpdate];
  /// `UpdateGate` calls it at startup on macOS. Never throws.
  Future<void> configureFeed() async {
    if (!_supported) return;
    // Registered here rather than in the constructor: the strategy is built on
    // every platform (the provider table is one list) and only macOS has a
    // plugin to talk to. Latched because configureFeed is deliberately
    // idempotent and runs again on every install.
    if (!_listening) {
      _listening = true;
      try {
        autoUpdater.addListener(this);
      } catch (e) {
        _listening = false;
        AbLog.warn(
          'Update',
          'MacosSparkleUpdateService.addListener failed (ignored)',
          fields: {'error': '$e'},
        );
      }
    }
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

  /// Detaches from Sparkle and closes [noUpdateFound].
  ///
  /// `autoUpdater` is a process-global singleton that holds listeners by strong
  /// reference and never drops them on its own, so an instance that skips this
  /// stays registered — and keeps answering delegate callbacks on a closed
  /// controller — for the rest of the process.
  void dispose() {
    if (_listening) {
      _listening = false;
      try {
        autoUpdater.removeListener(this);
      } catch (e) {
        AbLog.warn(
          'Update',
          'MacosSparkleUpdateService.removeListener failed (ignored)',
          fields: {'error': '$e'},
        );
      }
    }
    unawaited(_noUpdateFound.close());
  }

  // --- UpdaterListener -----------------------------------------------------
  //
  // Sparkle drives its own UI through SPUStandardUserDriver: it shows the
  // release notes, the progress, the errors and its own "You're up to date".
  // So these callbacks are for what the UI cannot do — retracting a row we lit
  // ourselves, and leaving a trace for a field report. Deliberately no toast:
  // a second opinion beside Sparkle's open dialog can only contradict it.

  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    AbLog.info('Update', 'Sparkle found nothing to install; clearing the row');
    if (!_noUpdateFound.isClosed) _noUpdateFound.add(null);
  }

  @override
  void onUpdaterError(UpdaterError? error) {
    // The plugin forwards only `localizedDescription` — no code, no domain —
    // and Sparkle routes a user cancellation through the same delegate as a
    // real failure. So this can be logged and never classified.
    AbLog.warn(
      'Update',
      'Sparkle aborted (cancelled or failed — indistinguishable here)',
      fields: {'error': '${error?.message}'},
    );
  }

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {}

  @override
  void onUpdaterUpdateAvailable(AppcastItem? appcastItem) {}

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? appcastItem) {}

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? appcastItem) {}
}
