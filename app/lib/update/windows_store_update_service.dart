import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/ab_log.dart';

/// What a Microsoft Store update check found.
///
/// [mandatory] means at least one pending package update was marked mandatory
/// in Partner Center — the Store's install flow should be launched directly
/// instead of offering an optional prompt.
enum StoreUpdateCheck { none, optional, mandatory }

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

/// Thin, Windows-only wrapper over the runner's `antgrid/store_update`
/// method channel (WinRT `StoreContext`, see
/// `windows/runner/store_update_channel.cpp`).
///
/// Every method is a safe no-op off Windows and swallows channel errors —
/// `StoreContext` requires MSIX package identity, so builds not installed
/// from the Microsoft Store (`flutter run`, sideloaded exe) fail the native
/// call and the whole feature must degrade silently rather than surface an
/// error or block startup.
class WindowsStoreUpdateService {
  const WindowsStoreUpdateService();

  static const MethodChannel _channel = MethodChannel('antgrid/store_update');

  bool get _supported => defaultTargetPlatform == TargetPlatform.windows;

  /// Asks the Store for pending package updates.
  ///
  /// Never throws — any failure resolves to [StoreUpdateCheck.none].
  Future<StoreUpdateCheck> checkForUpdates() async {
    if (!_supported) return StoreUpdateCheck.none;
    try {
      final reply = await _channel.invokeMapMethod<Object?, Object?>(
        'checkForUpdates',
      );
      return decideStoreUpdate(reply);
    } catch (e) {
      AbLog.warn(
        'StoreUpdate',
        'WindowsStoreUpdateService.checkForUpdates failed (ignored)',
        fields: {'error': '$e'},
      );
      return StoreUpdateCheck.none;
    }
  }

  /// Hands off to the Store's own download-and-install flow (system UI,
  /// parented to the app window). A mandatory update may restart the app on
  /// completion. Never throws.
  Future<void> requestDownloadAndInstall() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('requestDownloadAndInstall');
    } catch (e) {
      AbLog.warn(
        'StoreUpdate',
        'WindowsStoreUpdateService.requestDownloadAndInstall failed (ignored)',
        fields: {'error': '$e'},
      );
    }
  }
}
