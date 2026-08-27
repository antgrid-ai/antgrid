import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/ab_log.dart';

/// What a Microsoft Store update check found.
///
/// [mandatory] means at least one pending package update was marked mandatory
/// in Partner Center — the Store's install flow should be launched directly
/// instead of offering an optional prompt.
enum StoreUpdateCheck { none, optional, mandatory }

/// What came of handing off to the Store's download-and-install flow.
///
/// [cancelled] is the Store's entire "pending, not installed" bucket: a user
/// declining the system consent dialog is indistinguishable here from the
/// Store refusing on its own terms (low battery, Wi-Fi required) or from a
/// download still in flight — the native side collapses every non-completed
/// package state into it. Treat it as "offer it again", never as a decision
/// the user made.
///
/// [none] means the pending set cleared before the install started (the Store
/// already applied it); [unavailable] means the channel itself failed — an
/// unpackaged build with no MSIX identity, or a non-Windows host.
enum StoreInstallOutcome { completed, cancelled, none, unavailable }

/// The result of one Store update check: what was found, and which version it
/// would install.
@immutable
class StoreUpdateStatus {
  const StoreUpdateStatus({required this.check, this.version});

  static const StoreUpdateStatus none = StoreUpdateStatus(
    check: StoreUpdateCheck.none,
  );

  final StoreUpdateCheck check;

  /// The pending package's `Major.Minor.Build.Revision`, or null when the
  /// Store did not report one. Null is common and carries no meaning beyond
  /// "unknown" — a caller that names the version needs a nameless fallback.
  final String? version;

  @override
  bool operator ==(Object other) =>
      other is StoreUpdateStatus &&
      other.check == check &&
      other.version == version;

  @override
  int get hashCode => Object.hash(check, version);

  @override
  String toString() => 'StoreUpdateStatus($check, version: $version)';
}

/// Pure mapping from the native channel's reply to a decision, isolated so it
/// can be unit-tested without the platform channel (inert under
/// `flutter test`). Tolerates a malformed/missing reply by resolving to
/// [StoreUpdateCheck.none].
StoreUpdateCheck decideStoreUpdate(Map<Object?, Object?>? reply) {
  if (reply == null) return StoreUpdateCheck.none;
  final count = reply['updateCount'];
  if (count is! int || count <= 0) return StoreUpdateCheck.none;
  return reply['mandatory'] == true
      ? StoreUpdateCheck.mandatory
      : StoreUpdateCheck.optional;
}

/// Pure extraction of the pending package version from the native reply.
///
/// The native side sends dotted decimals, and the empty string when it has
/// nothing to report; anything that is not a dotted-decimal version resolves
/// to null, so a caller can never render a placeholder as a version.
String? storeUpdateVersion(Map<Object?, Object?>? reply) {
  final raw = reply?['version'];
  if (raw is! String) return null;
  final version = raw.trim();
  if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) return null;
  return version;
}

/// Pure mapping from the native install reply to an outcome. Null means the
/// reply was not one of the contract's strings — the caller decides what an
/// unrecognised answer costs.
StoreInstallOutcome? decodeStoreInstallOutcome(Object? reply) =>
    switch (reply) {
      'completed' => StoreInstallOutcome.completed,
      'cancelled' => StoreInstallOutcome.cancelled,
      'none' => StoreInstallOutcome.none,
      _ => null,
    };

/// Thin, Windows-only wrapper over the runner's `antgrid/store_update`
/// method channel (WinRT `StoreContext`, see
/// `windows/runner/store_update_channel.cpp`).
///
/// Every method is a safe no-op off Windows and swallows channel errors —
/// `StoreContext` requires MSIX package identity, so builds not installed
/// from the Microsoft Store (`flutter run`, sideloaded exe) fail the native
/// call and the whole feature must degrade silently rather than surface an
/// error or block startup. Failure arrives as a value, never a throw: callers
/// run from tap handlers and startup paths that discard the future.
class WindowsStoreUpdateService {
  const WindowsStoreUpdateService();

  static const MethodChannel _channel = MethodChannel('antgrid/store_update');

  /// Static because the channel's handler table is process-global and this
  /// class is const-constructible: callers make throwaway instances, so
  /// per-instance state would register a handler per construction.
  static final StreamController<int> _progress =
      StreamController<int>.broadcast();
  static bool _progressHandlerInstalled = false;

  bool get _supported => defaultTargetPlatform == TargetPlatform.windows;

  /// Download progress in whole percent, 0-100, pushed by the Store while
  /// [requestDownloadAndInstall] runs.
  ///
  /// Broadcast and unbuffered: ticks emitted with no listener are dropped, a
  /// late listener sees only what follows it, and the stream never closes or
  /// errors. The Store emits no terminal tick — 100 may never arrive, and the
  /// deploy happens after the last one — so completion is
  /// [requestDownloadAndInstall]'s answer alone.
  Stream<int> get downloadProgress {
    _ensureProgressHandler();
    return _progress.stream;
  }

  /// Asks the Store for pending package updates.
  ///
  /// Never throws — any failure resolves to [StoreUpdateStatus.none].
  Future<StoreUpdateStatus> checkForUpdates() async {
    if (!_supported) return StoreUpdateStatus.none;
    try {
      final reply = await _channel.invokeMapMethod<Object?, Object?>(
        'checkForUpdates',
      );
      final check = decideStoreUpdate(reply);
      if (check == StoreUpdateCheck.none) return StoreUpdateStatus.none;
      return StoreUpdateStatus(
        check: check,
        version: storeUpdateVersion(reply),
      );
    } catch (e) {
      AbLog.warn(
        'StoreUpdate',
        'WindowsStoreUpdateService.checkForUpdates failed (ignored)',
        fields: {'error': '$e'},
      );
      return StoreUpdateStatus.none;
    }
  }

  /// Hands off to the Store's own download-and-install flow (system UI,
  /// parented to the app window). A mandatory update may restart the app on
  /// completion. Never throws.
  ///
  /// Resolves only once the Store reaches a terminal state, which spans the
  /// two system consent dialogs, the download and the deploy — expect minutes,
  /// and read [downloadProgress] to say something in between.
  Future<StoreInstallOutcome> requestDownloadAndInstall() async {
    if (!_supported) return StoreInstallOutcome.unavailable;
    _ensureProgressHandler();
    try {
      final reply = await _channel.invokeMethod<String>(
        'requestDownloadAndInstall',
      );
      final outcome = decodeStoreInstallOutcome(reply);
      if (outcome != null) return outcome;
      AbLog.warn(
        'StoreUpdate',
        'WindowsStoreUpdateService.requestDownloadAndInstall returned an '
            'unrecognised outcome (treated as unavailable)',
        fields: {'reply': '$reply'},
      );
      return StoreInstallOutcome.unavailable;
    } catch (e) {
      AbLog.warn(
        'StoreUpdate',
        'WindowsStoreUpdateService.requestDownloadAndInstall failed (ignored)',
        fields: {'error': '$e'},
      );
      return StoreInstallOutcome.unavailable;
    }
  }

  void _ensureProgressHandler() {
    if (_progressHandlerInstalled) return;
    _progressHandlerInstalled = true;
    try {
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (e) {
      // Reached when there is no ServicesBinding yet (a plain `flutter test`).
      // Leave the latch down so a binding arriving later still gets a handler.
      _progressHandlerInstalled = false;
      AbLog.warn(
        'StoreUpdate',
        'WindowsStoreUpdateService progress handler not installed (ignored)',
        fields: {'error': '$e'},
      );
    }
  }

  static Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'downloadProgress') return null;
    final raw = call.arguments;
    if (raw is! num || !raw.isFinite) return null;
    _progress.add(raw.round().clamp(0, 100).toInt());
    return null;
  }
}
