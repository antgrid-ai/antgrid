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

/// Stream of cache-mutation events. Emits the `entryId` that just changed so
/// downstream `family` providers can selectively invalidate.
final cacheChangesProvider = StreamProvider<String>((ref) {
  final store = ref.watch(cachedSessionsStoreProvider);
  return store.changes;
});

/// Cached session list for a single drawer entry. Invalidates whenever the
/// underlying store reports a change for the matching id.
final cachedSessionsProvider = Provider.family<List<SessionEntry>, String>((
  ref,
  entryId,
) {
  ref.listen(cacheChangesProvider, (_, async) {
    final changed = async.value;
    if (changed == entryId) ref.invalidateSelf();
  });
  final store = ref.watch(cachedSessionsStoreProvider);
  return store.get(entryId);
});
