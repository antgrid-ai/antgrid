import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/external_url.dart';
import 'github_release_update_service.dart';
import 'in_app_update_service.dart';
import 'ios_app_store_update_service.dart';
import 'macos_appcast_update_service.dart';
import 'macos_sparkle_update_service.dart';
import 'windows_store_update_service.dart';

/// What one throttled update check concluded.
enum UpdateCheckOutcome {
  /// Nothing to surface.
  none,

  /// A newer version is waiting — light the drawer row
  /// (`updateAvailableProvider`) and announce the first light-up.
  updateAvailable,

  /// Like [updateAvailable], but the platform has ALREADY put its own
  /// install UI on screen (Windows' auto-launched mandatory Store flow) —
  /// light the row (the re-launch affordance after a cancel) without an
  /// announcement toast stacking on top of the system dialog.
  updateAvailableQuiet,

  /// Android only: a flexible Play update finished downloading — prompt for
  /// a restart-to-install. The gate also lights the drawer row, whose tap
  /// routes to the same [UpdateStrategy.install], so a missed prompt still
  /// leaves a durable affordance.
  restartReady,
}

/// One platform's complete update wiring: whether checks run in this build,
/// how a check detects, and what accepting the update does.
///
/// This is THE per-platform table. `UpdateGate` (check cadence + outcome
/// routing) and `UpdateRow` (the tap) both resolve [updateStrategyProvider],
/// so a platform cannot light the row without also carrying an install
/// route — detection, row copy, and install can only move in lockstep
/// because they live on one object.
abstract class UpdateStrategy {
  /// Whether checks run at all in this build. Release-only wherever a dev
  /// build can't be updated by its own store/feed — each subclass documents
  /// its platform's reason.
  bool get active;

  /// One-time startup hook, called before any check. Default: nothing.
  Future<void> prepare() async {}

  /// One update check. [rowAlreadyLit] lets a strategy skip network/IPC work
  /// once the latched row can't change anything further. Never throws.
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit});

  /// The user accepted the affordance — the drawer row's tap, or Android's
  /// restart-toast action. Never throws, surfaces its own UI, and tolerates
  /// a repeat invocation by re-opening the flow.
  Future<void> install(BuildContext context);

  /// Copy for the drawer row this strategy's outcomes light. The default
  /// promises a download/store hand-off; a strategy whose [install] does
  /// something stronger must say so (Play's restarts the app in place).
  String get rowTitle => 'Update available';
  String get rowActionLabel => 'Update';
}

/// Android: Google Play owns download and install; the app's only UI duty is
/// the restart prompt for a flexible update that finished downloading.
/// Active in every build mode — the Play path already degrades silently when
/// the build didn't come from Play.
class PlayUpdateStrategy extends UpdateStrategy {
  PlayUpdateStrategy({InAppUpdateService service = const InAppUpdateService()})
    : _service = service;

  final InAppUpdateService _service;

  @override
  bool get active => true;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    final decision = await _service.checkAndStart();
    return decision == UpdateDecision.flexibleReady
        ? UpdateCheckOutcome.restartReady
        : UpdateCheckOutcome.none;
  }

  @override
  Future<void> install(BuildContext context) =>
      _service.completeFlexibleUpdate();

  // The only outcome that lights the row here is a DOWNLOADED update, and
  // completeFlexibleUpdate restarts the app immediately — 'Update' would
  // promise less than the tap performs mid-session.
  @override
  String get rowTitle => 'Update ready';
  @override
  String get rowActionLabel => 'Restart';
}

/// Windows: the Microsoft Store detects and installs. Release-only — a build
/// without MSIX package identity just churns store_unavailable errors on
/// every check.
class WindowsStoreStrategy extends UpdateStrategy {
  WindowsStoreStrategy({
    WindowsStoreUpdateService service = const WindowsStoreUpdateService(),
  }) : _service = service;

  final WindowsStoreUpdateService _service;

  /// At most one auto-launched mandatory flow per process: the update stays
  /// mandatory until installed, so without the latch every ≥30-min refocus
  /// would re-pop the system dialog the user just cancelled. Lives here —
  /// provider-held, outliving any widget — so a gate remount can't reset it.
  bool _mandatoryAutoLaunched = false;

  @override
  bool get active => kReleaseMode;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    // Once the mandatory flow has auto-launched, the row is lit and the
    // latch is spent — nothing a further check finds can change anything, so
    // skip the Store round-trip (an out-of-process licensing-service call).
    // While only an OPTIONAL update is pending we keep checking: a later
    // check may see it escalate to mandatory and auto-launch.
    if (_mandatoryAutoLaunched) return UpdateCheckOutcome.none;
    final check = await _service.checkForUpdates();
    if (check == StoreUpdateCheck.none) return UpdateCheckOutcome.none;
    if (check == StoreUpdateCheck.mandatory) {
      // Partner Center marked the release mandatory — hand straight off to
      // the Store's install flow (which owns the UI and may restart the app)
      // instead of waiting for a click. Service never throws. Quiet: the
      // system dialog is already the announcement; the lit drawer row
      // remains the re-launch affordance after a cancel.
      _mandatoryAutoLaunched = true;
      unawaited(_service.requestDownloadAndInstall());
      return UpdateCheckOutcome.updateAvailableQuiet;
    }
    return UpdateCheckOutcome.updateAvailable;
  }

  @override
  Future<void> install(BuildContext context) =>
      _service.requestDownloadAndInstall();
}

/// macOS: detection and install read the SAME appcast, so a lit row implies
/// Sparkle has something installable. Install is Sparkle's own dialog
/// (download, verify, install, relaunch).
///
/// Release-only: neither Sparkle nor a GitHub release can update an
/// unpackaged `flutter run` bundle.
class MacosSparkleStrategy extends UpdateStrategy {
  MacosSparkleStrategy({
    MacosSparkleUpdateService sparkle = const MacosSparkleUpdateService(),
    MacosAppcastUpdateService? appcast,
  }) : _sparkle = sparkle,
       _appcast = appcast ?? MacosAppcastUpdateService();

  final MacosSparkleUpdateService _sparkle;
  final MacosAppcastUpdateService _appcast;

  @override
  bool get active => kReleaseMode;

  /// Sparkle needs the feed URL before [install] can start; this local call
  /// completes long before the first check's network round-trip can light
  /// the row.
  @override
  Future<void> prepare() => _sparkle.configureFeed();

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    // The row latches for the process lifetime — once lit a further check
    // can't change anything, so skip the fetch.
    if (rowAlreadyLit) return UpdateCheckOutcome.none;
    return await _appcast.isUpdateAvailable()
        ? UpdateCheckOutcome.updateAvailable
        : UpdateCheckOutcome.none;
  }

  @override
  Future<void> install(BuildContext context) async {
    // Re-assert the feed first: prepare() is fire-and-forget at startup and
    // swallows failures, and a feed-less Sparkle errors (silently) on every
    // startUpdate — this idempotent local call un-deadens the row's tap.
    await _sparkle.configureFeed();
    await _sparkle.startUpdate();
  }
}

/// Linux: GitHub-release detection; install opens the releases page in the
/// browser — replacing an AppImage is a manual step, and the page carries
/// the per-asset install notes. Unlike macOS there is no second document to
/// drift from: the row points at the very page it detected.
///
/// Release-only: a dev build always trails the released tag, so the row
/// would light forever.
class LinuxBrowserStrategy extends UpdateStrategy {
  LinuxBrowserStrategy({GithubReleaseUpdateService? releases})
    : _releases = releases ?? GithubReleaseUpdateService();

  final GithubReleaseUpdateService _releases;

  @override
  bool get active => kReleaseMode;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    // Skipping a lit row's re-check also stops burning the shared anonymous
    // GitHub API quota (60 req/hr per source IP).
    if (rowAlreadyLit) return UpdateCheckOutcome.none;
    return await _releases.isUpdateAvailable()
        ? UpdateCheckOutcome.updateAvailable
        : UpdateCheckOutcome.none;
  }

  @override
  Future<void> install(BuildContext context) => openExternalUrl(
    context,
    GithubReleaseUpdateService.latestDownloadPageUrl,
  );
}

/// iOS: iTunes-lookup detection; install opens the App Store listing (iOS
/// apps cannot self-update). Release-only — only an App Store install can be
/// updated by the store, so a dev build would light the row against a
/// published listing it didn't come from.
class IosAppStoreStrategy extends UpdateStrategy {
  IosAppStoreStrategy({IosAppStoreUpdateService? service})
    : _service = service ?? IosAppStoreUpdateService();

  final IosAppStoreUpdateService _service;

  @override
  bool get active => kReleaseMode;

  @override
  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    // Same latch skip as the GitHub strategies — once the row is lit the
    // lookup round-trip can't change anything.
    if (rowAlreadyLit) return UpdateCheckOutcome.none;
    return await _service.isUpdateAvailable()
        ? UpdateCheckOutcome.updateAvailable
        : UpdateCheckOutcome.none;
  }

  @override
  Future<void> install(BuildContext context) {
    // Cached by this same instance's check that lit the row, so it's
    // non-null on every reachable path here.
    final url = _service.listingUrl;
    assert(url != null, 'iOS update row lit without a store listing URL');
    if (url == null) return Future.value();
    return openExternalUrl(context, url);
  }
}

/// The running platform's update wiring, or null where none exists. One
/// instance per app: strategies carry cross-call state (Windows' mandatory
/// launch latch, iOS' cached listing URL), so `UpdateGate`'s check and
/// `UpdateRow`'s tap must land on the same object.
///
/// The switch is exhaustive over [TargetPlatform] on purpose — a new
/// platform is a compile error here, not a silently dead update path.
final updateStrategyProvider = Provider<UpdateStrategy?>(
  (_) => switch (defaultTargetPlatform) {
    TargetPlatform.android => PlayUpdateStrategy(),
    TargetPlatform.windows => WindowsStoreStrategy(),
    TargetPlatform.macOS => MacosSparkleStrategy(),
    TargetPlatform.linux => LinuxBrowserStrategy(),
    TargetPlatform.iOS => IosAppStoreStrategy(),
    TargetPlatform.fuchsia => null,
  },
);
