import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_entry.dart';
import '../storage/cached_sessions_store.dart';

/// Synchronous handle to the cache store. Opened in `main()` and injected
/// via `.overrideWithValue` — same convention as `projectStoreProvider`,
/// `recentAgentsStoreProvider`, `drawerOrderStoreProvider`. Reading without
/// the override throws.
final cachedSessionsStoreProvider = Provider<CachedSessionsStore>((_) {
  throw StateError('cachedSessionsStoreProvider must be overridden in main()');
});

/// One cache mutation: the `entryId` that changed, plus a monotonic [seq].
///
/// The counter is load-bearing, not diagnostics. A `StreamProvider` only
/// notifies when the new `AsyncValue` differs by `==`, and consecutive
/// mutations of the SAME project emit the same entryId — the common case, since
/// one session change produces a burst of `session:updated` frames. Without the
/// counter every repeat was silently swallowed: the drawer kept serving the
/// session list it had when that project last followed a DIFFERENT project's
/// write, so a session created (or deleted) elsewhere never appeared until some
/// other project happened to change. Same hazard, same fix as
/// `relayConnectionChangesProvider`.
typedef CacheChange = ({String entryId, int seq});

/// Stream of cache-mutation events. Emits the `entryId` that just changed so
/// downstream `family` providers can selectively invalidate.
final cacheChangesProvider = StreamProvider<CacheChange>((ref) {
  final store = ref.watch(cachedSessionsStoreProvider);
  var seq = 0;
  return store.changes.map((entryId) => (entryId: entryId, seq: ++seq));
});

/// Cached session list for a single drawer entry. Invalidates whenever the
/// underlying store reports a change for the matching id.
///
/// Subscribes to the store's raw stream rather than watching
/// [cacheChangesProvider]: routing through a `StreamProvider` made a drawer row
/// depend on someone ELSE keeping that provider alive (only the Recent tab
/// watches it), and left the invalidation subject to `AsyncValue` equality. A
/// direct subscription fires once per mutation, always.
final cachedSessionsProvider = Provider.family<List<SessionEntry>, String>((
  ref,
  entryId,
) {
  final store = ref.watch(cachedSessionsStoreProvider);
  final sub = store.changes
      .where((changed) => changed == entryId)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return store.get(entryId);
});
