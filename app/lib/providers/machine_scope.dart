import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/machine_scope_store.dart';
import '../util/detached.dart';
import 'demo_mode.dart';

/// Which machines the project-first views show. The ONE source of truth for
/// that question: the sidebar, Needs you, the project panel, the composer's
/// machine picker and the mobile home all filter through [includes], so no two
/// of them can disagree about what is in scope.
///
/// Stores explicit choices only. A machine absent from both sets follows the
/// default — online machines are in, offline ones out — so a machine coming
/// back online rejoins on its own unless the user unchecked it, and one added
/// to the account later is in scope without a migration.
@immutable
class MachineScope {
  const MachineScope({
    this.included = const {},
    this.excluded = const {},
    this.hideOffline = false,
  });

  final Set<String> included;
  final Set<String> excluded;

  /// Drops offline machines even when picked. Separate from the checkboxes so
  /// turning it off restores exactly what was picked before.
  final bool hideOffline;

  /// Whether the machine's checkbox is ticked — the user's choice, before
  /// [hideOffline] is applied.
  bool isChecked(String machineId, {required bool online}) {
    if (excluded.contains(machineId)) return false;
    return included.contains(machineId) || online;
  }

  /// Whether the machine is in scope.
  bool includes(String machineId, {required bool online}) {
    if (!online && hideOffline) return false;
    return isChecked(machineId, online: online);
  }

  /// Flips the checkbox, recording the result as an explicit choice.
  MachineScope toggled(String machineId, {required bool online}) {
    final checked = isChecked(machineId, online: online);
    final included = {...this.included}..remove(machineId);
    final excluded = {...this.excluded}..remove(machineId);
    (checked ? excluded : included).add(machineId);
    return MachineScope(
      included: Set.unmodifiable(included),
      excluded: Set.unmodifiable(excluded),
      hideOffline: hideOffline,
    );
  }

  /// Every listed machine checked, offline ones included, and nothing hidden.
  MachineScope selectAll(Iterable<String> machineIds) =>
      MachineScope(included: Set.unmodifiable(machineIds.toSet()));

  MachineScope withHideOffline(bool hide) =>
      MachineScope(included: included, excluded: excluded, hideOffline: hide);

  @override
  bool operator ==(Object other) =>
      other is MachineScope &&
      setEquals(other.included, included) &&
      setEquals(other.excluded, excluded) &&
      other.hideOffline == hideOffline;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(included),
    Object.hashAllUnordered(excluded),
    hideOffline,
  );
}

/// Null — in memory only — wherever `main()` did not open one, which keeps the
/// many tests that never touch the scope free of a store override.
final machineScopeStoreProvider = Provider<MachineScopeStore?>((_) => null);

final machineScopeProvider = NotifierProvider<MachineScopeNotifier, MachineScope>(
  MachineScopeNotifier.new,
);

class MachineScopeNotifier extends Notifier<MachineScope> {
  // Not final: build() re-runs on this instance when the demo switch flips.
  MachineScopeStore? _store;
  bool _demo = false;

  @override
  MachineScope build() {
    _demo = ref.watch(demoModeProvider);
    _store = ref.watch(machineScopeStoreProvider);
    // The demo has one machine and must not persist a choice about it — nor
    // inherit the real scope, which could hide the sample project.
    if (_demo) return const MachineScope();
    final saved = _store?.read();
    if (saved == null) return const MachineScope();
    return MachineScope(
      included: Set.unmodifiable(saved.included),
      excluded: Set.unmodifiable(saved.excluded),
      hideOffline: saved.hideOffline,
    );
  }

  void toggle(String machineId, {required bool online}) =>
      _set(state.toggled(machineId, online: online));

  void selectAll(Iterable<String> machineIds) =>
      _set(state.selectAll(machineIds));

  void setHideOffline(bool hide) => _set(state.withHideOffline(hide));

  void _set(MachineScope next) {
    if (next == state) return;
    state = next;
    final store = _store;
    if (_demo || store == null) return;
    // Best-effort, like the drawer's own stores: the in-memory state is already
    // right, and a failed write only costs the choice on the next launch.
    detached(
      'MachineScope',
      'persist failed',
      () => store.write(
        included: next.included,
        excluded: next.excluded,
        hideOffline: next.hideOffline,
      ),
    );
  }
}
