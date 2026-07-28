import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_transport.dart';
import '../providers/analytics.dart';
import '../providers/cached_sessions.dart';
import '../providers/provider_retry.dart';
import '../providers/registry_eviction.dart';
import '../util/device_id.dart';
import 'limits.dart';
import 'lru_policy.dart';
import 'project_session.dart';
import 'project_status.dart';
import 'project_status_cache.dart';

/// Injectable singleton; tests override with `ProjectStatusCache.testInstance(...)`.
final projectStatusCacheProvider = Provider<ProjectStatusCache>(
  (_) => ProjectStatusCache(),
);

typedef RegistryEvictionCallback = Future<void> Function(String projectId);

/// Lightweight registry of opened projects. Tracks insertion order and
/// last-focus time, enforces a warm cap by evicting the oldest project via
/// the supplied [onEvict] callback (fire-and-forget). Caps are per-bucket:
/// local-mode projects (each a ~80 MB spawned agent process) and relay-mode
/// projects (each a ~500 KB idle socket) have SEPARATE quotas, so opening a
/// relay socket can never evict a warm local agent.
class ProjectSessionRegistry extends ChangeNotifier {
  final int localCap;
  final int relayCap;
  // Reassignable so the app controller can install the real callback in build()
  // (a Notifier has no `ref` at construction; see AppProjectSessionRegistryController).
  RegistryEvictionCallback onEvict;

  final List<String> _open = [];
  final Map<String, DateTime> _lastFocused = {};
  final Map<String, bool> _isLocal = {};

  ProjectSessionRegistry({
    required this.localCap,
    required this.relayCap,
    required this.onEvict,
  });

  List<String> get openProjects => List.unmodifiable(_open);

  /// Adds the project if new and records last-focus time. Idempotent on touch
  /// of an existing project (only the timestamp updates; no notify).
  void touch(String projectId, {required bool isLocal}) {
    final isNew = !_open.contains(projectId);
    _lastFocused[projectId] = DateTime.now();
    _isLocal[projectId] = isLocal;
    if (isNew) {
      _open.add(projectId);
      _maybeEvict(protect: projectId);
      notifyListeners();
    }
  }

  /// Drops [projectId] from the warm set WITHOUT firing [onEvict]. Used when the
  /// caller manages teardown itself; for eviction-with-callback use [forceEvict]
  /// / [forceEvictAndSettle].
  void remove(String projectId) {
    if (_drop(projectId)) notifyListeners();
  }

  /// Drops [projectId] from the warm set and fires the eviction callback
  /// (fire-and-forget). Used by the mobile lifecycle observer to demote
  /// non-focused projects after the app has been backgrounded. Fire-and-forget
  /// of [forceEvictAndSettle], so it shares the same drop/notify/swallow path —
  /// a callers that don't await still can't leak an [onEvict] failure.
  void forceEvict(String projectId) {
    // ignore: unawaited_futures
    forceEvictAndSettle(projectId);
  }

  /// Like [forceEvict] but AWAITS the eviction callback instead of firing it
  /// and forgetting. The delete paths need this: `onEvict` writes the project's
  /// final-status cache file, and they purge that same file immediately after —
  /// awaiting the write makes write-then-purge deterministic so a stale status
  /// file can't survive the deletion. No-op (no callback) for an unknown id.
  ///
  /// `onEvict` does best-effort status I/O; a failure must not propagate and
  /// abort the caller's removal/teardown. Swallow — and because [forceEvict]
  /// delegates here, that guarantee covers both entry points.
  Future<void> forceEvictAndSettle(String projectId) async {
    if (!_drop(projectId)) return;
    notifyListeners();
    try {
      await onEvict(projectId);
    } catch (_) {}
  }

  /// Removes [projectId] from all three tracking maps in one place. Returns
  /// whether it was open, so callers can gate their notify/eviction on a real
  /// removal. The single chokepoint keeps the maps from drifting out of sync.
  bool _drop(String projectId) {
    final removed = _open.remove(projectId);
    _lastFocused.remove(projectId);
    _isLocal.remove(projectId);
    return removed;
  }

  DateTime? lastFocused(String projectId) => _lastFocused[projectId];

  /// Distinct bare device uuids of every machine currently backing >=1 open
  /// project — the base of each open COMPOUND id (`<uuid>.<projectId>`); bare/
  /// local ids (no dot) are excluded. The control-plane keep-alive unions this
  /// with the picker's viewed machine to decide which sockets stay open.
  Set<String> machinesWithOpenProjects() {
    return {
      for (final id in _open)
        if (id.contains('.')) baseDeviceUuid(id),
    };
  }

  /// Open ids served by the LOCAL bridge host, per the same `_isLocal` flag
  /// that buckets eviction. NOT the dot-free-id heuristic: a bare machine
  /// uuid is also dot-free but names a REMOTE control-plane session
  /// (`agent_transport.dart`'s bare-id branch), which must not be torn down
  /// when the local host respawns. These are exactly the sessions whose
  /// loopback transport dies with the host process, so host supervision
  /// re-binds them after a respawn.
  List<String> localOpenProjects() => [
    for (final id in _open)
      if (_isLocal[id] ?? false) id,
  ];

  void _maybeEvict({String? protect}) {
    _evictBucket(isLocal: true, cap: localCap, protect: protect);
    _evictBucket(isLocal: false, cap: relayCap, protect: protect);
  }

  /// Evicts the oldest project(s) within a single mode bucket until it fits its
  /// cap. Eviction stays within the overflowing bucket so a relay-socket open
  /// never displaces a local agent (or vice versa).
  void _evictBucket({
    required bool isLocal,
    required int cap,
    String? protect,
  }) {
    bool inBucket(String id) => (_isLocal[id] ?? false) == isLocal;
    while (_open.where(inBucket).length > cap) {
      final bucket = _open.where(inBucket).toList();
      final victim = selectEvictionVictim(
        open: bucket,
        lastFocused: _lastFocused,
        protect: protect,
      );
      if (victim == null) break;
      _drop(victim);
      // ignore: unawaited_futures
      onEvict(victim);
    }
  }
}

/// Riverpod adapter for [ProjectSessionRegistry]. The registry remains a plain
/// ChangeNotifier (with its own unit tests); this controller bridges it into
/// Riverpod — mirroring `openProjects` into `state` on every change so watchers
/// rebuild, and delegating the mutating verbs. Created with a ready-built
/// registry so `main()` and tests keep full control of caps + onEvict.
class ProjectSessionRegistryController extends Notifier<List<String>> {
  ProjectSessionRegistryController(this.registry);

  final ProjectSessionRegistry registry;

  @override
  List<String> build() {
    void listener() => state = registry.openProjects;
    registry.addListener(listener);
    ref.onDispose(() => registry.removeListener(listener));
    return registry.openProjects;
  }

  void touch(String projectId, {required bool isLocal}) =>
      registry.touch(projectId, isLocal: isLocal);
  void forceEvict(String projectId) => registry.forceEvict(projectId);
  Future<void> forceEvictAndSettle(String projectId) =>
      registry.forceEvictAndSettle(projectId);
  Set<String> machinesWithOpenProjects() => registry.machinesWithOpenProjects();
  List<String> localOpenProjects() => registry.localOpenProjects();
}

/// App-wired controller: builds the registry with a placeholder onEvict, then
/// installs the real status-snapshotting callback in build() where `ref` is
/// available (a Notifier has no ref at construction time).
class AppProjectSessionRegistryController
    extends ProjectSessionRegistryController {
  AppProjectSessionRegistryController({
    required int localCap,
    required int relayCap,
  }) : super(
         ProjectSessionRegistry(
           localCap: localCap,
           relayCap: relayCap,
           onEvict:
               (_) async {}, // placeholder; real callback installed in build()
         ),
       );

  @override
  List<String> build() {
    final cache = ref.read(projectStatusCacheProvider);
    registry.onEvict = (id) => snapshotAndInvalidateOnEvict(ref, cache, id);
    return super.build(); // wires the ChangeNotifier→state listener
  }
}

final projectSessionRegistryProvider =
    NotifierProvider<ProjectSessionRegistryController, List<String>>(
      () => ProjectSessionRegistryController(
        ProjectSessionRegistry(
          localCap: kWarmCapLocal,
          relayCap: kWarmCapRelay,
          onEvict: (id) async {
            // No-op placeholder; the real callback is installed via override.
          },
        ),
      ),
    );

/// Test-overridable factory. Production injects [defaultProjectSessionFactory].
typedef ProjectSessionFactory =
    Future<ProjectSession> Function(Ref ref, String projectId);

final projectSessionFactoryProvider = Provider<ProjectSessionFactory>(
  (_) => defaultProjectSessionFactory,
);

/// Production-mode factory. Resolves the per-projectId transport via the
/// [agentTransportForProvider] family so every open project keeps its own
/// warm transport. Lifetime is governed by the registry: `onEvict`
/// invalidates this provider (and the transport family) explicitly. This
/// is deliberately NOT `autoDispose` — duelling lifetime systems caused
/// disposed-mid-build races where a transient `.future` reader detaching
/// triggered autoDispose teardown while the build was still awaiting
/// `openFolder`. Registry-only lifetime keeps it deterministic.
Future<ProjectSession> defaultProjectSessionFactory(
  Ref ref,
  String projectId,
) async {
  // `watch`, not `read`: the transport family can resolve to null TRANSIENTLY
  // when this id is selected a beat before its AbProject lands in
  // `projectsProvider` (the `folder` select returns null → the build returns
  // null), then rebuilds to a real transport the instant the project is
  // registered. A one-shot `read` would latch that transient null into a
  // permanent "No transport available" StateError even though the launcher
  // went on to open the loopback transport. Watching makes this provider
  // rebuild when the transport flips null → non-null, so the session
  // self-heals instead of stranding the workspace on the error screen.
  final transport = await ref.watch(
    agentTransportForProvider(projectId).future,
  );
  if (transport == null) {
    throw StateError('No transport available for project "$projectId"');
  }
  final mode = transport.isLocal
      ? ProjectSessionMode.local
      : ProjectSessionMode.relay;
  final cache = ref.read(cachedSessionsStoreProvider);
  return ProjectSession(
    projectId: projectId,
    transport: transport,
    mode: mode,
    cachedSessionsStore: cache,
    analytics: ref.read(analyticsServiceProvider),
    onClose: () async {
      // Transport teardown is handled by the agentTransportForProvider's
      // own ref.onDispose, fired when the registry invalidates it.
    },
  );
}

final projectSessionProvider = FutureProvider.family<ProjectSession, String>((
  ref,
  projectId,
) async {
  final factory = ref.read(projectSessionFactoryProvider);
  final session = await factory(ref, projectId);
  final registry = ref.read(projectSessionRegistryProvider.notifier);
  registry.touch(projectId, isLocal: session.mode == ProjectSessionMode.local);
  ref.onDispose(() {
    // Best-effort close; ignore errors.
    session.close();
  });
  return session;
  // retry: this build re-throws the transport-layer Exception from
  // agentTransportForProvider verbatim; that inner provider already rejects
  // `.future` immediately (noProviderRetry), but without the same override
  // here Riverpod 3's default retry loop would catch the re-thrown Exception
  // and keep `.future` pending through up to 10 backoff attempts instead of
  // letting the direct-await call sites above see the failure. See
  // provider_retry.dart.
}, retry: noProviderRetry);

/// Drawer-friendly stream of a project's [ProjectStatus]. Watching this
/// rebuilds only on status changes for the given projectId.
final projectStatusProvider = StreamProvider.family<ProjectStatus, String>((
  ref,
  projectId,
) async* {
  final openProjects = ref.watch(projectSessionRegistryProvider);
  final isWarm = openProjects.contains(projectId);
  if (!isWarm) {
    final cache = ref.watch(projectStatusCacheProvider);
    final cached = await cache.read(projectId);
    yield cached ?? const ProjectStatus.empty();
    return;
  }
  // Warm: stream from the session's status notifier (existing logic).
  final session = await ref.watch(projectSessionProvider(projectId).future);
  final ctrl = StreamController<ProjectStatus>();
  ctrl.add(session.status.value);
  void listener() => ctrl.add(session.status.value);
  session.status.addListener(listener);
  ref.onDispose(() {
    session.status.removeListener(listener);
    ctrl.close();
  });
  yield* ctrl.stream;
});
