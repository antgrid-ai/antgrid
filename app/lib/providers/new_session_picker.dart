import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ab_project.dart';
import '../models/session_entry.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../services/control_plane_client.dart';
import '../project/project_session_registry.dart';
import '../services/account_agents_api.dart';
import '../storage/recent_agents_store.dart';
import '../util/device_id.dart';
import '../utils/platform_utils.dart';
import '../launcher/host_control_client.dart';
import '../widgets/new_session/picker_sources.dart';
import 'account_agents.dart';
import 'agent_transport.dart';
import 'control_plane.dart';
import 'device_provisioning.dart';
import 'projects.dart';
import 'recent_agents.dart';
import 'sessions.dart';
import 'ui_attention_providers.dart';
import 'value_controller.dart';

/// Bare device uuid of a `machine:<uuid>` source id; null for 'local' or the
/// 'machine:none' placeholder. Single source of truth for the source-id prefix
/// minted by [buildPickerSources] (`machine:$uuid` / `machine:none`).
String? machineUuidFromSourceId(String sourceId) {
  const prefix = 'machine:';
  if (!sourceId.startsWith(prefix)) return null;
  final uuid = sourceId.substring(prefix.length);
  return (uuid.isEmpty || uuid == 'none') ? null : uuid;
}

/// Pure grouping function for the New Session rail picker.
///
/// Produces a "Local" source first, then one source per remote MACHINE keyed by
/// bare deviceUuid (`id` == `machine:<uuid>`, `machineUuid` == that uuid). Remote
/// sources carry NO project rows — those arrive asynchronously over the control
/// plane and are expanded in the widget via `controlPlaneStateProvider(uuid)`.
/// Both previously-paired [recents] and account [inventory] agents contribute a
/// machine, so an OFFLINE (recents-only) agent still appears. A machine whose
/// bare deviceUuid already hosts a local project is shown only under "Local" and
/// is NOT duplicated as a remote source (mirrors `mergeDrawerEntries`). A
/// machine's display label resolves to, in order:
///   1. inventory [InventoryAgent.machineName] (trimmed, non-empty), else
///   2. the recents' [RecentAgent.hostMachineName] for that deviceUuid, else
///   3. the literal `'Remote'` bucket.
/// Colliding labels (e.g. two unnamed machines) get a short-uuid suffix so each
/// tab stays distinct. Machine sources are sorted by label; "Local" stays first.
List<PickerSource> buildPickerSources({
  required List<AbProject> localProjects,
  required List<RecentAgent> recents,
  required List<InventoryAgent> inventory,
  String? localDeviceUuid,
  bool includeLocal = true,
}) {
  // Mobile only allows remote agents — skip building the "Local" source there
  // so the rail and detail pane never surface local-folder affordances.
  final local = includeLocal
      ? PickerSource(
          id: 'local',
          label: 'Local',
          isLocal: true,
          projects: localProjects
              .map(
                (p) => PickerProject(
                  id: p.projectId,
                  name: p.displayName,
                  detail: p.folder,
                  isLocal: true,
                  lastActiveAt: p.lastOpenedAt,
                ),
              )
              .toList(),
        )
      : null;

  // An agent whose bare deviceUuid is already a local project's hostDeviceUuid
  // — or is THIS device's own host identity ([localDeviceUuid]) — belongs to
  // "Local", not a remote machine row (mirrors mergeDrawerEntries in
  // drawer_entries.dart). Seeding the device's own uuid keeps it from listing
  // itself as a phantom remote machine when no local project is open: the
  // locally-spawned agent registers in the account inventory under this uuid.
  final localHostUuids = <String>{
    ?localDeviceUuid,
    for (final p in localProjects)
      if (p.hostDeviceUuid != null) p.hostDeviceUuid!,
  };

  // Best machine label per bare deviceUuid: inventory machineName wins, else
  // recents hostMachineName. Missing → 'Remote' bucket at emit time.
  String? clean(String? s) =>
      (s != null && s.trim().isNotEmpty) ? s.trim() : null;
  final machineByUuid = <String, String>{};
  for (final r in recents) {
    final m = clean(r.hostMachineName);
    if (m != null) machineByUuid[baseDeviceUuid(r.agentDeviceId)] = m;
  }
  for (final a in inventory) {
    final m = clean(a.machineName);
    if (m != null) machineByUuid[a.deviceUuid] = m; // inventory wins
  }

  // One source per remote MACHINE (bare deviceUuid). Recents first so an OFFLINE
  // agent still appears; inventory fills in the rest. Rows are NOT built here —
  // the widget expands each machine via controlPlaneStateProvider(uuid).
  final remoteUuids = <String>[]; // insertion-ordered, deduped
  final emitted = <String>{};
  void consider(String uuid) {
    if (localHostUuids.contains(uuid) || !emitted.add(uuid)) return;
    remoteUuids.add(uuid);
  }

  for (final r in recents) {
    consider(baseDeviceUuid(r.agentDeviceId));
  }
  for (final a in inventory) {
    consider(a.deviceUuid);
  }

  // Resolve a display label per uuid; disambiguate collisions (e.g. two unnamed
  // machines both 'Remote') with a short-uuid suffix so each tab is distinct.
  final rawLabel = {
    for (final u in remoteUuids) u: (machineByUuid[u] ?? 'Remote'),
  };
  final labelCounts = <String, int>{};
  for (final l in rawLabel.values) {
    labelCounts[l] = (labelCounts[l] ?? 0) + 1;
  }
  String labelFor(String uuid) {
    final l = rawLabel[uuid]!;
    return (labelCounts[l]! > 1)
        ? '$l · ${uuid.substring(0, uuid.length.clamp(0, 6))}'
        : l;
  }

  final machineSources =
      remoteUuids
          .map(
            (uuid) => PickerSource(
              id: 'machine:$uuid',
              label: labelFor(uuid),
              isLocal: false,
              projects: const <PickerProject>[],
              machineUuid: uuid,
            ),
          )
          .toList()
        ..sort((x, y) => x.label.compareTo(y.label));

  final all = [?local, ...machineSources];
  // Guarantee at least one source so the picker view never needs a synthetic
  // fallback. Only reachable on mobile (includeLocal: false) before any machine
  // is paired — desktop always has the Local source.
  if (all.isEmpty) {
    return const [
      PickerSource(
        id: 'machine:none',
        label: 'Remote',
        isLocal: false,
        projects: <PickerProject>[],
        machineUuid: null,
      ),
    ];
  }
  return all;
}

/// Maps a machine's advertised projects into compound-keyed picker rows.
/// Pure: the widget feeds it the live `controlPlaneState(uuid).projects`. The
/// row id is `RemoteProject(machineUuid, projectId).registrationId`, so picker
/// selection produces a typed RemoteProject (not the legacy bare-uuid shim).
List<PickerProject> buildRemoteProjectRows(
  String machineUuid,
  List<AdvertisedProject> advertised,
) {
  return advertised
      .map(
        (ap) => PickerProject(
          id: RemoteProject(
            machineUuid: machineUuid,
            projectId: ap.projectId,
          ).registrationId,
          name: (ap.label != null && ap.label!.isNotEmpty)
              ? ap.label!
              : ap.projectId,
          detail: ap.path ?? '',
          isLocal: false,
          machineUuid: machineUuid,
          projectId: ap.projectId,
          running: ap.running,
          lastActiveAt: ap.lastActiveAt != null
              ? DateTime.tryParse(ap.lastActiveAt!)
              : null,
        ),
      )
      .toList(growable: false);
}

/// Rail sources for the New Session canvas, fed from the same three sources the
/// dashboard merges (local projects, recent agents, account inventory).
final pickerSourcesProvider = Provider<List<PickerSource>>((ref) {
  final locals = ref.watch(projectsProvider);
  final recents = ref.watch(recentAgentsProvider);
  final inventory =
      ref.watch(accountAgentsProvider).value ?? const <InventoryAgent>[];
  final localUuid = ref.watch(localDeviceUuidProvider).value;
  return buildPickerSources(
    localProjects: locals,
    recents: recents,
    inventory: inventory,
    localDeviceUuid: localUuid,
    includeLocal: !isMobilePlatform,
  );
});

/// Ids of every selectable LOCAL project. Since the Task 3 restructure remote
/// sources carry no project rows, so this yields local project ids only (the
/// footer uses it on the `target.isLocal` branch). Memoized so the action bar's
/// stale-target check doesn't reallocate a Set on every keystroke.
final pickerProjectIdsProvider = Provider<Set<String>>((ref) {
  final sources = ref.watch(pickerSourcesProvider);
  return sources.expand((s) => s.projects).map((p) => p.id).toSet();
});

/// Bare deviceUuids of every remote MACHINE source. The footer's Start guard
/// validates a remote target down to its machine still being listed (the
/// project row's own presence is the finer gate, enforced when it renders /
/// start-on-open runs) — pure sources no longer carry remote project ids.
final pickerMachineUuidsProvider = Provider<Set<String>>((ref) {
  final sources = ref.watch(pickerSourcesProvider);
  return sources
      .where((s) => !s.isLocal && s.machineUuid != null)
      .map((s) => s.machineUuid!)
      .toSet();
});

/// Currently-selected rail source id (`'local'` or `'machine:<deviceUuid>'`).
final selectedSourceIdProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController('local'),
    );

/// The source the picker is actually rendering: the selected source when it is
/// still present, otherwise the first available source.
final visiblePickerSourceProvider = Provider<PickerSource?>((ref) {
  final sources = ref.watch(pickerSourcesProvider);
  if (sources.isEmpty) return null;
  final selectedId = ref.watch(selectedSourceIdProvider);
  for (final s in sources) {
    if (s.id == selectedId) return s;
  }
  return sources.first;
});

/// Currently-selected target project within the active source.
final selectedTargetProjectProvider =
    NotifierProvider<ValueController<PickerProject?>, PickerProject?>(
      () => ValueController(null),
    );

/// Whether picker project [p] is the currently-focused project [focusId].
/// Local projects key by `projectId` (== focus id). Remote projects key by the
/// compound `<deviceUuid>.<projectId>` registration id, which equals the focus
/// id of an open remote project directly.
bool pickerMatchesFocus(PickerProject p, String? focusId) {
  if (focusId == null) return false;
  return p.id == focusId;
}

/// Tools installed on the selected target's MACHINE, as registry key -> display
/// label, driving the agent dropdown. Iteration order is the bridge's advert
/// order (registry declaration order) and is relied on by [firstInstalledAgent].
///
/// The label is null against a bridge predating the `label` field; callers fall
/// back to [kFallbackAgentLabels]. Keys are carried verbatim, so an agent this
/// app has never heard of still appears and is still named.
///
/// Control-plane sourced — no per-project data-plane session is opened to detect:
///   - remote target → the bare-deviceUuid control plane's `agent:tools`
///     ([controlPlaneStateProvider]);
///   - local target  → the loopback host's `tools:list` ([HostControlClient]).
/// While the control-plane connection is in flight (or on any error / offline
/// target / no host yet) this resolves to an empty map and the dropdown shows
/// [kFallbackSessionAgents] as a loading fallback.
final newSessionDetectedToolsProvider = FutureProvider<Map<String, String?>>((
  ref,
) async {
  final target = ref.watch(selectedTargetProjectProvider);
  if (target == null) return const <String, String?>{};

  if (target.isLocal) {
    try {
      final host = await ref.watch(hostControllerProvider).ensureHost();
      final client = HostControlClient(
        port: host.controlPort,
        token: host.token,
      );
      try {
        final tools = await client.toolsList();
        return {for (final t in tools) t.tool: t.label};
      } finally {
        client.close();
      }
    } catch (_) {
      return const <String, String?>{};
    }
  }

  // Remote: target.id is now the compound <uuid>.<projId> (Task 3). Tools are
  // per-MACHINE, so key the control-plane state by the bare deviceUuid. Prefer
  // the split machineUuid when present; fall back to deriving it from the id.
  final machineUuid = target.machineUuid ?? baseDeviceUuid(target.id);
  final state = ref.watch(controlPlaneStateProvider(machineUuid)).value;
  final tools = state?.tools;
  if (tools == null) return const <String, String?>{};
  return {for (final t in tools) t.tool: t.label};
});

/// Wire-advertised chat-capable tool keys for the selected target's MACHINE, or
/// `null` when the bridge hasn't told us (older bridge pre-dating the
/// `chatCapable` field, or no data yet — offline target / loading / error).
///
/// Mirrors the local-vs-remote sourcing of [newSessionDetectedToolsProvider]:
///   - local target  → the loopback host's `tools:list` ([HostControlClient]);
///   - remote target → the bare-deviceUuid control plane's `agent:tools`
///     ([controlPlaneStateProvider]).
///
/// A bridge that predates `chatCapable` sends every entry with the field
/// absent, which surfaces here as `null` (not an empty set) — [null] and
/// "advertised, capable of nothing" must stay distinguishable so callers know
/// to fall back to [newSessionAgentSupportsChat] rather than disabling Chat
/// for every agent.
/// `autoDispose` is load-bearing, not an optimization: a plain provider would
/// outlive the composer, staying subscribed to [controlPlaneStateProvider]
/// (which re-emits a non-`==` state on every control-plane push, so this stays
/// perpetually dirty). On the composer's next mount, `ref.listen` of this
/// provider flushes it mid-build and synchronously notifies its still-live
/// dependent [newSessionSupportsChatProvider], whose refresh is scheduled via
/// `setState` on the enclosing ProviderScope — illegal during build. Disposing
/// with the composer means each mount starts fresh, with no stale dependent to
/// notify. Keep this and [newSessionSupportsChatProvider] both autoDispose.
final newSessionChatCapableToolsProvider =
    FutureProvider.autoDispose<Set<String>?>((ref) async {
      final target = ref.watch(selectedTargetProjectProvider);
      if (target == null) return null;

      if (target.isLocal) {
        try {
          final host = await ref.watch(hostControllerProvider).ensureHost();
          final client = HostControlClient(
            port: host.controlPort,
            token: host.token,
          );
          try {
            final tools = await client.toolsList();
            return chatCapableSetOrNull(
              tools.map((t) => (t.tool, t.chatCapable)),
            );
          } finally {
            client.close();
          }
        } catch (_) {
          return null;
        }
      }

      final machineUuid = target.machineUuid ?? baseDeviceUuid(target.id);
      final state = ref.watch(controlPlaneStateProvider(machineUuid)).value;
      if (state == null) return null;
      return chatCapableSetOrNull(
        state.tools.map((t) => (t.tool, t.chatCapable)),
      );
    });

/// Reduce (tool, chatCapable?) pairs to the set of chat-capable tool keys, or
/// `null` when every entry's `chatCapable` was absent (no wire signal at all —
/// an older bridge, or an empty advert).
Set<String>? chatCapableSetOrNull(Iterable<(String, bool?)> entries) {
  final list = entries.toList(growable: false);
  if (list.isEmpty || list.every((e) => e.$2 == null)) return null;
  return {
    for (final e in list)
      if (e.$2 == true) e.$1,
  };
}

// -- Ephemeral New Session form state --
//
// These hold the visible session-config selections (agent, custom command, CLI
// args, name). They are consumed by [startNewSession] when Start is pressed,
// then reset to defaults on every exit via [resetNewSessionForm] /
// [leaveNewSession] so a stale value never carries into the next session.

/// The agent chosen for the new session: either a bridge registry key, or
/// `custom`, which reveals a free-form command field
/// ([newSessionCustomCmdProvider]).
///
/// Deliberately not an enum. The set of agents lives in the bridge registry, and
/// an app-side enum could only ever be a stale copy of it: every key the enum
/// did not list collapsed onto Claude Code, so a newly-shipped agent was both
/// absent from the picker and mislabelled wherever a session already ran it.
/// Carrying the key itself makes the bridge authoritative — the same reason
/// [agentSupportsChatResolved] prefers the wire over [newSessionAgentSupportsChat].
sealed class NewSessionAgent {
  const NewSessionAgent();
}

/// An agent identified by its bridge registry key (`claude-code`, `kilo`, ...).
final class KnownAgent extends NewSessionAgent {
  final String toolKey;
  const KnownAgent(this.toolKey);

  // Value equality is load-bearing: these flow through Riverpod state and
  // `options.contains(selected)`, both of which compare by `==`.
  @override
  bool operator ==(Object other) =>
      other is KnownAgent && other.toolKey == toolKey;

  @override
  int get hashCode => toolKey.hashCode;
}

/// The free-form-command flavor.
final class CustomAgent extends NewSessionAgent {
  const CustomAgent();

  @override
  bool operator ==(Object other) => other is CustomAgent;

  @override
  int get hashCode => (CustomAgent).hashCode;
}

/// The agent the form starts on before detection reports anything.
const NewSessionAgent kDefaultSessionAgent = KnownAgent('claude-code');

/// Registry key for a known agent, or null for `custom`.
String? newSessionAgentToolKey(NewSessionAgent a) => switch (a) {
  KnownAgent(:final toolKey) => toolKey,
  CustomAgent() => null,
};

/// Inverse of [newSessionAgentToolKey]. Any non-empty key is taken at face
/// value — an unrecognised one is a newer bridge's agent, not an error, and
/// must not be folded onto some default.
NewSessionAgent newSessionAgentFromToolKey(String? key) =>
    (key == null || key.isEmpty) ? kDefaultSessionAgent : KnownAgent(key);

/// Display names for the agents this app shipped knowing about.
///
/// Fallback ONLY: the bridge advertises `label` per tool and that always wins.
/// This exists so the picker still reads correctly against a bridge predating
/// the field, and is not a list of the agents that exist.
const Map<String, String> kFallbackAgentLabels = {
  'claude-code': 'Claude Code',
  'codex': 'Codex',
  'opencode': 'opencode',
  'cursor-agent': 'Cursor',
  'github-copilot': 'Copilot',
};

/// Pretty label for [a], preferring the bridge-advertised [wireLabels].
/// Falls back to the raw registry key: showing `kilo` is honest, whereas the
/// old enum showed such an agent as "Claude Code".
String newSessionAgentLabel(
  NewSessionAgent a, [
  Map<String, String?>? wireLabels,
]) => switch (a) {
  CustomAgent() => 'Custom',
  KnownAgent(:final toolKey) =>
    wireLabels?[toolKey] ?? kFallbackAgentLabels[toolKey] ?? toolKey,
};

/// Display label for a cached session's agent (registry tool key or custom cmd).
///
/// Static labels only, deliberately: a cached row belongs to its own origin
/// machine, and [newSessionDetectedToolsProvider] is scoped to whatever target
/// the New Session picker currently points at. Passing that in would name a row
/// from an unrelated machine's tool list.
String sessionAgentDisplayLabel(SessionEntry session) {
  final tool = session.tool;
  if (tool != null && tool.isNotEmpty) {
    return newSessionAgentLabel(KnownAgent(tool));
  }
  final command = session.command?.trim();
  if (command != null && command.isNotEmpty) return command;
  return newSessionAgentLabel(kDefaultSessionAgent);
}

/// The agents offered when the bridge has advertised nothing yet (loading, an
/// offline target, or a bridge with no tools handler). Fallback only — when a
/// live advert exists the picker is built from it, so a newer bridge's agents
/// appear without an app release.
final List<NewSessionAgent> kFallbackSessionAgents = kFallbackAgentLabels.keys
    .map<NewSessionAgent>(KnownAgent.new)
    .toList(growable: false);

/// The agent the form should default to once detection reveals what is
/// installed. Keeps [current] when it is `custom` or already installed;
/// otherwise snaps to the first installed known agent so the default is
/// actually runnable (or keeps [current] if nothing is detected installed).
NewSessionAgent firstInstalledAgent(
  Map<String, String?> detected,
  NewSessionAgent current,
) {
  if (current is CustomAgent) return current;
  final key = newSessionAgentToolKey(current);
  if (key != null && detected.containsKey(key)) return current;
  // Key order is the bridge's advert order (registry declaration order), so the
  // "first installed" preference is the bridge's to define rather than a copy
  // of it held here.
  if (detected.isEmpty) return current;
  return KnownAgent(detected.keys.first);
}

/// Selected agent flavor. Defaults to Claude Code.
final newSessionAgentProvider =
    NotifierProvider<ValueController<NewSessionAgent>, NewSessionAgent>(
      () => ValueController(kDefaultSessionAgent),
    );

/// Free-form launch command, used when [newSessionAgentProvider] is `custom`.
final newSessionCustomCmdProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController(''),
    );

/// Optional CLI arguments appended to the agent launch command.
final newSessionCliArgsProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController(''),
    );

/// Optional session name.
final newSessionNameProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController(''),
    );

/// Selected session mode for the new session (`'terminal'` | `'chat'`). Chat is
/// only valid for chat-capable agents; the toggle forces `'terminal'` for
/// other agents (see [agentSupportsChatResolved]).
final newSessionModeProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController('terminal'),
    );

/// Fallback whether [a] supports Chat mode, used only when no wire
/// `chatCapable` data is available (older bridge, or offline/loading target).
/// Prefer [agentSupportsChatResolved], which consults the wire advert first.
bool newSessionAgentSupportsChat(NewSessionAgent a) {
  final key = newSessionAgentToolKey(a);
  return key != null && kFallbackChatCapableTools.contains(key);
}

/// Static mirror of the entries carrying a `driver` in
/// bridge/src/agents/registry.ts, used only by [newSessionAgentSupportsChat].
/// Fallback only — see [agentSupportsChatResolved].
const Set<String> kFallbackChatCapableTools = {
  'claude-code',
  'codex',
  'opencode',
};

/// Resolve whether [a] supports Chat mode: wire-first, static fallback.
///
/// When [wireChatCapable] is non-null (the bridge advertised `chatCapable` for
/// at least one tool on the target machine), Chat support is decided purely
/// from whether the agent's registry key is in that set — this makes the
/// bridge authoritative and keeps a newer bridge's driver additions/removals
/// in sync with the app without a release. When it is null (older bridge that
/// predates the field, or no data yet), falls back to the static
/// [newSessionAgentSupportsChat] list so Chat still works against old bridges
/// and during the brief loading window.
bool agentSupportsChatResolved(
  NewSessionAgent a,
  Set<String>? wireChatCapable,
) {
  final key = newSessionAgentToolKey(a);
  if (wireChatCapable != null) {
    return key != null && wireChatCapable.contains(key);
  }
  return newSessionAgentSupportsChat(a);
}

/// Whether the selected agent supports Chat mode right now (wire-first, static
/// fallback). Derived so the composer can watch a stable `bool` instead of
/// [newSessionChatCapableToolsProvider] directly: that FutureProvider allocates
/// a fresh `Set` and re-emits on EVERY control-plane push (heartbeat), which
/// would rebuild the whole composer subtree while idle. A `Provider<bool>`
/// notifies only when the resolved value actually flips.
/// autoDispose so it never outlives the composer as a stale, still-subscribed
/// dependent of [newSessionChatCapableToolsProvider] — see that provider's note.
final newSessionSupportsChatProvider = Provider.autoDispose<bool>((ref) {
  final agent = ref.watch(newSessionAgentProvider);
  final wire = ref.watch(newSessionChatCapableToolsProvider).value;
  return agentSupportsChatResolved(agent, wire);
});

/// True once the user manually changed the agent dropdown during this New
/// Session visit. Suppresses target-driven re-defaulting so a manual pick is
/// never clobbered. Reset by [resetNewSessionForm].
final newSessionAgentTouchedProvider =
    NotifierProvider<ValueController<bool>, bool>(() => ValueController(false));

/// True while [startNewSession] is mid-flight creating+starting a session.
/// `_bootstrapSessions` (workspace_shell) checks this and skips its
/// empty->New-Session route so the two paths don't fight over
/// [workbenchSurfaceProvider].
final newSessionStartInFlightProvider =
    NotifierProvider<ValueController<bool>, bool>(() => ValueController(false));

/// The composer's prompt text. Non-empty text becomes the session's first
/// message (chat) or launch argv (terminal) via `session:start.initialPrompt`.
final newSessionPromptProvider =
    NotifierProvider<ValueController<String>, String>(
      () => ValueController(''),
    );

/// Whether the picked target is still valid to start against: a local target's
/// project must still exist; a remote target's machine must still be listed
/// (the project row's own presence is the finer gate, enforced when it
/// renders / start-on-open runs). Relocated from the old form footer.
final newSessionHasValidTargetProvider = Provider<bool>((ref) {
  final target = ref.watch(selectedTargetProjectProvider);
  if (target == null) return false;
  if (target.isLocal) {
    return ref.watch(pickerProjectIdsProvider).contains(target.id);
  }
  return target.machineUuid != null &&
      ref.watch(pickerMachineUuidsProvider).contains(target.machineUuid);
});

/// Reset the ephemeral New Session form + selection to defaults. Called on every
/// exit (Start success / Cancel / Esc) so reopening the page starts clean and a
/// stale name never attaches to the next session.
///
/// Takes the container, not a `WidgetRef`: the session-activation callers reach
/// here after an await, by which point the row that started it may be gone.
void resetNewSessionForm(ProviderContainer ref) {
  ref.read(newSessionAgentProvider.notifier).set(kDefaultSessionAgent);
  ref.read(newSessionCustomCmdProvider.notifier).set('');
  ref.read(newSessionCliArgsProvider.notifier).set('');
  ref.read(newSessionNameProvider.notifier).set('');
  ref.read(newSessionModeProvider.notifier).set('terminal');
  ref.read(selectedTargetProjectProvider.notifier).set(null);
  ref.read(selectedSourceIdProvider.notifier).set('local');
  ref.read(newSessionAgentTouchedProvider.notifier).set(false);
  ref.read(newSessionStartInFlightProvider.notifier).set(false);
  ref.read(newSessionPromptProvider.notifier).set('');
}

/// Leave the New Session page: reset the form, clear new-session mode, and
/// record the return to workspace. Callers are the genuine "exit New Session"
/// sites (Cancel / Esc / back).
void leaveNewSession(ProviderContainer ref) {
  // Record a history entry ONLY when we were actually on the New Session
  // surface. The read happens before resetNewSessionForm, which never touches
  // workbenchSurfaceProvider, so the captured value reflects the entry surface.
  // (A session tap that dismisses the page lands in workspace and records its
  // own session entry — it resets the form directly instead of calling this.)
  final wasNewSession =
      ref.read(workbenchSurfaceProvider) == WorkbenchSurface.newSession;
  resetNewSessionForm(ref);
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.workspace);
  if (wasNewSession) {
    ref
        .read(navControllerProvider.notifier)
        .commit(
          NavLocation(
            target: ref.read(selectedTargetProvider),
            surface: WorkbenchSurface.workspace,
            sessionId: ref.read(activeSessionIdProvider),
          ),
        );
  }
}

/// Default the New Session form to [target]'s configured agent (from the
/// project's cached agent:hello), unless the user already overrode the dropdown
/// this visit. Maps `agentHello.tool` to the dropdown; if the project is
/// configured with a custom `command` (no tool), selects `custom` and seeds the
/// command field; otherwise defaults to claudeCode. The configured `flags` seed
/// the CLI-args field so keeping the default agent re-applies them (a per-session
/// tool/command launch does not inherit antgrid.yaml flags otherwise).
///
/// Best-effort: a missing/loading status (common for a remote target keyed by
/// bare deviceUuid) yields claudeCode with empty command/args. Never throws.
void seedNewSessionAgentForTarget(
  ProviderContainer ref,
  PickerProject? target,
) {
  if (ref.read(newSessionAgentTouchedProvider)) return;
  final hello = target == null
      ? null
      : ref.read(projectStatusProvider(target.id)).value?.agentHello;
  final tool = hello?.tool;
  final command = hello?.command;

  if (tool != null && tool.isNotEmpty) {
    ref
        .read(newSessionAgentProvider.notifier)
        .set(newSessionAgentFromToolKey(tool));
    ref.read(newSessionCustomCmdProvider.notifier).set('');
  } else if (command != null && command.isNotEmpty) {
    ref.read(newSessionAgentProvider.notifier).set(const CustomAgent());
    ref.read(newSessionCustomCmdProvider.notifier).set(command);
  } else {
    ref.read(newSessionAgentProvider.notifier).set(kDefaultSessionAgent);
    ref.read(newSessionCustomCmdProvider.notifier).set('');
  }
  ref
      .read(newSessionCliArgsProvider.notifier)
      .set((hello?.flags ?? const <String>[]).join(' '));
}

/// Default the New Session form to mirror an existing [session]'s launch config
/// (agent/command/args), unless the user already overrode the dropdown this
/// visit. Used when "New Session" is tapped from inside a workspace so the new
/// session inherits the one you were just looking at — `tool` maps to the
/// dropdown; a custom (toolless) `command` selects `custom` and seeds the command
/// field; `args` seeds the CLI-args field. Falls back to claudeCode when the
/// session carries neither a tool nor a command.
void seedNewSessionAgentFromSession(
  ProviderContainer ref,
  SessionEntry session,
) {
  if (ref.read(newSessionAgentTouchedProvider)) return;
  final tool = session.tool;
  final command = session.command;

  if (tool != null && tool.isNotEmpty) {
    ref
        .read(newSessionAgentProvider.notifier)
        .set(newSessionAgentFromToolKey(tool));
    ref.read(newSessionCustomCmdProvider.notifier).set('');
  } else if (command != null && command.isNotEmpty) {
    ref.read(newSessionAgentProvider.notifier).set(const CustomAgent());
    ref.read(newSessionCustomCmdProvider.notifier).set(command);
  } else {
    ref.read(newSessionAgentProvider.notifier).set(kDefaultSessionAgent);
    ref.read(newSessionCustomCmdProvider.notifier).set('');
  }
  ref.read(newSessionCliArgsProvider.notifier).set(session.args ?? '');
}

/// Enter the New Session page with a specific advertised remote [project]
/// (under machine [machineUuid]) preselected, so a `+` tapped on a project row
/// in the drawer lands the user on New Session already targeting THAT project —
/// they only pick the agent and hit Start. Mirrors the remote branch of
/// [enterNewSession] but sources the target from the drawer's advert instead of
/// the current focus (the tapped project need not be focused, or even warm).
void enterNewSessionForRemoteProject(
  ProviderContainer ref, {
  required String machineUuid,
  required AdvertisedProject project,
}) {
  resetNewSessionForm(ref);
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.newSession);

  final regId = RemoteProject(
    machineUuid: machineUuid,
    projectId: project.projectId,
  ).registrationId;
  final label = project.label;
  final target = PickerProject(
    id: regId,
    name: (label != null && label.isNotEmpty) ? label : project.projectId,
    detail: project.path ?? '',
    isLocal: false,
    machineUuid: machineUuid,
    projectId: project.projectId,
    running: project.running,
  );
  ref.read(selectedSourceIdProvider.notifier).set('machine:$machineUuid');
  ref.read(selectedTargetProjectProvider.notifier).set(target);
  seedNewSessionAgentForTarget(ref, target);

  ref
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: ref.read(selectedTargetProvider),
          surface: WorkbenchSurface.newSession,
        ),
      );
}

/// Enter the New Session page, preselecting the currently-focused project when
/// one is active (e.g. "New Session" tapped from inside a workspace). Reverse-
/// looks up [selectedRegistrationIdProvider] in the live picker sources and, on a
/// match, seeds [selectedTargetProjectProvider] + [selectedSourceIdProvider] so
/// the user can hit Start immediately. No match (or no active project — the
/// first-launch landing) leaves the defaults ('local' source, no target).
///
/// Matching mirrors the id namespaces the picker uses: local targets key by
/// `projectId` (direct), remote targets key by the compound registration id
/// `<deviceUuid>.<projectId>` (matches the focus id directly).
void enterNewSession(ProviderContainer ref) {
  resetNewSessionForm(ref);
  ref.read(workbenchSurfaceProvider.notifier).set(WorkbenchSurface.newSession);

  final focusId = ref.read(selectedRegistrationIdProvider);
  if (focusId != null) {
    final localMatch = ref
        .read(pickerSourcesProvider)
        .where((s) => s.isLocal)
        .expand((s) => s.projects)
        .where((p) => pickerMatchesFocus(p, focusId))
        .firstOrNull;
    if (localMatch != null) {
      ref.read(selectedSourceIdProvider.notifier).set('local');
      ref.read(selectedTargetProjectProvider.notifier).set(localMatch);
    } else {
      // Remote sources no longer carry rows, so synthesize the focused remote
      // target from its compound registration id (<deviceUuid>.<projectId>):
      // select the matching machine tab and prime the target so Start works
      // before the control-plane advertisement re-materializes the row.
      final base = baseDeviceUuid(focusId);
      final machine = ref
          .read(pickerSourcesProvider)
          .where((s) => s.machineUuid == base)
          .firstOrNull;
      if (machine != null && focusId.length > base.length + 1) {
        final projId = focusId.substring(base.length + 1);
        final cpState = ref.read(controlPlaneStateProvider(base)).value;
        final advertised = cpState?.projects
            .where((p) => p.projectId == projId)
            .firstOrNull;
        ref.read(selectedSourceIdProvider.notifier).set(machine.id);
        final label = advertised?.label;
        ref
            .read(selectedTargetProjectProvider.notifier)
            .set(
              PickerProject(
                id: focusId,
                name: (label != null && label.isNotEmpty) ? label : projId,
                detail: advertised?.path ?? '',
                isLocal: false,
                machineUuid: base,
                projectId: projId,
                running: advertised?.running ?? true,
              ),
            );
      }
    }
  }

  // Prefer the focused session's actual launch config (agent/command/args) so a
  // "New Session" tapped from inside a workspace inherits what you were just
  // looking at. The preselected target is, by construction, the focused project
  // (it's only set above when it matched the focus id), so the active session
  // belongs to it. With no active session, fall back to the project's configured
  // default (agent:hello).
  final target = ref.read(selectedTargetProjectProvider);
  final active = ref.read(activeSessionProvider);
  if (target != null && active != null) {
    seedNewSessionAgentFromSession(ref, active);
  } else {
    seedNewSessionAgentForTarget(ref, target);
  }

  ref
      .read(navControllerProvider.notifier)
      .commit(
        NavLocation(
          target: ref.read(selectedTargetProvider),
          surface: WorkbenchSurface.newSession,
        ),
      );
}
