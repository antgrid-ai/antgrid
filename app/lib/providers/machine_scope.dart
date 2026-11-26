import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/machine_scope_store.dart';
import '../util/detached.dart';
import 'demo_mode.dart';

/// Which machines the project-first views show. The ONE source of truth for
/// that question: the sidebar, Needs you, the composer's project and
/// machine pickers and the mobile home all filter through [includes], so no two
/// of them can disagree about what is in scope.
///
/// An offline machine is never in scope and is not offered as a choice:
/// nothing can be started there. Stores only the online machines the user
/// unchecked, so a machine coming back online rejoins on its own unless it was
/// unchecked, and one added to the account later is in scope without a
/// migration.
@immutable
class MachineScope {
  const MachineScope({this.excluded = const {}});

  final Set<String> excluded;

  /// Whether the machine's checkbox is ticked.
  bool isChecked(String machineId) => !excluded.contains(machineId);

  /// Whether the machine is in scope.
  bool includes(String machineId, {required bool online}) =>
      online && isChecked(machineId);

  /// Flips the checkbox.
  MachineScope toggled(String machineId) {
    final excluded = {...this.excluded};
    if (!excluded.remove(machineId)) excluded.add(machineId);
    return MachineScope(excluded: Set.unmodifiable(excluded));
  }

  /// Every online machine checked.
  MachineScope selectAll() => const MachineScope();

  @override
  bool operator ==(Object other) =>
      other is MachineScope && setEquals(other.excluded, excluded);

  @override
  int get hashCode => Object.hashAllUnordered(excluded);
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
    if (saved == null || saved.isEmpty) return const MachineScope();
    return MachineScope(excluded: Set.unmodifiable(saved));
  }

  void toggle(String machineId) => _set(state.toggled(machineId));

  void selectAll() => _set(state.selectAll());

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
      () => store.write(excluded: next.excluded),
    );
  }
}
