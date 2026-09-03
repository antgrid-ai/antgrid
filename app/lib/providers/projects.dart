import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../models/ab_project.dart';
import '../project/project_session_registry.dart';
import '../storage/project_store.dart';
import '../util/path_basename.dart';
import 'agent_transport.dart';
import 'control_plane.dart';
import 'entry_cleanup.dart';

/// Synchronous handle to the on-disk project store. The store is opened
/// eagerly in `main()` and injected via a Riverpod override; reading this
/// provider without that override throws.
final projectStoreProvider = Provider<ProjectStore>((_) {
  throw StateError('projectStoreProvider must be overridden in main()');
});

class ProjectsNotifier extends Notifier<List<AbProject>> {
  late final ProjectStore _store;

  @override
  List<AbProject> build() {
    _store = ref.watch(projectStoreProvider);
    return _store.list();
  }

  Future<void> upsert(AbProject p) async {
    // `list()` is a full JSON decode that publishes a fresh List, which is
    // never `==` the old one — so every `projectsProvider` watcher rebuilds.
    // Skipped when the store refused the write (the sample project), whose
    // drawer row goes through here on every tap: it is the demo's primary
    // navigation gesture.
    if (!await _store.upsert(p)) return;
    state = _store.list();
  }

  /// Re-stamps every project recorded against [from] with [to].
  ///
  /// Called when this device's persisted host identity is replaced — see
  /// `ensureCurrentUserDeviceRecord`, the one place that happens. Only the
  /// local-open path ever writes `hostDeviceUuid`, so a row holding the
  /// outgoing uuid is a folder on THIS machine whose identity moved, never a
  /// project hosted elsewhere; left behind it fails `AbProject.isLocalFor` for
  /// good.
  Future<void> rehost({required String from, required String to}) async {
    if (from == to) return;
    var changed = false;
    for (final p in _store.list()) {
      if (p.hostDeviceUuid != from) continue;
      p.hostDeviceUuid = to;
      changed = await _store.upsert(p) || changed;
    }
    if (changed) state = _store.list();
  }

  /// Registers every project the local bridge knows about but this store
  /// doesn't — the gap that opens when a session is started from another
  /// device's remote-control view of THIS machine: the bridge's seen-catalog
  /// picks it up (so a phone controlling this desktop lists it), but nothing
  /// ever ran the local "Open folder…" upsert that would land it here, so the
  /// desktop app's own drawer never showed it. [known] is this machine's full
  /// catalog (`HostControlClient.phonesList().knownProjects`, warm cores ∪
  /// seen-catalog hints); [hostUuid] is this device's own host identity
  /// ([localDeviceUuidProvider]).
  Future<void> backfillFromHost(
    List<KnownProject> known, {
    required String hostUuid,
  }) async {
    for (final p in missingLocalProjects(
      locals: _store.list(),
      known: known,
      hostUuid: hostUuid,
    )) {
      await upsert(p);
    }
  }

  Future<void> remove(String id) async {
    // Only stop active sessions when the project is already warm — warming a
    // cold project just to stop sessions would block on the relay connect +
    // E2E handshake (3-5s if the agent is offline), which is exactly what
    // users feel as a slow delete. Cold projects have no live transport to tear
    // down; the agent's PTYs will keep running and can be stopped on reconnect.
    final open = ref.read(projectSessionRegistryProvider);
    if (open.contains(id)) {
      try {
        await _stopProjectSessions(id).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Agent unreachable, slow, or already gone — nothing live to stop.
      }
    }
    // Evict the warm session so its services + transport are disposed and the
    // agent's owner-lock released (otherwise reopening later can trip 4409).
    // `AndSettle` AWAITS the eviction's `onEvict`, which writes the final-status
    // cache file — so the `purgeEntryState` below (which deletes that very file)
    // runs strictly after the write and can't lose a race to it. Promptly
    // handles the already-warm case; a warm-up that resolves only after the
    // timeout is evicted by `_stopProjectSessions`' own `finally`.
    await ref
        .read(projectSessionRegistryProvider.notifier)
        .forceEvictAndSettle(id);

    await _store.remove(id);
    state = _store.list();
    // Clear every per-entry store keyed by this id (cached sessions, recent
    // ports, status cache) — no consumer left after the drawer entry
    // disappears, and stale data here resurrects on reopen.
    await purgeEntryState(ref, id);
    // Tell the bridge to forget the project too: its persisted `sessions.json`
    // is the AUTHORITATIVE session list (purgeEntryState only clears the app's
    // cache of it), so without this the old sessions reload when the same folder
    // is reopened — same projectId, same store on disk. This also destroys the
    // project's isolated working directories, which is why every caller of
    // `remove` must confirm first — see `projectForget`'s contract.
    await _forgetOnHost(id);
    // If the removed project was active, clear the selection so the App
    // doesn't sit on a workspace shell with no transport.
    final selected = ref.read(selectedRegistrationIdProvider);
    if (selected == id) {
      ref.read(selectedTargetProvider.notifier).set(null);
    }
  }

  /// Best-effort: ask the local bridge host to erase the project's persisted
  /// store (sessions.json + seen-catalog entry). Bounded
  /// + swallowed so a slow/unreachable host never blocks or fails the delete —
  /// the app-side removal already succeeded. Uses `peekHost` (NOT `ensureHost`):
  /// a delete must never cold-SPAWN a host. The common delete happens with the
  /// host live (it was spawned when the project opened), so this connects. When
  /// no host is running (remote-only user, or it already exited) we skip rather
  /// than boot one — that would add delete latency AND leave a host the
  /// teardown-on-close must then reap. Worst case the on-disk store lingers until
  /// a later delete that coincides with a live host.
  Future<void> _forgetOnHost(String id) async {
    HostControlClient? client;
    try {
      final host = await ref
          .read(hostControllerProvider)
          .peekHost()
          .timeout(const Duration(seconds: 5));
      if (host == null) return; // no live host — nothing to reach.
      client = HostControlClient(port: host.controlPort, token: host.token);
      await client.projectForget(id).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Host down, slow, or version-skewed (no project:forget verb) — the
      // on-disk store survives until the host next runs, but the app-side delete
      // stands. Nothing actionable here.
    } finally {
      client?.close();
    }
  }

  /// Warm the (possibly cold) ProjectSession and stop every non-archived
  /// session. `requestList()` defaults to non-archived; archived sessions
  /// already had their PTY killed on archive, and stopping an already-stopped
  /// session is a no-op on the agent. Linear by design — [remove] bounds it
  /// with a timeout + catch.
  Future<void> _stopProjectSessions(String id) async {
    try {
      final session = await ref.read(projectSessionProvider(id).future);
      final sessions = await session.sessionsService.requestList();
      await Future.wait([
        for (final s in sessions) session.sessionsService.stopSession(s.id),
      ]);
    } finally {
      // Evict whatever warm session this read created, even if [remove]'s outer
      // timeout already abandoned the await — otherwise the FutureProvider's
      // late `registry.touch(id)` (it runs only once the slow factory resolves)
      // would re-add the just-removed project as an orphan holding the
      // owner-lock. `AndSettle` so the eviction's status-cache write completes
      // before [remove] reaches `purgeEntryState` (which deletes that file).
      await ref
          .read(projectSessionRegistryProvider.notifier)
          .forceEvictAndSettle(id);
    }
  }
}

/// In-memory mirror of [ProjectStore].
final projectsProvider = NotifierProvider<ProjectsNotifier, List<AbProject>>(
  ProjectsNotifier.new,
);

/// Pure helper behind [ProjectsNotifier.backfillFromHost]: [known] entries
/// whose id isn't already in [locals], turned into rows ready to [upsert].
/// A hint with no `path` is skipped — nothing to open it with.
List<AbProject> missingLocalProjects({
  required List<AbProject> locals,
  required List<KnownProject> known,
  required String hostUuid,
}) {
  final existing = {for (final p in locals) p.projectId};
  return [
    for (final p in known)
      if (!existing.contains(p.projectId) && p.path != null)
        AbProject(
          projectId: p.projectId,
          folder: p.path!,
          displayName: p.label ?? pathBasename(p.path!),
          hostDeviceUuid: hostUuid,
          hostMachineName: '',
          lastOpenedAt: DateTime.tryParse(p.lastActiveAt ?? '') ?? DateTime.now(),
        ),
  ];
}
