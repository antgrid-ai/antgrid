import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/project_session_registry.dart';
import 'agent_catalog.dart';
import 'cached_sessions.dart';
import 'projects.dart' show projectsProvider;
import 'providers.dart' show preferencesServiceProvider, storageServiceProvider;

/// One purge step: a store name (for error reporting) plus the async clear
/// itself.
typedef _PurgeStep = ({String store, Future<void> Function() clear});

/// Runs [steps] best-effort and step-isolated: each is awaited in turn, and a
/// failure clearing one is reported via [onFailure] rather than aborting the
/// rest — shared by [purgeEntryState] and [purgeAccountCaches] so the
/// isolate-and-report contract can't drift between the two (it did before
/// this helper existed).
Future<void> _runBestEffortSteps(
  List<_PurgeStep> steps,
  void Function(String store, Object error) onFailure,
) async {
  for (final step in steps) {
    try {
      await step.clear();
    } catch (e) {
      onFailure(step.store, e);
    }
  }
}

/// Single owner of the per-entry persisted footprint. Deleting a project or
/// forgetting a machine must clear EVERY store keyed by that id, or stale data
/// resurrects when the same id reappears (the classic symptom: a removed
/// project's old session list comes back on reopen). Centralizing it here keeps
/// the local (`ProjectsNotifier.remove`) and remote
/// (`MachineConnectionNotifier.forgetMachine`) paths from drifting out of sync.
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
  final steps = <_PurgeStep>[
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
      store: 'projectStatusCache',
      clear: () => ref.read(projectStatusCacheProvider).clear(id),
    ),
  ];
  await _runBestEffortSteps(steps, onError ?? _logPurgeFailure);
}

void _logPurgeFailure(String store, Object error) {
  developer.log(
    'purgeEntryState: "$store" clear failed — stale data may survive',
    name: 'antgrid.cleanup',
    error: error,
  );
}

/// Wipes every cache derived from the signed-in ACCOUNT, across all ids. The
/// sign-out counterpart of [purgeEntryState], and the single owner of that list
/// for the same reason: a store added here-but-not-there (or the reverse) is a
/// silent leak with no compile-time signal.
///
/// Everything below describes machines the account made reachable — their
/// session lists, project labels and work status, the file-tree state of the
/// projects on them, the agents they advertised. Left at rest, it all
/// renders on the very next launch, before (or without) any sign-in: the drawer
/// and the Recent list read straight from these stores. So the next person to
/// use the install sees the previous account's work.
///
/// Caller contract: run AFTER live sessions have been evicted with
/// [ProjectSessionRegistry.forceEvictAndSettle] — eviction's `onEvict` WRITES
/// the status cache and the session cache, so a fire-and-forget teardown would
/// let a late write land behind the purge.
///
/// Deliberately NOT cleared:
///   - The local project list, drawer order and collapsed set. These name
///     folders on THIS machine and opaque ids; they are filtered on read and
///     hold nothing an agent reported (same reasoning as [purgeEntryState]).
///     Local projects' preferences (expanded folders, split ratio, selected
///     tab) survive for the same reason — [clearAccountScoped] filters the
///     shared preferences.json by the current local project list rather than
///     wiping it outright.
///   - App settings, install/client id, and the relay epoch — machine-level, and
///     the epoch specifically must stay monotonic across sign-outs.
///
/// Best-effort and step-isolated exactly like [purgeEntryState] (same shared
/// runner, [_runBestEffortSteps]): one failing store must not strand the
/// rest, and a swallowed failure is reported rather than lost.
Future<void> purgeAccountCaches(
  Ref ref, {
  void Function(String store, Object error)? onError,
}) async {
  final steps = <_PurgeStep>[
    (
      store: 'cachedSessions',
      clear: () => ref.read(cachedSessionsStoreProvider).clear(),
    ),
    (
      store: 'projectStatusCache',
      clear: () => ref.read(projectStatusCacheProvider).clearAll(),
    ),
    (
      store: 'agentCatalog',
      clear: () => ref.read(agentCatalogStoreProvider).clear(),
    ),
    (
      store: 'pairedAgents',
      clear: () => ref.read(storageServiceProvider).clearPairedAgents(),
    ),
    (
      store: 'projectPreferences',
      // Reading the local project list inside the step keeps it under the
      // runner's isolation: the list comes from a store of its own, and a
      // failure there must be reported like any other rather than aborting the
      // whole purge before the first clear runs.
      clear: () {
        final localProjectIds = ref
            .read(projectsProvider)
            .map((p) => p.projectId)
            .toSet();
        return ref
            .read(preferencesServiceProvider)
            .clearAccountScoped(localProjectIds.contains);
      },
    ),
  ];
  await _runBestEffortSteps(steps, onError ?? _logAccountPurgeFailure);
}

void _logAccountPurgeFailure(String store, Object error) {
  developer.log(
    'purgeAccountCaches: "$store" clear failed — signed-out install keeps '
    'account-derived data',
    name: 'antgrid.cleanup',
    error: error,
  );
}
