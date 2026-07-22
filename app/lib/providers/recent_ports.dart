import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/recent_ports_store.dart';

/// Synchronous handle to the on-disk recent-ports store. Opened eagerly in
/// `main()` and injected via a Riverpod override; reading without that override
/// throws.
final recentPortsStoreProvider = Provider<RecentPortsStore>((_) {
  throw StateError('recentPortsStoreProvider must be overridden in main()');
});

/// Per-project remembered ports, most-recent-first. Seeds from the store and
/// follows its [RecentPortsStore.changes] for the matching project.
class RecentPortsNotifier extends Notifier<List<RecentPort>> {
  RecentPortsNotifier(this._projectId);
  final String _projectId;

  @override
  List<RecentPort> build() {
    final store = ref.watch(recentPortsStoreProvider);
    final sub = store.changes.listen((c) {
      if (c.projectId == _projectId) state = c.ports;
    });
    ref.onDispose(sub.cancel);
    return store.list(_projectId);
  }

  Future<void> add(int port, String scheme) =>
      ref.read(recentPortsStoreProvider).add(_projectId, port, scheme);
  Future<void> remove(int port) =>
      ref.read(recentPortsStoreProvider).remove(_projectId, port);
}

final recentPortsProvider =
    NotifierProvider.family<RecentPortsNotifier, List<RecentPort>, String>(
      RecentPortsNotifier.new,
    );
