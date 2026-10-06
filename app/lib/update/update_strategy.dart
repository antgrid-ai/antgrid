import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart';

import '../util/external_url.dart';
import 'github_release_update_service.dart';
import 'in_app_update_service.dart';
import 'ios_app_store_update_service.dart';
import 'macos_appcast_update_service.dart';
import 'macos_sparkle_update_service.dart';
import 'update_check_result.dart';
import 'windows_store_update_service.dart';

// Policy outcomes are distinct from detection: manual checks never apply them.
enum UpdateCheckOutcome {
  none,
  updateAvailable,
  updateAvailableQuiet,
  startDownloadQuiet,
  restartReady,
}

enum UpdateInstallResult {
  handedOff,
  notInstalled,
  nothingPending,
  unavailable,
}

abstract class UpdateStrategy {
  bool get active;
  Future<void> prepare() async {}
  Future<UpdateCheckResult> detect();

  UpdateCheckOutcome automaticOutcome(UpdateCheckResult result) =>
      switch (result.status) {
        UpdateCheckStatus.available => UpdateCheckOutcome.updateAvailable,
        UpdateCheckStatus.restartReady => UpdateCheckOutcome.restartReady,
        _ => UpdateCheckOutcome.none,
      };

  bool get skipAutomaticWhenPending => true;
  bool get skipAutomaticChecks => false;

  Future<UpdateCheckOutcome> check({required bool rowAlreadyLit}) async {
    if (skipAutomaticChecks || rowAlreadyLit && skipAutomaticWhenPending) {
      return UpdateCheckOutcome.none;
    }
    return automaticOutcome(await detect());
  }

  Future<UpdateInstallResult> install(BuildContext context);
  bool get installEndsSession => false;
  Stream<int>? get installProgress => null;
  String? get pendingVersion => null;
  Stream<void>? get updateRetracted => null;
  Stream<UpdateCheckResult>? get statusChanges => null;
  String? get updatedNote => null;
  String get rowTitle => 'Update available';
  String get rowActionLabel => 'Update';
  String actionLabel(UpdateCheckResult result) => rowActionLabel;
  void dispose() {}
}

const kUpdateStoppedSessionsNote = 'Open project sessions were stopped.';

class PlayUpdateStrategy extends UpdateStrategy {
  PlayUpdateStrategy({InAppUpdateService service = const InAppUpdateService()})
    : _service = service;
  final InAppUpdateService _service;
  AppUpdateInfo? _info;
  UpdateAction _action = UpdateAction.none;
  UpdateAction _automaticAction = UpdateAction.none;
  bool _flowRunning = false;
  bool _downloaded = false;
  final _changes = StreamController<UpdateCheckResult>.broadcast();

  @override
  bool get active => true;
  @override
  bool get skipAutomaticWhenPending => false;
  @override
  Stream<UpdateCheckResult> get statusChanges => _changes.stream;

  UpdateCheckResult _result(UpdateCheckStatus status) => UpdateCheckResult(
    status,
    candidateId: _info?.availableVersionCode?.toString(),
  );

  @override
  Future<UpdateCheckResult> detect() async {
    if (_flowRunning) return _result(UpdateCheckStatus.downloading);
    try {
      final info = await _service.check();
      if (_flowRunning) return _result(UpdateCheckStatus.downloading);
      _info = info;
      _downloaded =
          _downloaded || info.installStatus == InstallStatus.downloaded;
      _automaticAction = decideUpdateAction(
        available:
            info.updateAvailability == UpdateAvailability.updateAvailable,
        updateInProgress:
            info.updateAvailability ==
            UpdateAvailability.developerTriggeredUpdateInProgress,
        downloaded: _downloaded,
        updatePriority: info.updatePriority,
        stalenessDays: info.clientVersionStalenessDays ?? 0,
        immediateAllowed: info.immediateUpdateAllowed,
        flexibleAllowed: info.flexibleUpdateAllowed,
      );
      _action = _automaticAction;
      // An explicit update can use the only permitted flow even when the
      // automatic priority policy would wait for a flexible flow.
      if (_action == UpdateAction.none &&
          info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.immediateUpdateAllowed) {
        _action = UpdateAction.immediate;
      }
      if (_downloaded) return _result(UpdateCheckStatus.restartReady);
      if (info.installStatus == InstallStatus.pending ||
          info.installStatus == InstallStatus.downloading ||
          info.installStatus == InstallStatus.installing) {
        // Play requires resuming interrupted immediate flows; a flexible
        // download already owned by Play must not be started a second time.
        if (_action != UpdateAction.resumeImmediate) {
          return _result(UpdateCheckStatus.downloading);
        }
      }
      if (_action != UpdateAction.none) {
        return _result(UpdateCheckStatus.available);
      }
      if (info.updateAvailability == UpdateAvailability.updateNotAvailable) {
        return UpdateCheckResult.upToDate;
      }
      if (info.updateAvailability == UpdateAvailability.unknown) {
        return UpdateCheckResult.failed;
      }
      return const UpdateCheckResult(
        UpdateCheckStatus.unsupported,
        message:
            'Google Play cannot offer an update flow for this build or device.',
      );
    } on MissingPluginException {
      return UpdateCheckResult.unsupported;
    } on PlatformException catch (e) {
      // Play install error -10 is APP_NOT_OWNED (sideloaded/dev builds).
      if (e.message?.contains('(-10)') ?? false) {
        return UpdateCheckResult.unsupported;
      }
      return UpdateCheckResult.failed;
    } catch (_) {
      return UpdateCheckResult.failed;
    }
  }

  @override
  UpdateCheckOutcome automaticOutcome(UpdateCheckResult result) =>
      result.status == UpdateCheckStatus.available
      ? _automaticAction == UpdateAction.none
            ? UpdateCheckOutcome.none
            : UpdateCheckOutcome.startDownloadQuiet
      : super.automaticOutcome(result);

  @override
  Future<UpdateInstallResult> install(BuildContext context) async {
    if (_flowRunning) return UpdateInstallResult.notInstalled;
    if (_downloaded) {
      await _service.completeFlexibleUpdate();
      return UpdateInstallResult.handedOff;
    }
    final action = _action;
    if (action == UpdateAction.none ||
        action == UpdateAction.completeFlexible) {
      return UpdateInstallResult.unavailable;
    }
    _flowRunning = true;
    _changes.add(_result(UpdateCheckStatus.downloading));
    try {
      final result = await _service.start(action);
      if (result != AppUpdateResult.success) {
        _changes.add(_result(UpdateCheckStatus.available));
        return UpdateInstallResult.notInstalled;
      }
      if (action == UpdateAction.flexible) {
        _downloaded = true;
        _action = UpdateAction.completeFlexible;
        _changes.add(_result(UpdateCheckStatus.restartReady));
      }
      return UpdateInstallResult.handedOff;
    } catch (_) {
      _changes.add(_result(UpdateCheckStatus.available));
      return UpdateInstallResult.unavailable;
    } finally {
      _flowRunning = false;
    }
  }

  @override
  String get rowTitle => _downloaded ? 'Update ready' : 'Update available';
  @override
  String get rowActionLabel => _downloaded ? 'Restart' : 'Update';
  @override
  String actionLabel(UpdateCheckResult result) =>
      result.status == UpdateCheckStatus.restartReady ? 'Restart' : 'Update';
  @override
  void dispose() => unawaited(_changes.close());
}

class WindowsStoreStrategy extends UpdateStrategy {
  WindowsStoreStrategy({
    WindowsStoreUpdateService service = const WindowsStoreUpdateService(),
  }) : _service = service;
  final WindowsStoreUpdateService _service;
  bool _mandatoryAutoLaunched = false;
  bool _mandatory = false;
  String? _pendingVersion;
  @override
  bool get active => kReleaseMode;
  @override
  bool get skipAutomaticWhenPending => _mandatoryAutoLaunched;
  @override
  bool get skipAutomaticChecks => _mandatoryAutoLaunched;
  @override
  bool get installEndsSession => true;
  @override
  Stream<int> get installProgress => _service.downloadProgress;
  @override
  String? get pendingVersion => _pendingVersion;

  @override
  Future<UpdateCheckResult> detect() async {
    final status = await _service.checkForUpdates();
    switch (status.check) {
      case StoreUpdateCheck.failed:
        return UpdateCheckResult.failed;
      case StoreUpdateCheck.unsupported:
        return UpdateCheckResult.unsupported;
      case StoreUpdateCheck.none:
        _pendingVersion = null;
        _mandatory = false;
        return UpdateCheckResult.upToDate;
      case StoreUpdateCheck.optional:
      case StoreUpdateCheck.mandatory:
        _pendingVersion = status.version;
        _mandatory = status.check == StoreUpdateCheck.mandatory;
        return UpdateCheckResult(
          UpdateCheckStatus.available,
          version: status.version,
          candidateId: status.version,
        );
    }
  }

  @override
  UpdateCheckOutcome automaticOutcome(UpdateCheckResult result) {
    if (_mandatoryAutoLaunched) return UpdateCheckOutcome.none;
    if (result.status == UpdateCheckStatus.available && _mandatory) {
      _mandatoryAutoLaunched = true;
      return UpdateCheckOutcome.updateAvailableQuiet;
    }
    return super.automaticOutcome(result);
  }

  @override
  Future<UpdateInstallResult> install(BuildContext context) async =>
      switch (await _service.requestDownloadAndInstall()) {
        StoreInstallOutcome.completed => UpdateInstallResult.handedOff,
        StoreInstallOutcome.cancelled => UpdateInstallResult.notInstalled,
        StoreInstallOutcome.none => UpdateInstallResult.nothingPending,
        StoreInstallOutcome.unavailable => UpdateInstallResult.unavailable,
      };
  @override
  String get rowActionLabel => 'Install & restart';
  @override
  String? get updatedNote => kUpdateStoppedSessionsNote;
}

class MacosSparkleStrategy extends UpdateStrategy {
  MacosSparkleStrategy({
    MacosSparkleUpdateService? sparkle,
    MacosAppcastUpdateService? appcast,
  }) : _sparkle = sparkle ?? MacosSparkleUpdateService(),
       _appcast = appcast ?? MacosAppcastUpdateService();
  final MacosSparkleUpdateService _sparkle;
  final MacosAppcastUpdateService _appcast;
  UpdateCheckResult? _candidate;
  String? _installingCandidate;
  final _rejected = <String>{};
  StreamSubscription<void>? _retraction;
  @override
  Stream<UpdateCheckResult> get statusChanges =>
      _sparkle.flowChanges.map((running) {
        if (running) {
          return UpdateCheckResult(
            UpdateCheckStatus.downloading,
            version: _candidate?.version,
            candidateId: _installingCandidate,
          );
        }
        if (_rejected.contains(_installingCandidate)) {
          return const UpdateCheckResult(
            UpdateCheckStatus.unsupported,
            message: 'Sparkle cannot install this update on this Mac.',
          );
        }
        return _candidate ?? UpdateCheckResult.failed;
      });
  @override
  bool get active => kReleaseMode;
  @override
  Future<void> prepare() async {
    _retraction ??= _sparkle.noUpdateFound.listen((_) {
      final id = _installingCandidate;
      if (id != null) _rejected.add(id);
    });
    await _sparkle.configureFeed();
  }

  @override
  String? get pendingVersion => _candidate?.version;
  @override
  String? get updatedNote => kUpdateStoppedSessionsNote;
  @override
  Stream<void> get updateRetracted => _sparkle.noUpdateFound;
  @override
  Future<UpdateCheckResult> detect() async {
    if (_sparkle.flowRunning) {
      return UpdateCheckResult(
        UpdateCheckStatus.downloading,
        version: _candidate?.version,
        candidateId: _installingCandidate,
      );
    }
    final result = await _appcast.check();
    if (_sparkle.flowRunning) {
      return UpdateCheckResult(
        UpdateCheckStatus.downloading,
        version: _candidate?.version,
        candidateId: _installingCandidate,
      );
    }
    if (result.actionable && _rejected.contains(result.candidateId)) {
      return UpdateCheckResult(
        UpdateCheckStatus.unsupported,
        candidateId: result.candidateId,
        message: 'Sparkle cannot install this update on this Mac.',
      );
    }
    if (result.actionable) _candidate = result;
    return result;
  }

  @override
  Future<UpdateInstallResult> install(BuildContext context) async {
    if (_sparkle.flowRunning) return UpdateInstallResult.notInstalled;
    _installingCandidate = _candidate?.candidateId;
    await _sparkle.configureFeed();
    await _sparkle.startUpdate();
    return UpdateInstallResult.handedOff;
  }

  @override
  void dispose() {
    unawaited(_retraction?.cancel());
    _sparkle.dispose();
  }
}

class LinuxBrowserStrategy extends UpdateStrategy {
  LinuxBrowserStrategy({GithubReleaseUpdateService? releases})
    : _releases = releases ?? GithubReleaseUpdateService();
  final GithubReleaseUpdateService _releases;
  String? _version;
  @override
  bool get active => kReleaseMode;
  @override
  String? get pendingVersion => _version;
  @override
  Future<UpdateCheckResult> detect() async {
    final result = await _releases.check();
    if (result.actionable) _version = result.version;
    return result;
  }

  @override
  String actionLabel(UpdateCheckResult result) => 'Open download page';
  @override
  Future<UpdateInstallResult> install(BuildContext context) async {
    await openExternalUrl(
      context,
      GithubReleaseUpdateService.latestDownloadPageUrl,
    );
    return UpdateInstallResult.handedOff;
  }
}

class IosAppStoreStrategy extends UpdateStrategy {
  IosAppStoreStrategy({IosAppStoreUpdateService? service})
    : _service = service ?? IosAppStoreUpdateService();
  final IosAppStoreUpdateService _service;
  String? _version;
  @override
  bool get active => kReleaseMode;
  @override
  String? get pendingVersion => _version;
  @override
  Future<UpdateCheckResult> detect() async {
    final result = await _service.check();
    if (result.actionable) _version = result.version;
    return result;
  }

  @override
  String actionLabel(UpdateCheckResult result) => 'Open App Store';
  @override
  Future<UpdateInstallResult> install(BuildContext context) async {
    final url = _service.listingUrl;
    if (url == null) return UpdateInstallResult.unavailable;
    await openExternalUrl(context, url);
    return UpdateInstallResult.handedOff;
  }
}

final updateStrategyProvider = Provider<UpdateStrategy?>((ref) {
  if (kIsWeb) return null;
  final strategy = switch (defaultTargetPlatform) {
    TargetPlatform.android => PlayUpdateStrategy(),
    TargetPlatform.windows => WindowsStoreStrategy(),
    TargetPlatform.macOS => MacosSparkleStrategy(),
    TargetPlatform.linux => LinuxBrowserStrategy(),
    TargetPlatform.iOS => IosAppStoreStrategy(),
    TargetPlatform.fuchsia => null,
  };
  if (strategy != null) ref.onDispose(strategy.dispose);
  return strategy;
});
