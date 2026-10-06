import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config/storage_scope.dart' show storageScopeOverride;
import '../launcher/host_discovery.dart' show hostDir;

const String kAppLogFileName = 'app.log';

/// The headless push isolate on a phone writes here, not to [kAppLogFileName]:
/// two isolates each rotating one file would race on its `.old` generation.
const String kPushLogFileName = 'app-push.log';

/// Android and iOS have no home directory the app can write to, so hostDir()
/// (USERPROFILE/HOME) resolves to an unwritable or unreachable path there.
/// Those platforms keep their logs in the app's own sandbox instead (see
/// [mobileLogBaseDirectory]).
bool logsLiveInAppSupport(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;

/// The log directory when it is knowable synchronously (desktop: hostDir(),
/// unchanged, so app.log stays beside the spawned host's host.log). Null where
/// it needs the async support-directory lookup.
String? syncLogDir({TargetPlatform? platform}) =>
    logsLiveInAppSupport(platform ?? defaultTargetPlatform) ? null : hostDir();

/// Mirrors hostDir()'s release/dev/scope split so a dev build and a release
/// build never write one file. The split is kept although the two builds share
/// an application id on a phone: a reinstall over the other build inherits its
/// sandbox, and the suffix costs nothing.
String mobileLogDir(
  String supportDir, {
  bool release = kReleaseMode,
  String scope = storageScopeOverride,
}) {
  if (release) return '$supportDir/logs';
  return '$supportDir/logs-dev${scope.isEmpty ? '' : '-$scope'}';
}

/// The directory the mobile log directory hangs off. iOS backs up Application
/// Support to iCloud and device backups, and up to two rotated generations of
/// diagnostics do not belong there; Library/Caches is excluded from backups and
/// the OS may purge it, which a debug log can afford. Android's backup rules
/// already keep these files out, so it stays on the support directory.
Future<Directory> mobileLogBaseDirectory({
  TargetPlatform? platform,
  Future<Directory> Function() support = getApplicationSupportDirectory,
  Future<Directory> Function() cache = getApplicationCacheDirectory,
}) => (platform ?? defaultTargetPlatform) == TargetPlatform.iOS
    ? cache()
    : support();

Future<String> resolveMobileLogDir({
  Future<Directory> Function()? supportDir,
}) async =>
    mobileLogDir((await (supportDir ?? mobileLogBaseDirectory)()).path);
