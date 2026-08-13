import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recent_session_row.dart';
import '../services/account_agents_api.dart';
import '../services/control_plane_client.dart';
import '../services/sessions_service.dart' show SessionOperationException;
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../project/project_session_registry.dart';
import '../widgets/drawer_entry_row.dart' show activateDrawerEntryById;
import 'account_agents.dart';
import 'cached_sessions.dart';
import 'control_plane.dart';
import 'device_provisioning.dart';
import 'new_session_picker.dart';
import 'projects.dart';
import 'recent_agents.dart';
import 'sessions.dart';
import 'ui_attention_providers.dart';
import 'agent_transport.dart';

/// Human-readable project labels for the Recent list, keyed by
/// `"<machineUuid>.<projectId>"`. Seeded from the persisted cache (survives
/// offline/cold boot); `_ControlPlaneReaperState` (app_shell.dart) keeps it
/// current by listening to each ALREADY-open machine's control-plane advert
/// and pushing updates in via [put] — imperatively, from an always-mounted
/// widget, never via `ref.watch` here.
///
/// This used to be computed inline inside [recentSessionsProvider] by
/// `ref.watch`ing a control-plane state stream per known machine, in a loop
/// over a set that changed shape (and size) across rebuilds. That fan-in of
/// N independently-firing streams into one `Provider` reproduced live as
/// "Bad state: Tried to rebuild `Provider<List<RecentSessionRow>>` multiple
/// times in the same frame" during pull-to-refresh: two of those streams
/// emitting within the same animation frame raced Riverpod's own scheduler.
/// Routing the updates through a single, plain state holder — written to
/// imperatively rather than watched N-wide — gives recentSessionsProvider one
/// stable dependency instead of a variable-length one.
final remoteProjectLabelsProvider =
    NotifierProvider<RemoteProjectLabelsController, Map<String, String>>(
      RemoteProjectLabelsController.new,
    );

class RemoteProjectLabelsController extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => {
    ...ref.read(cachedSessionsStoreProvider).labels(),
  };

  /// No-op when [label] is already current — avoids a redundant state update
  /// (and downstream rebuild) for every unchanged advert re-delivery.
  void put(String entryId, String label) {
    if (state[entryId] == label) return;
    state = {...state, entryId: label};
  }
}

/// Live per-project work status (working/attention/error/done) from each
/// ALREADY-open machine's control-plane advert, keyed by drawer entryId
/// (`"<machineUuid>.<projectId>"`). Written imperatively by the app_shell
/// control-plane reaper — the SAME single-writer pattern as
/// [remoteProjectLabelsProvider], and for the same reason (a per-machine
/// `ref.watch` fan-in into one provider reproduced Riverpod's "rebuilt multiple
/// times in the same frame" crash). Seeded from [CachedSessionsStore] on cold
/// boot (last-known state before the first advert arrives); cleared from the
/// cache when a socket closes so offline machines don't seed stale badges.
final remoteProjectStatusProvider =
    NotifierProvider<
      RemoteProjectStatusController,
      Map<String, AgentWorkStatus>
    >(RemoteProjectStatusController.new);

class RemoteProjectStatusController
    extends Notifier<Map<String, AgentWorkStatus>> {
  @override
  Map<String, AgentWorkStatus> build() {
    // Seed from the persisted status cache so the two PROJECT-level surfaces —
    // the collapsed machine header's aggregate and the title bar's pill — can
    // show the last-known CALL-TO-ACTION (attention/error) before the first
    // advert arrives. Session ROWS deliberately get nothing from this:
    // [remoteSessionStatusProvider] is never seeded, and with no per-session
    // entry `sessionRowStatus` masks on `running`, which the cache loads false.
    // Only those two are seeded: "working" means a prompt is in flight
    // RIGHT NOW, which a cached value from a previous launch cannot possibly
    // know — seeding it would paint a live-activity pulse on a machine we
    // aren't even connected to. attention/error are durable ("this project
    // needs you") and self-heal the moment the socket dials (the advert
    // overwrites the whole machine).
    //
    // Guarded: a widget/provider test that never touches cached sessions won't
    // override cachedSessionsStoreProvider (which throws by contract when
    // unset), and reading status must not force that store into existence —
    // degrade to an empty map rather than throwing out of build().
    try {
      final raw = ref.read(cachedSessionsStoreProvider).allStatuses();
      final result = <String, AgentWorkStatus>{};
      for (final e in raw.entries) {
        final s = AgentWorkStatus.fromWire(e.value);
        if (s == AgentWorkStatus.attention || s == AgentWorkStatus.error) {
          result[e.key] = s!;
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  /// Replace every entry for [machineUuid] with [statuses] in one write:
  /// handles additions, transitions, and removals (a project dropped from the
  /// advert — or the whole socket closing → empty map — clears its status so the
  /// row reads "done"). No-op when nothing changed for this
  /// machine, so an unchanged advert re-delivery triggers no rebuild.
  void setMachineStatuses(
    String machineUuid,
    Map<String, AgentWorkStatus> statuses,
  ) {
    final prefix = '$machineUuid.';
    final next = <String, AgentWorkStatus>{
      for (final e in state.entries)
        if (!e.key.startsWith(prefix)) e.key: e.value,
      ...statuses,
    };
    if (const MapEquality<String, AgentWorkStatus>().equals(state, next)) return;
    state = next;
  }

  /// Update work status for LOCAL (bare-key) projects from the host control
  /// plane's `project:list` poll. [statuses] is keyed by bare projectId.
  /// Compound `uuid.projectId` keys from relay adverts are left untouched.
  /// Called by the desktop periodic poll in [_ControlPlaneReaperState].
  void setLocalStatuses(Map<String, AgentWorkStatus> statuses) {
    final next = <String, AgentWorkStatus>{
      for (final e in state.entries)
        if (e.key.contains('.')) e.key: e.value,
      ...statuses,
    };
    if (const MapEquality<String, AgentWorkStatus>().equals(state, next)) return;
    state = next;
  }
}


/// Live PER-SESSION work status from the same adverts that fill
/// [remoteProjectStatusProvider], keyed by drawer entryId → (sessionId →
/// status). Same single-writer discipline, and for the same reason.
///
/// A project's status is only the ROLLUP of its sessions, so without this every
/// session row on a project wore its noisiest sibling's dot — one chat blocked
/// on a question made all of them read "needs you". An entryId present with an
/// empty map means "the bridge speaks per-session and nothing is running"; an
/// entryId ABSENT means no per-session data at all (older bridge, cold project,
/// closed socket) and callers fall back to the project status.
final remoteSessionStatusProvider =
    NotifierProvider<
      RemoteSessionStatusController,
      Map<String, Map<String, AgentWorkStatus>>
    >(RemoteSessionStatusController.new);

class RemoteSessionStatusController
    extends Notifier<Map<String, Map<String, AgentWorkStatus>>> {
  @override
  Map<String, Map<String, AgentWorkStatus>> build() => const {};

  /// Replace every entry for [machineUuid] in one write (same full-replace
  /// semantics as [RemoteProjectStatusController.setMachineStatuses], so a
  /// project dropped from the advert — or the whole socket closing — clears).
  /// Never seeded from the persisted cache: "working"/"needs you" are claims
  /// about what an agent is doing RIGHT NOW, and a project-level cached value
  /// can't be attributed to a session anyway.
  void setMachineSessionStatuses(
    String machineUuid,
    Map<String, Map<String, AgentWorkStatus>> statuses,
  ) => _replace((key) => !key.startsWith('$machineUuid.'), statuses);

  /// Update the LOCAL (bare-key) projects from the host control plane's
  /// `project:list` poll. Compound `uuid.projectId` keys are left untouched.
  void setLocalSessionStatuses(
    Map<String, Map<String, AgentWorkStatus>> statuses,
  ) => _replace((key) => key.contains('.'), statuses);

  void _replace(
    bool Function(String key) keep,
    Map<String, Map<String, AgentWorkStatus>> incoming,
  ) {
    final next = <String, Map<String, AgentWorkStatus>>{
      for (final e in state.entries)
        if (keep(e.key)) e.key: e.value,
    };
    for (final e in incoming.entries) {
      // Reuse the previous inner map when the contents match: the widgets read
      // this through `select((m) => m[entryId])`, whose equality guard is `==`
      // on the inner Map — a fresh-but-identical instance would rebuild every
      // session row on every advert re-delivery.
      final prev = state[e.key];
      next[e.key] = prev != null && _sameStatuses(prev, e.value) ? prev : e.value;
    }
    if (const MapEquality<String, Map<String, AgentWorkStatus>>().equals(
      state,
      next,
    )) {
      return;
    }
    state = next;
  }
}

bool _sameStatuses(
  Map<String, AgentWorkStatus> a,
  Map<String, AgentWorkStatus> b,
) => const MapEquality<String, AgentWorkStatus>().equals(a, b);

/// What each connected machine's last `agent:projects` advert said, keyed by
/// bare machineUuid: the advertised-project count plus the machine-level
/// remote-access flag (null = flag-less older bridge). "Remote access is on"
/// is the explicit flag when the bridge sent one, with count > 0 as the
/// older-bridge fallback (a bridge with remote off advertises nothing).
typedef MachineAdvertSummary = ({int projectCount, bool? remoteAccessEnabled});

/// Written imperatively by the app_shell control-plane reaper — the SAME
/// single-writer pattern as [remoteProjectStatusProvider], and for the same
/// reason (the per-machine `ref.watch` fan-in crash described above). Not
/// derivable from [remoteProjectLabelsProvider]: that map only records
/// projects with a non-empty label, and labels deliberately persist across
/// disconnects.
final machineAdvertisedProjectsProvider = NotifierProvider<
  MachineAdvertisedProjectsController,
  Map<String, MachineAdvertSummary>
>(MachineAdvertisedProjectsController.new);

class MachineAdvertisedProjectsController
    extends Notifier<Map<String, MachineAdvertSummary>> {
  @override
  Map<String, MachineAdvertSummary> build() => const {};

  /// No-op when unchanged, so an advert re-delivery triggers no rebuild.
  void setAdvert(String machineUuid, MachineAdvertSummary advert) {
    if (state[machineUuid] == advert) return;
    state = {...state, machineUuid: advert};
  }

  /// Drop [machineUuid] entirely — a disconnected machine must not keep
  /// reading as "remote access on" (persisted checklist latches are separate).
  void clear(String machineUuid) {
    if (!state.containsKey(machineUuid)) return;
    state = {...state}..remove(machineUuid);
  }
}

/// Flat, recency-sorted list of every cached session across all projects and
/// devices. Rebuilds when the cache changes (via [cacheChangesProvider]) or any
/// metadata source (projects / recent agents / inventory / local uuid /
/// [remoteProjectLabelsProvider]) updates.
final recentSessionsProvider = Provider<List<RecentSessionRow>>((ref) {
  // Re-derive on any cache mutation. We don't care WHICH key changed — the
  // whole list is cheap to rebuild and a global re-sort is required anyway.
  ref.watch(cacheChangesProvider);

  final store = ref.watch(cachedSessionsStoreProvider);
  final locals = ref.watch(projectsProvider);
  final remotes = ref.watch(recentAgentsProvider);
  final inventory = ref.watch(accountAgentsProvider).value ?? const [];
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  final localLabel = _localDeviceLabel(inventory, localUuid);
  final remoteProjectLabels = ref.watch(remoteProjectLabelsProvider);

  // Overlay the focused project's LIVE session list on top of the cache — the
  // SAME live-or-cached rule the drawer's [sessionsForEntryProvider] uses. A
  // just-created/updated session lands in the live SessionsService state
  // immediately, but its cache write-through can lag (or be clobbered by a
  // stale control-plane listSessions peek), which is why a new session shows in
  // the sidebar yet not here. Reading the live state makes Recent authoritative
  // for the focused project, exactly like the sidebar.
  final cached = {...store.entries()};
  final fresh = ref.watch(freshSessionsStateProvider);
  if (fresh != null) {
    cached[fresh.projectId] = fresh.sessions;
  }

  return buildRecentSessions(
    cached: cached,
    locals: locals,
    remotes: remotes,
    inventory: inventory,
    localDeviceLabel: localLabel,
    remoteProjectLabels: remoteProjectLabels,
  );
});

/// Label for THIS device. The inventory row keyed by [localUuid] carries the
/// friendly machine name; fall back to a generic label when none is found.
String _localDeviceLabel(List<InventoryAgent> inventory, String? localUuid) {
  if (localUuid != null) {
    for (final a in inventory) {
      if (a.deviceUuid == localUuid) return 'This device · ${a.displayName}';
    }
  }
  return 'This device';
}

/// Open/resume a recent session by delegating to the SAME activation helper
/// the drawer and session rows use — never re-implement focus/start
/// orchestration here. `row.origin.registrationId` is the drawer entryId:
/// bare `projectId` for local, compound `<uuid>.<projectId>` for remote.
/// `activateDrawerEntryById` resolves both and returns false on failure.
/// On success, switch to the workspace surface exactly as
/// `session_row.dart`'s `_showFocusedSessionSurface` does.
Future<void> openRecentSession(
  BuildContext context,
  ProviderContainer ref,
  RecentSessionRow row,
) async {
  // Seed the desired active session BEFORE activation; clear it if the switch
  // fails — whether it returns false OR throws (cold-remote pairing/promotion
  // can throw) — so it cannot leak into a future unrelated project open.
  ref.read(pendingActiveSessionIdProvider.notifier).set(row.session.id);
  bool ok;
  try {
    ok = await activateDrawerEntryById(context, ref, row.origin.registrationId);
  } catch (_) {
    ok = false;
  }
  if (!ok) {
    ref.read(pendingActiveSessionIdProvider.notifier).set(null);
    return;
  }
  // Mirror session_row.dart's `_showFocusedSessionSurface`: workspace surface,
  // reset any half-filled New Session form, and record the precise nav entry.
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  resetNewSessionForm(ref);
  ref
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: ref.read(selectedTargetProvider),
          surface: WorkbenchSurface.workspace,
          sessionId: row.session.id,
        ),
      );
}

/// Outcome of a [deleteRecentSession] call — distinguishes an offline machine
/// (block, don't delete locally, reconcile on reconnect) from an outright
/// failure, so the caller can message each case accurately.
enum RecentSessionDeleteOutcome { deleted, offline, failed }

/// The codes `BufferedAgentTransport` mints for itself when a request never
/// reaches the bridge or never comes back. Everything else on an `RpcException`
/// came from the bridge's own error frame — this is the only place the two
/// vocabularies can be told apart, since both arrive as one exception type.
const _kTransportRpcCodes = {'E_TIMEOUT', 'E_SEND_FAILED', 'E_UNKNOWN'};

/// Delete a recent session.
///
/// Local → data-plane via the project's SessionsService (obtained from the
/// registry; warms the loopback session if cold).
/// Remote → control-plane `sessions.delete` RPC, which works whether the
/// project is running or stopped.
///
/// [force] and [deleteBranch] carry the second rung of the delete confirm
/// ladder, so this is called twice for a blocked isolated session. A typed
/// refusal is raised as [SessionOperationException] on BOTH paths rather than
/// collapsed to [RecentSessionDeleteOutcome.failed]: the refusal is what tells
/// the caller which second question to ask, and the enum has no room for it.
Future<RecentSessionDeleteOutcome> deleteRecentSession(
  ProviderContainer ref,
  RecentSessionRow row, {
  bool? force,
  bool? deleteBranch,
}) async {
  final o = row.origin;
  final store = ref.read(cachedSessionsStoreProvider);

  if (o.isLocal) {
    // SessionsService write-throughs the new list to cache on session:updated,
    // so no manual cache edit is needed for the local path. A stale row (cache
    // outlived a removed local project) can fail to resolve a transport and
    // throw — report failure rather than rejecting the Future, so the caller's
    // confirm flow handles it cleanly. Offline is N/A here — the agent is
    // on-device.
    try {
      final session = await ref.read(
        projectSessionProvider(o.registrationId).future,
      );
      final ok = await session.sessionsService.delete(
        row.session.id,
        force: force,
        deleteBranch: deleteBranch,
      );
      return ok
          ? RecentSessionDeleteOutcome.deleted
          : RecentSessionDeleteOutcome.failed;
    } on SessionOperationException {
      rethrow;
    } catch (_) {
      return RecentSessionDeleteOutcome.failed;
    }
  }

  final cp = await ref.read(
    controlPlaneClientForProvider(o.machineUuid!).future,
  );
  if (cp == null) return RecentSessionDeleteOutcome.offline;
  final bool ok;
  try {
    ok = await cp.deleteSession(
      o.projectId,
      row.session.id,
      force: force,
      deleteBranch: deleteBranch,
    );
  } on RpcException catch (e) {
    // Transport failures carry no bridge code and their message is a developer
    // string ("request sessions.delete timed out", or an exception dump), while
    // the ladder falls back to printing `message` verbatim — so they stay an
    // untyped failure and get the surface's own copy.
    if (_kTransportRpcCodes.contains(e.code)) {
      return RecentSessionDeleteOutcome.failed;
    }
    // Re-typed, not rethrown: the caller branches on the bridge's refusal code
    // and must not have to know whether this row's machine answered over the
    // control plane or the data plane.
    throw SessionOperationException(e.code, e.message);
  } catch (_) {
    return RecentSessionDeleteOutcome.failed;
  }
  if (!ok) return RecentSessionDeleteOutcome.failed;
  // Control-plane delete has no automatic cache write-through; prune locally
  // so the row disappears immediately. Flush immediately (not the usual
  // debounced write) so a disconnect/app-kill right after can't resurrect the
  // deleted session on next launch.
  final next = store
      .get(o.registrationId)
      .where((s) => s.id != row.session.id)
      .toList();
  await store.put(o.registrationId, next);
  await store.flushNow();
  return RecentSessionDeleteOutcome.deleted;
}

/// Best-effort background refresh: re-peek the session list for every remote
/// machine that ALREADY has a live control-plane client (never force-pairs —
/// that would storm connections). Write-through updates rows via cacheChanges.
Future<void> refreshRecentSessions(WidgetRef ref) async {
  final rows = ref.read(recentSessionsProvider);
  final store = ref.read(cachedSessionsStoreProvider);
  // One peek per distinct remote PROJECT, not per row: a project with N cached
  // sessions yields N rows sharing one registrationId, and listSessions returns
  // the project's whole list — so a per-row loop would fire N identical RPCs.
  // Key by registrationId (the cache key) → its (machineUuid, projectId).
  final projects = <String, ({String machineUuid, String projectId})>{};
  for (final r in rows) {
    if (r.origin.isLocal) continue;
    projects[r.origin.registrationId] = (
      machineUuid: r.origin.machineUuid!,
      projectId: r.origin.projectId,
    );
  }
  // Peeks are independent reads — run them concurrently so one slow/distant
  // machine doesn't serialize the whole refresh.
  await Future.wait(
    projects.entries.map((e) async {
      // Only refresh machines whose control-plane client is already resolved
      // (non-null means we're paired and connected — don't force a new pair).
      final cp = ref
          .read(controlPlaneClientForProvider(e.value.machineUuid))
          .value;
      if (cp == null) return;
      try {
        final sessions = await cp.listSessions(e.value.projectId);
        await store.put(e.key, sessions);
      } catch (_) {
        // Offline / NOT_ALLOWED — keep the cached rows; reactive presence
        // handles visibility once the machine reconnects.
      }
    }),
  );
}

/// The New Session canvas's pull-to-refresh: the ONLY place that dials the
/// relay for machines behind cached rows. Landing there shows the cache as-is
/// (no auto-connect — see [RecentSessionsTab]); the user explicitly asks to
/// connect and sync by pulling down.
///
/// Connects every distinct remote machine represented in the current cache
/// (via [refreshMachineInventoryAndControlPlanes], which also re-pulls account
/// inventory), then re-peeks each project's session list into the cache via
/// [refreshRecentSessions]. `ref.mounted` is checked after each async gap —
/// [RefreshIndicator]'s `onRefresh` future can keep running after the user
/// navigates off the canvas (or the widget rebuilds away), and resuming a
/// `WidgetRef` past that point throws.
///
/// [extraMachineUuids] lets the caller pin machines with no cached rows into
/// the same gesture — the canvas passes the composer's picker-viewed machine
/// so its project advert refreshes too (nulls are ignored).
Future<void> pullToRefreshRecentSessions(
  WidgetRef ref, {
  Iterable<String?> extraMachineUuids = const [],
}) async {
  final rows = ref.read(recentSessionsProvider);
  final uuids = <String?>{
    ...extraMachineUuids,
    for (final r in rows)
      if (!r.origin.isLocal) r.origin.machineUuid!,
  };
  final refreshRef = RefreshRef.of(ref);
  await refreshMachineInventoryAndControlPlanes(refreshRef, uuids);
  if (!refreshRef.mounted) return;
  await refreshRecentSessions(ref);
}
