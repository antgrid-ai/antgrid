import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memory.dart';
import 'value_controller.dart';

/// What the Memory surface shows. Deliberately not value-equal: each open is a
/// new instance, so reopening the same project resets a filter changed since.
class MemoryView {
  MemoryView(this.target, {this.projectId});
  final MemoryTarget target;
  final String? projectId;
}

/// Read by the surface rather than handed to it, because the drawer and
/// settings that open Memory cannot reach the screen the surface mounts.
final memoryViewProvider =
    NotifierProvider<ValueController<MemoryView>, MemoryView>(
      () => ValueController(MemoryView(const MemoryTarget.machine())),
    );
