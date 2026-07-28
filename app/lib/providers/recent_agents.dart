import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/recent_agents_store.dart';

/// Synchronous handle to the on-disk recent-agents store. The store is opened
/// eagerly in `main()` and injected via a Riverpod override; reading this
/// provider without that override throws.
final recentAgentsStoreProvider = Provider<RecentAgentsStore>((_) {
  throw StateError('recentAgentsStoreProvider must be overridden in main()');
});

/// In-memory mirror of [RecentAgentsStore]. Seeds from `store.list()` on
/// construction and then follows `store.changes`, so writes from any path
/// (including direct `RecentAgentsStore.upsert` calls in the transport builder)
/// are reflected here automatically.
class RecentAgentsNotifier extends Notifier<List<RecentAgent>> {
  @override
  List<RecentAgent> build() {
    final store = ref.watch(recentAgentsStoreProvider);
    final sub = store.changes.listen((snapshot) => state = snapshot);
    ref.onDispose(sub.cancel);
    return store.list();
  }

  Future<void> upsert(RecentAgent a) =>
      ref.read(recentAgentsStoreProvider).upsert(a);
  Future<void> remove(String agentDeviceId) =>
      ref.read(recentAgentsStoreProvider).remove(agentDeviceId);
}

final recentAgentsProvider =
    NotifierProvider<RecentAgentsNotifier, List<RecentAgent>>(
      RecentAgentsNotifier.new,
    );
