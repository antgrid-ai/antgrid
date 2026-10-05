import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/update_handoff_store.dart';
import 'value_controller.dart';

/// Whether a newer app version is waiting to be installed — a pending
/// Microsoft Store package update on Windows, a newer `antgrid`
/// release on macOS/Linux, a newer App Store listing on iOS, a downloaded
/// Play flexible update on Android (or one explicitly discovered by a manual
/// check). Lit by the shared check controller, rendered by `UpdateRow`.
///
/// A CHECK only ever latches it true: no source un-pends on its own within
/// this process's lifetime (an MSIX update can't apply while running;
/// `releases/latest` and a store listing only move forward; a downloaded
/// flexible update stays installable until the restart applies it), and a
/// later failed or transient re-check must not hide the affordance.
///
/// A platform install answering "nothing pending", or Sparkle retracting its
/// candidate, can clear it. Transient check/install failures leave it lit.
final updateAvailableProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);

/// Records the build being replaced so the next launch can prove an update
/// actually happened — the `--after-update` argument alone cannot, because
/// Windows relaunches with it after a crash too. Overridden in `main()`.
final updateHandoffStoreProvider = Provider<UpdateHandoffSink>((_) {
  throw StateError('updateHandoffStoreProvider must be overridden in main()');
});
