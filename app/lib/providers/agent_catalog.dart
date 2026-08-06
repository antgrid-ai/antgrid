import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_descriptor.dart';
import '../storage/agent_catalog_store.dart';

/// Swappable store so tests can inject an in-memory instance.
final agentCatalogStoreProvider = Provider<AgentCatalogStore>(
  (ref) => AgentCatalogStore(),
);

/// Registry key -> [AgentDescriptor]: every machine's advertised catalog merged
/// over the persisted one, and written back whenever it changes.
///
/// This is what replaced the app's hardcoded agent tables. The bridge is
/// authoritative for what an agent is called and what it can do; the app caches
/// what it was told, so a newly-registered agent is named and capability-
/// described without an app release.
///
/// Merging across machines is sound because the descriptor is a projection of
/// the bridge's static registry, not a fact about any one machine — the
/// machine-scoped question ("is it installed HERE") stays on `tools[]`.
///
/// A key ABSENT from this map means no bridge has ever described that agent.
/// Callers must render that as unknown; folding it onto `false` would silently
/// hide a working capability, and onto `true` would offer one the bridge
/// refuses.
///
/// Filled imperatively from the app-shell control-plane reaper (single-writer,
/// like the work-status maps beside it) rather than by fanning `ref.watch` out
/// over every machine's control plane — that fan-in is what reproduced
/// Riverpod's "rebuilt multiple times in the same frame" crash.
class AgentCatalogNotifier extends Notifier<Map<String, AgentDescriptor>> {
  @override
  Map<String, AgentDescriptor> build() {
    unawaited(_hydrate());
    return const {};
  }

  /// False until the persisted blob has been folded in. While it is false
  /// [_hydrate] owns the write — see [merge].
  bool _hydrated = false;

  Future<void> _hydrate() async {
    final stored = await ref.read(agentCatalogStoreProvider).read();
    // The read outlives a container torn down mid-launch (and every widget test
    // that disposes before the future lands); writing state then throws.
    if (!ref.mounted) return;
    // A live advert can land while the disk read is in flight, and a running
    // bridge outranks whatever wrote the blob — so it wins key by key.
    final raced = state;
    final merged = {...stored, ...raced};
    _hydrated = true;
    if (stored.isNotEmpty) state = merged;
    // The adverts that won the race deferred their write to here, so this is
    // the only thing that puts them on disk — and it writes the union, which is
    // what keeps [AgentCatalogStore.write]'s whole-blob replace from dropping
    // every agent the read just restored.
    if (raced.isNotEmpty) unawaited(_persist(merged));
  }

  /// Fold one machine's advertised catalog in. The advert wins per key.
  ///
  /// An empty [advertised] is a no-op, not a clear: it is what a bridge
  /// predating the descriptor sends, and dropping the cache on it would blank
  /// every label the moment an older machine connected.
  void merge(Iterable<AgentDescriptor> advertised) {
    if (advertised.isEmpty) return;
    final next = {...state, for (final d in advertised) d.tool: d};
    if (_unchanged(next)) return;
    state = next;
    // Persisting before hydration lands would replace the stored blob with this
    // machine's rows alone, and the union [_hydrate] then builds lives only in
    // memory — so every previously cached agent is gone from disk for good.
    if (_hydrated) unawaited(_persist(next));
  }

  Future<void> _persist(Map<String, AgentDescriptor> next) async {
    try {
      await ref.read(agentCatalogStoreProvider).write(next);
    } catch (_) {
      // A failed cache write costs one re-advert on the next launch. Escaping
      // as an unhandled async error would cost the app.
    }
  }

  bool _unchanged(Map<String, AgentDescriptor> next) {
    if (next.length != state.length) return false;
    for (final e in next.entries) {
      if (state[e.key] != e.value) return false;
    }
    return true;
  }
}

final agentCatalogProvider =
    NotifierProvider<AgentCatalogNotifier, Map<String, AgentDescriptor>>(
      AgentCatalogNotifier.new,
    );

/// Whether an armed Handler could observe a session of [tool] running in [chat]
/// mode — the PRE-arm answer, available before any session is armed and before
/// any status snapshot exists.
///
/// Null when no bridge has described [tool] (including a null [tool]): the
/// caller must render that as unknown and claim nothing, exactly as the catalog
/// requires. This never answers for an ARMED session — that one reports its own
/// `observability`, which also accounts for its judge pick.
bool? handlerObservableFromCatalog(
  Map<String, AgentDescriptor> catalog,
  String? tool, {
  required bool chat,
}) {
  final d = tool == null ? null : catalog[tool];
  if (d == null) return null;
  return chat ? d.handlerChat : d.handlerTerminal;
}

/// Registry keys the bridge can drive headlessly as a Handler judge.
///
/// Read off the merged catalog rather than the target machine's advert on
/// purpose: the judge picker must list tools whether or not the machine in
/// front of you has them installed, and `judgeCapable` is a registry fact, not
/// a probe.
///
/// Sorted rather than left in map order, which is whichever machine advertised
/// first and so reshuffles the picker between launches.
///
/// Empty until a bridge has described an agent — the picker then offers only
/// its Default entry. The app carries no list of its own: a hardcoded floor
/// here is the registry mirror this whole surface exists to delete.
final judgeCapableToolsProvider = Provider<List<String>>((ref) {
  final catalog = ref.watch(agentCatalogProvider);
  return [
    for (final d in catalog.values)
      if (d.judgeCapable) d.tool,
  ]..sort();
});
