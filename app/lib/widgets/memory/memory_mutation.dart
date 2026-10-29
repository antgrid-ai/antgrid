import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/memory.dart';
import '../../providers/memory.dart';
import 'memory_error.dart';

/// One mutation at a time per surface, with its failure shown in place and
/// every memory view refreshed on success.
mixin MemoryMutation<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  MemoryTarget get mutationTarget;

  bool busy = false;
  String? mutationError;

  Future<bool> sendMutation(
    Map<String, dynamic> request, {
    void Function(Object error)? onError,
  }) async {
    if (busy) return false;
    final send = ref.read(memoryRequestProvider(mutationTarget));
    setState(() {
      busy = true;
      mutationError = null;
    });
    try {
      await send(request);
      if (!mounted) return false;
      invalidateMemoryViews(ref, mutationTarget);
      return true;
    } catch (error) {
      if (mounted) {
        if (onError != null) {
          onError(error);
        } else {
          setState(() => mutationError = memoryErrorCopy(error, mutation: true));
        }
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
