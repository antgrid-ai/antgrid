import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memory.dart';
import 'account_machines.dart';
import 'demo_mode.dart';
import 'value_controller.dart';

/// What the Memory surface shows. Deliberately not value-equal: each open is a
/// new instance, so reopening the same project resets a filter changed since.
class MemoryView {
  MemoryView(MemoryTarget this.target, {this.projectId});
  MemoryView.selected() : target = null, projectId = null;

  /// Null follows the machine selector.
  final MemoryTarget? target;
  final String? projectId;
}

/// Read by the surface rather than handed to it, because the drawer and
/// settings that open Memory cannot reach the screen the surface mounts.
final memoryViewProvider =
    NotifierProvider<ValueController<MemoryView>, MemoryView>(
      () => ValueController(MemoryView.selected()),
    );

/// Null means there is no machine to show.
final memoryTargetProvider = Provider<MemoryTarget?>((ref) {
  // Before the explicit target, so a stale remote view cannot pin a real
  // machine inside the sample project.
  if (ref.watch(demoModeProvider)) return null;
  // An explicit target must not build the account inventory or recents.
  final explicit = ref.watch(memoryViewProvider.select((v) => v.target));
  if (explicit != null) return explicit;
  if (ref.watch(accountMachinesProvider).isEmpty) return null;
  return MemoryTarget.machine(machineId: ref.watch(machineTargetProvider));
});
