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

/// Detection never starts a Play flow. The install controller owns every action.
class InAppUpdateService {
  const InAppUpdateService();

  Future<AppUpdateInfo> check() => InAppUpdate.checkForUpdate();

  Future<AppUpdateResult> start(UpdateAction action) => switch (action) {
    UpdateAction.immediate ||
    UpdateAction.resumeImmediate => InAppUpdate.performImmediateUpdate(),
    UpdateAction.flexible => InAppUpdate.startFlexibleUpdate(),
    _ => Future.value(AppUpdateResult.inAppUpdateFailed),
  };

  Future<void> completeFlexibleUpdate() => InAppUpdate.completeFlexibleUpdate();
}
