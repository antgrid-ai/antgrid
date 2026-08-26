import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/host_control_client.dart';
import '../models/ab_project.dart';
import '../project/project_session_registry.dart';
import '../storage/project_store.dart';
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
