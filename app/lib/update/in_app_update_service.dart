import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';

/// Immediate (blocking) update kicks in only for important or very-stale
/// releases; everything else takes the flexible (background-download) path.
/// `updatePriority` is 0..5, set per-release in the Play Console / Developer API.
const int kImmediatePriorityThreshold = 4;
const int kImmediateStalenessDays = 14;

/// Which Play update flow a given [AppUpdateInfo] should drive.
///
/// [resumeImmediate] and [completeFlexible] cover updates Play has *already*
/// started on a prior run — an immediate flow the user backgrounded before it
/// finished, or a flexible update that finished downloading but was never
/// installed. Both surface on subsequent `checkForUpdate` calls as
/// `developerTriggeredUpdateInProgress` / `installStatus == downloaded`, and
/// must be re-driven rather than treated as "no update".
enum UpdateAction {
  none,
  immediate,
  flexible,
  resumeImmediate,
  completeFlexible,
}

/// Outcome of [InAppUpdateService.checkAndStart], for the caller's UI decision.
/// [flexibleReady] means a flexible update finished downloading and the app
/// should prompt the user to restart-to-install.
enum UpdateDecision { none, immediate, flexibleReady }

/// Pure decision core — the priority-based hybrid rule, isolated so it can be
/// unit-tested without the plugin's platform channel (which is inert under
/// `flutter test`).
UpdateAction decideUpdateAction({
  required bool available,
  required bool updateInProgress,
  required bool downloaded,
  required int updatePriority,
  required int stalenessDays,
  required bool immediateAllowed,
  required bool flexibleAllowed,
}) {
  // A flexible update that finished downloading needs an explicit install —
  // surface the restart prompt regardless of the availability field, so a
  // download whose "Update ready" prompt was missed is re-offered on the next
  // check instead of sitting orphaned forever.
  if (downloaded) return UpdateAction.completeFlexible;

  // Play already started an update that hasn't finished (e.g. the user
  // backgrounded the immediate full-screen flow). Play requires resuming an
  // interrupted immediate update on the next foreground; a flexible download
  // still in flight is left alone until it reaches [downloaded] above.
  if (updateInProgress) {
    return immediateAllowed ? UpdateAction.resumeImmediate : UpdateAction.none;
  }

  if (!available) return UpdateAction.none;
  final wantImmediate =
      updatePriority >= kImmediatePriorityThreshold ||
      stalenessDays >= kImmediateStalenessDays;
  if (wantImmediate && immediateAllowed) return UpdateAction.immediate;
  if (flexibleAllowed) return UpdateAction.flexible;
  return UpdateAction.none;
}

/// Thin, Android-only wrapper over the `in_app_update` plugin.
///
/// Every method is a safe no-op off Android and swallows plugin errors —
/// `InAppUpdate.checkForUpdate()` throws for builds not installed from Google
/// Play (sideloaded, `flutter run`, other stores), so the whole feature must
/// degrade silently rather than surface an error or block startup.
class InAppUpdateService {
  const InAppUpdateService();

  bool get _supported => defaultTargetPlatform == TargetPlatform.android;

  /// Checks Play for an update and, if one applies, starts the appropriate
  /// flow. Immediate updates are driven entirely by Play's own full-screen UI;
  /// for flexible updates this awaits the background download and returns
  /// [UpdateDecision.flexibleReady] once it's ready to install.
  ///
  /// Never throws — any failure resolves to [UpdateDecision.none].
  Future<UpdateDecision> checkAndStart() async {
    if (!_supported) return UpdateDecision.none;
    try {
      final info = await InAppUpdate.checkForUpdate();
      final action = decideUpdateAction(
        available:
            info.updateAvailability == UpdateAvailability.updateAvailable,
        updateInProgress:
            info.updateAvailability ==
            UpdateAvailability.developerTriggeredUpdateInProgress,
        downloaded: info.installStatus == InstallStatus.downloaded,
        updatePriority: info.updatePriority,
        stalenessDays: info.clientVersionStalenessDays ?? 0,
        immediateAllowed: info.immediateUpdateAllowed,
        flexibleAllowed: info.flexibleUpdateAllowed,
      );
      switch (action) {
        case UpdateAction.none:
          return UpdateDecision.none;
        case UpdateAction.immediate:
        case UpdateAction.resumeImmediate:
          // Play owns the blocking UI. A user-denied/failed result needs no
          // in-app follow-up — the next eligible check may re-offer.
          await InAppUpdate.performImmediateUpdate();
          return UpdateDecision.immediate;
        case UpdateAction.flexible:
          // Resolves when the background download completes. Only prompt the
          // restart when it actually succeeded.
          final result = await InAppUpdate.startFlexibleUpdate();
          return result == AppUpdateResult.success
              ? UpdateDecision.flexibleReady
              : UpdateDecision.none;
        case UpdateAction.completeFlexible:
          // Already downloaded on a prior run — don't re-download; just surface
          // the restart prompt so the user can install it now.
          return UpdateDecision.flexibleReady;
      }
    } catch (e) {
      debugPrint('InAppUpdateService.checkAndStart failed (ignored): $e');
      return UpdateDecision.none;
    }
  }

  /// Installs a flexible update that finished downloading — restarts the app.
  Future<void> completeFlexibleUpdate() async {
    if (!_supported) return;
    try {
      await InAppUpdate.completeFlexibleUpdate();
    } catch (e) {
      debugPrint('InAppUpdateService.completeFlexibleUpdate failed: $e');
    }
  }
}
