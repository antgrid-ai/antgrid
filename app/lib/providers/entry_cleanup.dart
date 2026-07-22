import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/project_session_registry.dart';
import 'cached_sessions.dart';
import 'recent_ports.dart';

/// Single owner of the per-entry persisted footprint. Deleting a project or
/// forgetting a machine must clear EVERY store keyed by that id, or stale data
/// resurrects when the same id reappears (the classic symptom: a removed
/// project's old session list comes back on reopen). Centralizing it here keeps
/// the local (`ProjectsNotifier.remove`) and remote
/// (`PairedAgentNotifier.forgetMachine`) paths from drifting out of sync.
///
/// Caller contract: invoke AFTER the id has been evicted from the warm registry
/// via [ProjectSessionRegistry.forceEvictAndSettle] (not the fire-and-forget
/// [ProjectSessionRegistry.forceEvict]). Eviction's `onEvict` writes the
/// final-status cache file; awaiting it first guarantees write-then-purge so
/// the status clear below can't lose a race to a still-in-flight write.
///
/// Deliberately NOT cleared: drawer order / collapsed-state stores. They're
/// filtered-on-read (a dead id never matches a live entry) and self-prune on
/// the next reorder/toggle, so they leak nothing that can resurface — only a
/// harmless dead id that costs a few bytes until the next drawer interaction.
///
/// Each store is purged independently and best-effort: a failure clearing one
/// (a disk error, a Windows file-handle race on the status file) must not
/// strand the others — leaving a subset behind is exactly the stale-data
/// resurrection this helper exists to prevent. The whole call is best-effort
/// and never throws into the delete path. A swallowed failure is reported via
/// [onError] (defaults to a `developer.log`) rather than vanishing silently —
/// a partial purge is undiagnosable otherwise. Listing the steps keeps the
/// isolate-and-report contract uniform, so a newly-added store can't be left
/// unwrapped.
Future<void> purgeEntryState(
  Ref ref,
  String id, {
  void Function(String store, Object error)? onError,
}) async {
  final steps = <({String store, Future<void> Function() clear})>[
    (
      store: 'cachedSessions',
      clear: () async {
        final sessions = ref.read(cachedSessionsStoreProvider);
        await sessions.removeKey(id);
        // Force the debounced write so the SharedPreferences blob actually
        // shrinks now, rather than on a timer that may never fire if nothing
        // else mutates.
        await sessions.flushNow();
      },
    ),
    (
      store: 'recentPorts',
      clear: () => ref.read(recentPortsStoreProvider).removeProject(id),
    ),
    (
      store: 'projectStatusCache',
      clear: () => ref.read(projectStatusCacheProvider).clear(id),
    ),
  ];
  for (final step in steps) {
    try {
      await step.clear();
    } catch (e) {
      (onError ?? _logPurgeFailure)(step.store, e);
    }
  }
}

void _logPurgeFailure(String store, Object error) {
  developer.log(
    'purgeEntryState: "$store" clear failed — stale data may survive',
    name: 'antgrid.cleanup',
    error: error,
  );
}
