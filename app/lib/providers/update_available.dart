import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'value_controller.dart';

/// Whether a newer app version is waiting to be installed — a pending
/// Microsoft Store package update on Windows, a newer `antgrid`
/// release on macOS/Linux, a newer App Store listing on iOS, a downloaded
/// Play flexible update on Android. Lit by `UpdateGate` routing the platform
/// `UpdateStrategy`'s check outcome, rendered by `UpdateRow` in the drawer.
///
/// Latches true only — no source un-pends within this process's lifetime
/// (an MSIX update can't apply while running; `releases/latest` and a store
/// listing only move forward; a downloaded flexible update stays installable
/// until the restart applies it), and a later failed/transient re-check must
/// not hide the affordance.
final updateAvailableProvider = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(false),
);
