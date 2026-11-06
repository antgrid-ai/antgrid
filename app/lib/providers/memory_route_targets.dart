import 'package:flutter_riverpod/flutter_riverpod.dart';

class MemoryRouteTargets extends Notifier<Set<String>> {
  final _routes = <String, int>{};

  @override
  Set<String> build() => const {};

  void Function() retain(String machineId) {
    final count = _routes[machineId] ?? 0;
    _routes[machineId] = count + 1;
    if (count == 0) state = {...state, machineId};
    var released = false;
    return () {
      if (released || !ref.mounted) return;
      released = true;
      final remaining = _routes[machineId]! - 1;
      if (remaining > 0) {
        _routes[machineId] = remaining;
      } else {
        _routes.remove(machineId);
        state = {...state}..remove(machineId);
      }
    };
  }
}

final memoryRouteTargetsProvider =
    NotifierProvider<MemoryRouteTargets, Set<String>>(MemoryRouteTargets.new);
