import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/drawer_order_store.dart';

/// Synchronous handle to the on-disk drawer-order store. Opened eagerly in
/// `main()` and injected via a Riverpod override; reading without the
/// override throws.
final drawerOrderStoreProvider = Provider<DrawerOrderStore>((_) {
  throw StateError('drawerOrderStoreProvider must be overridden in main()');
});

/// Pure reorder of [currentIds]: removes the item at [from] and inserts it at
/// the slot indicated by [to], normalizing for `ReorderableListView`'s
/// downward-drag convention (where `to` is one past the target slot). Returns
/// `null` for no-op drops (same slot, out-of-range `from`).
///
/// Extracted as a top-level function so the index math is unit-testable
/// without spinning up a notifier or store.
List<String>? reorderIds(List<String> currentIds, int from, int to) {
  if (from < 0 || from >= currentIds.length) return null;
  var target = to;
  if (target > from) target -= 1;
  if (target < 0) target = 0;
  if (target >= currentIds.length) target = currentIds.length - 1;
  if (target == from) return null;
  final next = List<String>.from(currentIds);
  final moved = next.removeAt(from);
  next.insert(target, moved);
  return next;
}

class DrawerOrderNotifier extends Notifier<List<String>> {
  late final DrawerOrderStore _store;

  @override
  List<String> build() {
    _store = ref.watch(drawerOrderStoreProvider);
    return _store.list();
  }

  /// Reorders the persisted list. Indices are into the *currently displayed*
  /// drawer list, which may include ids not yet in the persisted order
  /// (newly opened projects appended at the end). The notifier rebuilds the
  /// canonical id sequence from the caller's view, then persists it — that
  /// way a drag commits "new" ids into the persisted order without needing a
  /// separate reconcile step.
  ///
  /// This also implicitly prunes stale ids: [currentIds] is what the user
  /// just saw, which by construction contains only live entries (stale ids
  /// were already filtered out by `applyDrawerOrder`).
  Future<void> move({
    required List<String> currentIds,
    required int from,
    required int to,
  }) async {
    final next = reorderIds(currentIds, from, to);
    if (next == null) return;
    state = List.unmodifiable(next);
    await _store.write(next);
  }
}

/// In-memory mirror of [DrawerOrderStore]. Empty list means "no user-defined
/// order yet" — fall back to source order.
final drawerOrderProvider = NotifierProvider<DrawerOrderNotifier, List<String>>(
  DrawerOrderNotifier.new,
);
